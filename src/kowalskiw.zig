//! `kowalskiw.exe`: the daemon without a console window. With `--background`
//! (the logon entry, `kowalski start`) it serves quietly and logs to
//! `daemon.log` next to the database; double-clicked, it starts that daemon
//! and opens the dashboard.
const std = @import("std");
const windows = std.os.windows;
const daemon = @import("daemon.zig");
const paths = @import("paths.zig");
const opener = @import("opener.zig");

const synchronize: u32 = 0x00100000;
const wait_timeout: u32 = 258;
const error_invalid_parameter: u32 = 87;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const Args = struct { db: ?[]const u8 = null, background: bool = false, after: ?u32 = null, trial: ?[]const u8 = null };

fn validNonce(nonce: []const u8) bool {
    if (nonce.len != 32) return false;
    for (nonce) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn parseArgs(args: []const []const u8) !Args {
    var result: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--background")) {
            result.background = true;
        } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len and result.db == null) {
            result.db = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--after") and i + 1 < args.len and result.after == null) {
            const pid = std.fmt.parseInt(u32, args[i + 1], 10) catch return error.Usage;
            if (pid == 0) return error.Usage;
            result.after = pid;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--trial") and i + 1 < args.len and result.trial == null) {
            if (!validNonce(args[i + 1])) return error.Usage;
            result.trial = args[i + 1];
            result.background = true;
            i += 1;
        } else return error.Usage;
    }
    return result;
}

fn waitForPrevious(pid: u32) !void {
    const previous = OpenProcess(synchronize, 0, pid) orelse {
        if (GetLastError() == error_invalid_parameter) return;
        return error.WaitFailed;
    };
    defer _ = CloseHandle(previous);
    return switch (WaitForSingleObject(previous, 30_000)) {
        0 => {},
        wait_timeout => error.WaitTimedOut,
        else => error.WaitFailed,
    };
}

pub fn main(init: std.process.Init) void {
    run(init) catch std.process.exit(1);
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const options = try parseArgs(args);
    const db = options.db orelse try paths.defaultDb(init.io, a);
    if (options.after) |pid| {
        waitForPrevious(pid) catch |err| {
            daemon.logBeforeStart(init.gpa, db, if (err == error.WaitTimedOut)
                "previous daemon still running; not starting"
            else
                "could not wait for previous daemon; not starting") catch {};
            return err;
        };
    }
    if (!options.background) return opener.openOrAlert(init.io, a, db, options.db);
    const log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", "daemon.log" });
    try daemon.serve(init.io, init.gpa, .{ .db_path = db, .log_path = log_path, .trial_nonce = options.trial });
}

test "parse delayed background start with and without db" {
    const first = try parseArgs(&.{ "kowalskiw.exe", "--background", "--after", "42" });
    try std.testing.expect(first.background);
    try std.testing.expectEqual(@as(?u32, 42), first.after);
    try std.testing.expect(first.db == null);
    const second = try parseArgs(&.{ "kowalskiw.exe", "--background", "--db", "scratch\\k.db", "--after", "123" });
    try std.testing.expectEqualStrings("scratch\\k.db", second.db.?);
    try std.testing.expectEqual(@as(?u32, 123), second.after);
    try std.testing.expectError(error.Usage, parseArgs(&.{ "kowalskiw.exe", "--after", "oops" }));
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", (try parseArgs(&.{ "kowalskiw.exe", "--trial", "0123456789abcdef0123456789abcdef" })).trial.?);
    try std.testing.expectError(error.Usage, parseArgs(&.{ "kowalskiw.exe", "--trial", "bad" }));
}
