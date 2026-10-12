//! Starting the windowless daemon (`kowalskiw.exe`, next to `kowalski.exe`)
//! now or at logon. Logon start is the HKCU Run entry only.
const std = @import("std");
const windows = std.os.windows;

const Hkey = *opaque {};
const hkey_current_user: Hkey = @ptrFromInt(0x80000001);
const reg_sz: u32 = 1;
const rrf_rt_reg_sz: u32 = 0x00000002;
const error_file_not_found: i32 = 2;
const detached_process: u32 = 0x00000008;
const create_new_process_group: u32 = 0x00000200;

extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buffer: [*]u16, size: u32) callconv(.winapi) u32;
extern "advapi32" fn RegSetKeyValueW(key: Hkey, subkey: [*:0]const u16, value: [*:0]const u16, kind: u32, data: *const anyopaque, size: u32) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueW(key: Hkey, subkey: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: *u32) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteKeyValueW(key: Hkey, subkey: [*:0]const u16, value: [*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteKeyW(key: Hkey, subkey: [*:0]const u16) callconv(.winapi) i32;

const StartupInfoW = extern struct {
    cb: u32 = @sizeOf(StartupInfoW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?windows.HANDLE = null,
    hStdOutput: ?windows.HANDLE = null,
    hStdError: ?windows.HANDLE = null,
};
const ProcessInformation = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, command: [*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: i32, flags: u32, environment: ?*anyopaque, cwd: ?[*:0]const u16, startup: *const StartupInfoW, info: *ProcessInformation) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn TerminateProcess(handle: windows.HANDLE, code: u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleProcessList(list: [*]u32, count: u32) callconv(.winapi) u32;
extern "kernel32" fn FreeConsole() callconv(.winapi) i32;
extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, operation: ?[*:0]const u16, file: [*:0]const u16, parameters: ?[*:0]const u16, directory: ?[*:0]const u16, show: i32) callconv(.winapi) ?*anyopaque;
extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;

pub const run_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
pub const value_name = "kowalski";
pub const background_exe = "kowalskiw.exe";

fn wide(a: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, text);
}

/// The folder holding the running executable.
pub fn exeDir(a: std.mem.Allocator) ![]u8 {
    var buffer: [32 * 1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &buffer, buffer.len);
    if (n == 0 or n >= buffer.len) return error.ModulePath;
    const path = try std.unicode.utf16LeToUtf8Alloc(a, buffer[0..n]);
    return a.dupe(u8, std.fs.path.dirname(path) orelse return error.ModulePath);
}

/// The command line that runs the windowless daemon quietly (no browser);
/// `--db` when the caller supplies a path; `--after` waits for an old daemon.
pub fn backgroundCommand(a: std.mem.Allocator, db: ?[]const u8, after: ?u32) ![]u8 {
    const dir = try exeDir(a);
    const exe = try std.fs.path.join(a, &.{ dir, background_exe });
    const base = if (db) |path|
        try std.fmt.allocPrint(a, "\"{s}\" --background --db \"{s}\"", .{ exe, path })
    else
        try std.fmt.allocPrint(a, "\"{s}\" --background", .{exe});
    if (after) |pid| return std.fmt.allocPrint(a, "{s} --after {d}", .{ base, pid });
    return base;
}

/// Opens `url` in the default browser.
pub fn openUrl(a: std.mem.Allocator, url: []const u8) !void {
    const result = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), try wide(a, url), null, null, 1);
    // ShellExecute returns a value above 32 on success.
    if (@intFromPtr(result) <= 32) return error.OpenUrl;
}

/// Whether this console program owns its console alone: started from
/// Explorer (a double-click) rather than from a terminal.
pub fn ownConsole() bool {
    var list: [2]u32 = undefined;
    return GetConsoleProcessList(&list, list.len) == 1;
}

/// Closes the console window of a program started by a double-click.
pub fn dropConsole() void {
    _ = FreeConsole();
}

