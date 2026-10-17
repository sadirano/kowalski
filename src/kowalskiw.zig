//! `kowalskiw.exe`: the daemon without a console window. With `--background`
//! (the logon entry, `kowalski start`) it serves quietly and logs to
//! `daemon.log` next to the database; double-clicked, it starts that daemon
//! and opens the dashboard.
const std = @import("std");
const windows = std.os.windows;
const daemon = @import("daemon.zig");
const paths = @import("paths.zig");
const opener = @import("opener.zig");
const update_guard = @import("update_guard.zig");
const update_lock = @import("update_lock.zig");
const update_journal = @import("update_journal.zig");
const launch = @import("launch.zig");
const clock = @import("clock.zig");
const doctor = @import("doctor.zig");

const synchronize: u32 = 0x00100000;
const wait_timeout: u32 = 258;
const error_invalid_parameter: u32 = 87;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const Args = struct { db: ?[]const u8 = null, background: bool = false, after: ?u32 = null, trial: ?[]const u8 = null, guard: bool = false };

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
        } else if (std.mem.eql(u8, args[i], "--update-guard")) {
            result.guard = true;
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
    run(init) catch |err| {
        const a = init.arena.allocator();
        const args = init.minimal.args.toSlice(a) catch &.{};
        const options = parseArgs(args) catch Args{};
        const db = options.db orelse paths.defaultDb(init.io, a) catch "kowalski.db";
        const message = logLaunchFailure(a, init.gpa, db, err);
        if (!options.background) launch.alert(a, message);
        std.process.exit(1);
    };
}

fn logLaunchFailure(a: std.mem.Allocator, gpa: std.mem.Allocator, db: []const u8, err: anyerror) []const u8 {
    const log_path = std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", "daemon.log" }) catch "daemon.log";
    const reason = switch (err) {
        error.WaitTimedOut => "previous daemon still running",
        error.WaitFailed => "could not wait for previous daemon",
        else => @errorName(err),
    };
    const message = std.fmt.allocPrint(a, "launcher: launch failed: {s}; log: {s}", .{ reason, log_path }) catch "launcher: launch failed";
    daemon.logBeforeStart(gpa, db, message) catch {};
    return message;
}

fn reportAbandoned(a: std.mem.Allocator, gpa: std.mem.Allocator, db: []const u8, background: bool, reason: []const u8, backup: []const u8, snapshot: []const u8) void {
    const log_path = std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", "daemon.log" }) catch "daemon.log";
    const message = std.fmt.allocPrint(a, "launcher: {s}; saved journal: {s}; database snapshot: {s}; log: {s}", .{ reason, backup, snapshot, log_path }) catch return;
    daemon.logBeforeStart(gpa, db, message) catch {};
    if (!background) launch.alert(a, message);
}

const LockWait = struct {
    context: *anyopaque,
    acquire: *const fn (*anyopaque) bool,
    pause: *const fn (*anyopaque) anyerror!void,
};

fn waitForUpdate(wait: LockWait) !bool {
    for (0..121) |attempt| {
        if (wait.acquire(wait.context)) return true;
        if (attempt == 120) break;
        try wait.pause(wait.context);
    }
    return false;
}

const RealLockWait = struct {
    io: std.Io,
    fn acquire(_: *anyopaque) bool {
        var held = update_lock.tryAcquire() orelse return false;
        held.release();
        return true;
    }
    fn pause(context: *anyopaque) !void {
        const self: *RealLockWait = @ptrCast(@alignCast(context));
        try self.io.sleep(.fromMilliseconds(250), .awake);
    }
    fn driver(self: *RealLockWait) LockWait {
        return .{ .context = self, .acquire = acquire, .pause = pause };
    }
};

