# End-to-end check of the windowless daemon on a scratch database: start,
# lunch-window lock pause, resume-from-sleep recovery, log file, shutdown.
# Lock and power messages are posted to the event window, so this proves the
# wiring, not that Windows sends them; that needs a real lock and sleep.
param([string]$Bin = "$PSScriptRoot/../zig-out/bin")
$ErrorActionPreference = 'Stop'

if (Get-Process kowalski, kowalskiw -ErrorAction SilentlyContinue) {
    throw 'a kowalski daemon is running; stop it first (one daemon per user)'
}
Add-Type -Namespace Smoke -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")]
public static extern bool PostMessageW(IntPtr hwnd, uint msg, UIntPtr w, IntPtr l);
'@

$scratch = Join-Path ([IO.Path]::GetTempPath()) "kowalski-smoke-$PID"
New-Item -ItemType Directory $scratch | Out-Null
$db = Join-Path $scratch 'k.db'
$k = Join-Path $Bin 'kowalski.exe'
function K { & $k --db $db @args; if ($LASTEXITCODE -ne 0) { throw "kowalski $args failed ($LASTEXITCODE)" } }
function Check([bool]$ok, [string]$what) { if (-not $ok) { throw "FAILED: $what" }; "ok: $what" }

try {
    K start
    Check ($null -ne (Get-Process kowalskiw -ErrorAction SilentlyContinue)) 'kowalskiw runs'
    $hwnd = [Smoke.Win]::FindWindowW('sadirano-kowalski-events', [NullString]::Value)
    Check ($hwnd -ne [IntPtr]::Zero) 'event window exists'

    # A lunch window around the current time in the reporting zone (the OS zone).
    $now = Get-Date
    K set auto_pause_on_lock 1 | Out-Null
    K set lunch_end $now.AddMinutes(5).ToString('HH:mm') | Out-Null
    K set lunch_start $now.AddMinutes(-5).ToString('HH:mm') | Out-Null
    K switch smoke-task | Out-Null
    [Smoke.Win]::PostMessageW($hwnd, 0x02B1, [UIntPtr]7, [IntPtr]::Zero) | Out-Null # WTS_SESSION_LOCK
    Start-Sleep -Milliseconds 500
    $state = K --json status | ConvertFrom-Json
    Check ($null -eq $state.focus -and $state.saved.Count -eq 1) 'lock in the lunch window pauses'

    K resume | Out-Null
    [Smoke.Win]::PostMessageW($hwnd, 0x0218, [UIntPtr]0x12, [IntPtr]::Zero) | Out-Null # PBT_APMRESUMEAUTOMATIC
    Start-Sleep -Milliseconds 500
    $state = K --json status | ConvertFrom-Json
    Check ($null -eq $state.focus -and $state.saved.Count -eq 1) 'resume from sleep closes and saves the focus'

    K shutdown | Out-Null
    Start-Sleep -Milliseconds 1000
    Check ($null -eq (Get-Process kowalskiw -ErrorAction SilentlyContinue)) 'shutdown ends kowalskiw'
    $log = Get-Content (Join-Path $scratch 'daemon.log') -Raw
    foreach ($line in 'listening on', 'paused', 'resumed', 'stopped') {
        Check ($log -match $line) "daemon.log has '$line'"
    }
} finally {
    Get-Process kowalskiw -ErrorAction SilentlyContinue | Stop-Process
    Remove-Item -Recurse -Force $scratch
}