/// A message box, for programs that have no console to write to.
pub fn alert(a: std.mem.Allocator, text: []const u8) void {
    const body = wide(a, text) catch return;
    _ = MessageBoxW(null, body, std.unicode.utf8ToUtf16LeStringLiteral("kowalski"), 0x10);
}

/// Starts a detached process and does not wait for it.
pub fn spawn(a: std.mem.Allocator, command: []const u8) !void {
    var child = try spawnTracked(a, command);
    child.close();
}

pub const Child = struct {
    handle: windows.HANDLE,
    pid: u32,

    pub fn alive(self: Child) bool { return WaitForSingleObject(self.handle, 0) == 0x102; }
    pub fn terminate(self: Child) void {
        if (self.alive()) _ = TerminateProcess(self.handle, 1);
        _ = WaitForSingleObject(self.handle, 10_000);
    }
    pub fn close(self: *Child) void { _ = CloseHandle(self.handle); self.* = undefined; }
};

pub fn spawnTracked(a: std.mem.Allocator, command: []const u8) !Child {
    const line = try wide(a, command);
    var info: ProcessInformation = undefined;
    if (CreateProcessW(null, line.ptr, null, null, 0, detached_process | create_new_process_group, null, null, &.{}, &info) == 0) return error.Spawn;
    _ = CloseHandle(info.hThread);
    return .{ .handle = info.hProcess, .pid = info.dwProcessId };
}

/// The logon command stored under `subkey`, or null when there is none.
pub fn getAutostart(a: std.mem.Allocator, subkey: []const u8) !?[]u8 {
    const key = try wide(a, subkey);
    const name = try wide(a, value_name);
    var size: u32 = 0;
    var status = RegGetValueW(hkey_current_user, key, name, rrf_rt_reg_sz, null, null, &size);
    if (status == error_file_not_found) return null;
    if (status != 0) return error.Registry;
    const data = try a.alloc(u16, size / 2);
    status = RegGetValueW(hkey_current_user, key, name, rrf_rt_reg_sz, null, data.ptr, &size);
    if (status != 0) return error.Registry;
    const text = std.mem.sliceTo(data, 0);
    return try std.unicode.utf16LeToUtf8Alloc(a, text);
}

pub fn setAutostart(a: std.mem.Allocator, subkey: []const u8, command: []const u8) !void {
    const data = try wide(a, command);
    const status = RegSetKeyValueW(hkey_current_user, try wide(a, subkey), try wide(a, value_name), reg_sz, data.ptr, @intCast((data.len + 1) * 2));
    if (status != 0) return error.Registry;
}

/// Removes the logon command; removing one that is not there is fine.
pub fn removeAutostart(a: std.mem.Allocator, subkey: []const u8) !void {
    const status = RegDeleteKeyValueW(hkey_current_user, try wide(a, subkey), try wide(a, value_name));
    if (status != 0 and status != error_file_not_found) return error.Registry;
}

test "autostart round trip on a scratch key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scratch = "Software\\sadirano-kowalski-test";
    const scratch_key = try wide(a, scratch);
    defer _ = RegDeleteKeyW(hkey_current_user, scratch_key);
    try removeAutostart(a, scratch);
    try std.testing.expect((try getAutostart(a, scratch)) == null);
    const command = try backgroundCommand(a, "scratch\\k.db", null);
    try std.testing.expect(std.mem.endsWith(u8, command, "\\kowalskiw.exe\" --background --db \"scratch\\k.db\""));
    const after = try backgroundCommand(a, "scratch\\k.db", 1234);
    try std.testing.expect(std.mem.endsWith(u8, after, "\\kowalskiw.exe\" --background --db \"scratch\\k.db\" --after 1234"));
    try setAutostart(a, scratch, command);
    try std.testing.expectEqualStrings(command, (try getAutostart(a, scratch)).?);
    try removeAutostart(a, scratch);
    try std.testing.expect((try getAutostart(a, scratch)) == null);
}