fn pendingFromOtherVersion(value: update_journal.Journal) bool {
    return update_journal.needsRecovery(value) and !std.mem.eql(u8, value.from, @import("build_options").version);
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const options = try parseArgs(args);
    const db = options.db orelse try paths.defaultDb(init.io, a);
    if (options.after) |pid| {
        try waitForPrevious(pid);
    }
    if (options.guard) {
        var lock: ?update_lock.Lock = null;
        for (0..120) |_| {
            lock = update_lock.tryAcquire();
            if (lock != null) break;
            try init.io.sleep(.fromMilliseconds(250), .awake);
        }
        var held = lock orelse return error.UpdateInProgress;
        defer held.release();
        const dir = try launch.exeDir(a);
        update_guard.trial(a, init.io, db, dir, update_guard.realProbe()) catch |err| {
            if (try update_journal.read(a, init.io, db)) |saved| {
                if (update_journal.needsRecovery(saved)) {
                    var value = saved;
                    try update_guard.rollback(a, init.io, db, dir, &value, @errorName(err));
                    try launch.spawn(a, try std.fmt.allocPrint(a, "\"{s}\\kowalskiw.exe\" --background --db \"{s}\"", .{ dir, db }));
                }
            }
            return err;
        };
        return;
    }
    if (options.trial == null) {
        var waiter: RealLockWait = .{ .io = init.io };
        const ready = try waitForUpdate(waiter.driver());
        if (!ready) {
            const holder = update_journal.read(a, init.io, db) catch null;
            const pid = doctor.updateProcessPid() orelse if (holder) |saved| saved.candidate_pid else 0;
            const log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", "daemon.log" });
            const message = try std.fmt.allocPrint(a, "an update is still running (pid {d}); log: {s}", .{ pid, log_path });
            daemon.logBeforeStart(init.gpa, db, message) catch {};
            if (!options.background) launch.alert(a, message);
            return;
        }
        var pending = update_journal.read(a, init.io, db) catch |err| blk: {
            const backup = try update_journal.abandon(a, init.io, db, null, "unreadable journal", clock.nowMs());
            reportAbandoned(a, init.gpa, db, options.background, @errorName(err), backup, "unknown");
            break :blk null;
        };
        if (pending != null) {
            var recovering = false;
            for (0..121) |attempt| {
                recovering = update_guard.recoverOnLaunch(a, init.io, db) catch |err| blk: {
                    const snapshot = try std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", pending.?.snapshot });
                    const backup = try update_journal.abandon(a, init.io, db, pending, "rollback failed", clock.nowMs());
                    reportAbandoned(a, init.gpa, db, options.background, @errorName(err), backup, snapshot);
                    pending = null;
                    break :blk false;
                };
                if (!recovering) break;
                if (attempt == 120) {
                    const log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", "daemon.log" });
                    const message = try std.fmt.allocPrint(a, "an update is still running (pid {d}); log: {s}", .{ doctor.updateProcessPid() orelse pending.?.candidate_pid, log_path });
                    daemon.logBeforeStart(init.gpa, db, message) catch {};
                    if (!options.background) launch.alert(a, message);
                    return;
                }
                try init.io.sleep(.fromMilliseconds(250), .awake);
            }
        }
        if (pending) |value| if (pendingFromOtherVersion(value)) {
            try launch.spawn(a, try launch.backgroundCommand(a, db, null));
            if (options.background) return;
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

test "launch errors are logged beside a scratch database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const db = try std.fs.path.join(a, &.{ root, "k.db" });
    const message = logLaunchFailure(a, std.testing.allocator, db, error.TestLaunchFailure);
    try std.testing.expect(std.mem.indexOf(u8, message, "TestLaunchFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "daemon.log") != null);
    const logged = try tmp.dir.readFileAlloc(io, "daemon.log", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, logged, "TestLaunchFailure") != null);
}

test "update lock wait stops at 30 seconds or release" {
    const Fake = struct {
        attempts: usize = 0,
        pauses: usize = 0,
        release_after: usize,
        fn acquire(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.attempts += 1;
            return self.attempts >= self.release_after;
        }
        fn pause(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.pauses += 1;
        }
        fn driver(self: *@This()) LockWait { return .{ .context = self, .acquire = acquire, .pause = pause }; }
    };
    var released: Fake = .{ .release_after = 3 };
    try std.testing.expect(try waitForUpdate(released.driver()));
    try std.testing.expectEqual(@as(usize, 3), released.attempts);
    try std.testing.expectEqual(@as(usize, 2), released.pauses);
    var held: Fake = .{ .release_after = 999 };
    try std.testing.expect(!try waitForUpdate(held.driver()));
    try std.testing.expectEqual(@as(usize, 121), held.attempts);
    try std.testing.expectEqual(@as(usize, 120), held.pauses);
}

test "pending journal from another version keeps foreground opener path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const db = try std.fs.path.join(a, &.{ root, "k.db" });
    const journal: update_journal.Journal = .{
        .id = "0123456789abcdef0123456789abcdef", .from = "other-version", .to = "new-version", .phase = .swapped,
        .nonce = "abcdef0123456789abcdef0123456789", .snapshot = "snapshot.db", .exe_dir = ".", .started_ms = 1,
    };
    try update_journal.write(a, io, db, journal);
    const pending = (try update_journal.read(a, io, db)).?;
    try std.testing.expect(pendingFromOtherVersion(pending));
    try std.testing.expect(!@as(Args, .{}).background);
    var finished = pending;
    finished.phase = .rolled_back;
    try std.testing.expect(!pendingFromOtherVersion(finished));
}
