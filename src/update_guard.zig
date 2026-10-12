//! Guarded update trial and journal recovery. The old daemon owns the guard.
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const journal_mod = @import("update_journal.zig");
const snapshot = @import("update_snapshot.zig");
const update_lock = @import("update_lock.zig");
const launch = @import("launch.zig");
const sqlite = @import("sqlite.zig");
const api = @import("api.zig");
const clock = @import("clock.zig");

extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn TerminateProcess(windows.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) i32;
extern "winhttp" fn WinHttpOpen([*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpConnect(*anyopaque, [*:0]const u16, u16, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpOpenRequest(*anyopaque, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpSetTimeouts(*anyopaque, i32, i32, i32, i32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpSendRequest(*anyopaque, ?[*:0]const u16, u32, ?*const anyopaque, u32, u32, usize) callconv(.winapi) i32;
extern "winhttp" fn WinHttpReceiveResponse(*anyopaque, ?*anyopaque) callconv(.winapi) i32;
extern "winhttp" fn WinHttpQueryHeaders(*anyopaque, u32, ?[*:0]const u16, ?*anyopaque, *u32, ?*u32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpReadData(*anyopaque, [*]u8, u32, *u32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpCloseHandle(*anyopaque) callconv(.winapi) i32;

const HttpReply = struct { status: u32, body: []const u8 };

fn httpRequest(a: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, body: []const u8) !HttpReply {
    const agent = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("kowalski-update-guard"), 0, null, null, 0) orelse return error.Http;
    defer _ = WinHttpCloseHandle(agent);
    const connection = WinHttpConnect(agent, std.unicode.utf8ToUtf16LeStringLiteral("127.0.0.1"), port, 0) orelse return error.Http;
    defer _ = WinHttpCloseHandle(connection);
    const method_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, method);
    const path_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    const request = WinHttpOpenRequest(connection, method_wide, path_wide, null, null, null, 0) orelse return error.Http;
    defer _ = WinHttpCloseHandle(request);
    if (WinHttpSetTimeouts(request, 500, 500, 500, 500) == 0) return error.Http;
    const headers = std.unicode.utf8ToUtf16LeStringLiteral("X-Kowalski: 1\r\nContent-Type: application/json\r\n");
    if (WinHttpSendRequest(request, headers, 0xffffffff, if (body.len == 0) null else body.ptr, @intCast(body.len), @intCast(body.len), 0) == 0) return error.Http;
    if (WinHttpReceiveResponse(request, null) == 0) return error.Http;
    var status: u32 = 0;
    var length: u32 = @sizeOf(u32);
    if (WinHttpQueryHeaders(request, 19 | 0x20000000, null, &status, &length, null) == 0) return error.Http;
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        var buffer: [1024]u8 = undefined;
        var count: u32 = 0;
        if (WinHttpReadData(request, &buffer, buffer.len, &count) == 0) return error.Http;
        if (count == 0) break;
        if (bytes.items.len + count > 4096) return error.HttpTooLarge;
        try bytes.appendSlice(a, buffer[0..count]);
    }
    return .{ .status = status, .body = bytes.items };
}

fn httpReady(_: *anyopaque, a: std.mem.Allocator, port: u16) !?Ready {
    const response = try httpRequest(a, port, "GET", "/api/update/ready", "");
    if (response.status != 200) return null;
    const body = try std.json.parseFromSliceLeaky(struct { nonce: []const u8, pid: u32 }, a, response.body, .{ .ignore_unknown_fields = true });
    return .{ .nonce = body.nonce, .pid = body.pid };
}

fn httpCommit(_: *anyopaque, a: std.mem.Allocator, port: u16, nonce: []const u8) !bool {
    const body = try std.json.Stringify.valueAlloc(a, .{ .nonce = nonce }, .{});
    return (try httpRequest(a, port, "POST", "/api/update/commit", body)).status == 200;
}

pub fn realProbe() Probe {
    return .{ .context = @ptrFromInt(1), .ready = httpReady, .commit = httpCommit };
}

fn snapshotPath(a: std.mem.Allocator, db_path: []const u8, name: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(name) or !std.mem.eql(u8, std.fs.path.basename(name), name)) return error.MalformedJournal;
    return std.fs.path.join(a, &.{ std.fs.path.dirname(db_path) orelse ".", name });
}

fn replace(a: std.mem.Allocator, source: []const u8, dest: []const u8) !void {
    const from = try std.unicode.utf8ToUtf16LeAllocZ(a, source);
    defer a.free(from);
    const to = try std.unicode.utf8ToUtf16LeAllocZ(a, dest);
    defer a.free(to);
    if (MoveFileExW(from, to, 1 | 8) == 0) return error.ExeRestore;
}

pub fn restoreExecutables(a: std.mem.Allocator, io: Io, exe_dir: []const u8) !void {
    const cwd = Io.Dir.cwd();
    for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
        const current = try std.fs.path.join(a, &.{ exe_dir, name });
        const old = try std.fmt.allocPrint(a, "{s}.old", .{current});
        if (cwd.statFile(io, old, .{})) |_| {
            try replace(a, old, current);
        } else |err| if (err != error.FileNotFound) return err;
    }
}

fn stopCandidate(pid: u32) void {
    if (pid == 0) return;
    const process = OpenProcess(0x00100000 | 0x0001, 0, pid) orelse return;
    defer _ = CloseHandle(process);
    if (WaitForSingleObject(process, 0) == 0x102) _ = TerminateProcess(process, 1);
    _ = WaitForSingleObject(process, 10_000);
}

/// Idempotent after an interrupted rollback: each .old that remains is restored.
pub fn rollback(a: std.mem.Allocator, io: Io, db_path: []const u8, exe_dir: []const u8, value: *journal_mod.Journal, reason: []const u8) !void {
    const had_trial = value.phase == .trial or value.phase == .rolling_back;
    value.phase = .rolling_back;
    value.reason = reason;
    try journal_mod.write(a, io, db_path, value.*);
    stopCandidate(value.candidate_pid);
    try restoreExecutables(a, io, exe_dir);
    const path = try snapshotPath(a, db_path, value.snapshot);
    if (had_trial and (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null) {
        try snapshot.restore(a, io, db_path, path);
    }
    value.phase = .rolled_back;
    value.ack = false;
    try journal_mod.write(a, io, db_path, value.*);
}

/// Returns true when another process (the guard) owns recovery and startup exits.
pub fn recoverOnLaunch(a: std.mem.Allocator, io: Io, db_path: []const u8) !bool {
    var value = (try journal_mod.read(a, io, db_path)) orelse return false;
    if (!journal_mod.needsRecovery(value)) return false;
    var lock = update_lock.tryAcquire() orelse return true;
    defer lock.release();
    const exe_dir = try launch.exeDir(a);
    try rollback(a, io, db_path, exe_dir, &value, "interrupted update");
    return false;
}

fn readPort(a: std.mem.Allocator, db_path: []const u8) u16 {
    _ = a;
    var db: sqlite.Db = .{};
    db.openReadOnly(db_path) catch return api.default_port;
    defer db.close();
    var statement = db.prepare("SELECT value FROM settings WHERE key='http_port'") catch return api.default_port;
    defer statement.finalize();
    if ((statement.step() catch return api.default_port) == .done) return api.default_port;
    return std.fmt.parseInt(u16, statement.columnText(0).?, 10) catch api.default_port;
}

pub const Ready = struct { nonce: []const u8, pid: u32 };
pub const Probe = struct {
    context: *anyopaque,
    ready: *const fn (*anyopaque, std.mem.Allocator, u16) anyerror!?Ready,
    commit: *const fn (*anyopaque, std.mem.Allocator, u16, []const u8) anyerror!bool,
};

pub const Driver = struct {
    context: *anyopaque,
    take_snapshot: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    launch_trial: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!u32,
    alive: *const fn (*anyopaque) bool,
    kill: *const fn (*anyopaque) void,
    start_old: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!void,
    pause: *const fn (*anyopaque, u32) anyerror!void,
    now: *const fn (*anyopaque) i64,
    probe: Probe,
};

const Real = struct {
    io: Io,
    child: ?launch.Child = null,

    fn takeSnapshot(_: *anyopaque, db_path: []const u8, path: []const u8) !void { try snapshot.snapshot(db_path, path); }
    fn launchTrial(context: *anyopaque, a: std.mem.Allocator, db_path: []const u8, exe_dir: []const u8, nonce: []const u8) !u32 {
        const self: *Real = @ptrCast(@alignCast(context));
        const command = try std.fmt.allocPrint(a, "\"{s}\\kowalskiw.exe\" --background --db \"{s}\" --trial {s}", .{ exe_dir, db_path, nonce });
        self.child = try launch.spawnTracked(a, command);
        return self.child.?.pid;
    }
    fn alive(context: *anyopaque) bool {
        const self: *Real = @ptrCast(@alignCast(context));
        return self.child.?.alive();
    }
    fn kill(context: *anyopaque) void {
        const self: *Real = @ptrCast(@alignCast(context));
        if (self.child) |child| child.terminate();
    }
    fn startOld(_: *anyopaque, a: std.mem.Allocator, db_path: []const u8, exe_dir: []const u8) !void {
        try launch.spawn(a, try std.fmt.allocPrint(a, "\"{s}\\kowalskiw.exe\" --background --db \"{s}\"", .{ exe_dir, db_path }));
    }
    fn pause(context: *anyopaque, milliseconds: u32) !void {
        const self: *Real = @ptrCast(@alignCast(context));
        try self.io.sleep(.fromMilliseconds(milliseconds), .awake);
    }
    fn now(_: *anyopaque) i64 { return clock.nowMs(); }
};

pub fn trial(a: std.mem.Allocator, io: Io, db_path: []const u8, exe_dir: []const u8, probe: Probe) !void {
    var real: Real = .{ .io = io };
    defer if (real.child) |*child| child.close();
    try runTrial(a, io, db_path, exe_dir, .{
        .context = &real, .take_snapshot = Real.takeSnapshot, .launch_trial = Real.launchTrial,
        .alive = Real.alive, .kill = Real.kill, .start_old = Real.startOld,
        .pause = Real.pause, .now = Real.now, .probe = probe,
    });
}

pub fn runTrial(a: std.mem.Allocator, io: Io, db_path: []const u8, exe_dir: []const u8, driver: Driver) !void {
    var value = (try journal_mod.read(a, io, db_path)) orelse return error.MissingJournal;
    if (value.phase != .swapped) return error.BadPhase;
    const path = try snapshotPath(a, db_path, value.snapshot);
    try driver.take_snapshot(driver.context, db_path, path);
    value.phase = .trial;
    try journal_mod.write(a, io, db_path, value);
    const pid = driver.launch_trial(driver.context, a, db_path, exe_dir, value.nonce) catch |err| {
        try rollback(a, io, db_path, exe_dir, &value, @errorName(err));
        try driver.start_old(driver.context, a, db_path, exe_dir);
        return err;
    };
    value.candidate_pid = pid;
    try journal_mod.write(a, io, db_path, value);
    const port = readPort(a, db_path);
    const deadline = driver.now(driver.context) + 120_000;
    var reason: []const u8 = "readiness timeout";
    var ready = false;
    while (driver.now(driver.context) < deadline) {
        if (!driver.alive(driver.context)) { reason = "candidate exited before readiness"; break; }
        if (driver.probe.ready(driver.probe.context, a, port) catch null) |response| {
            if (!std.mem.eql(u8, response.nonce, value.nonce) or response.pid != pid) { reason = "wrong readiness identity"; break; }
            ready = true;
            break;
        }
        try driver.pause(driver.context, 250);
    }
    if (ready) {
        const stable_until = driver.now(driver.context) + 10_000;
        while (driver.now(driver.context) < stable_until) {
            if (!driver.alive(driver.context)) { reason = "candidate exited during stability"; ready = false; break; }
            const response = driver.probe.ready(driver.probe.context, a, port) catch null;
            if (response == null or !std.mem.eql(u8, response.?.nonce, value.nonce) or response.?.pid != pid) {
                reason = "candidate lost readiness"; ready = false; break;
            }
            try driver.pause(driver.context, 500);
        }
    }
    if (ready) {
        ready = driver.probe.commit(driver.probe.context, a, port, value.nonce) catch false;
        if (!ready) reason = "commit refused";
    }
    if (!ready) {
        driver.kill(driver.context);
        value.candidate_pid = 0;
        try rollback(a, io, db_path, exe_dir, &value, reason);
        try driver.start_old(driver.context, a, db_path, exe_dir);
        return error.TrialFailed;
    }
    value.phase = .committed;
    value.ack = false;
    try journal_mod.write(a, io, db_path, value);
}

test "journal recovery restores both executables and eligible snapshot" {
    const io = std.testing.io;
    for ([_]journal_mod.Phase{ .swapped, .trial, .rolling_back }) |phase| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
        const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = db_path, .data = "candidate data" });
        try tmp.dir.writeFile(io, .{ .sub_path = "update-snapshot-0123456789abcdef0123456789abcdef.db", .data = "original data" });
        for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "new" });
            try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.old", .{name}), .data = "old" });
        }
        var value: journal_mod.Journal = .{
            .id = "0123456789abcdef0123456789abcdef", .from = "1.0.0", .to = "1.1.0", .phase = phase,
            .nonce = "abcdef0123456789abcdef0123456789", .snapshot = "update-snapshot-0123456789abcdef0123456789abcdef.db",
            .exe_dir = ".", .started_ms = 1,
        };
        try journal_mod.write(a, io, db_path, value);
        try rollback(a, io, db_path, root, &value, "test failure");
        try std.testing.expectEqual(journal_mod.Phase.rolled_back, (try journal_mod.read(a, io, db_path)).?.phase);
        for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
            try std.testing.expectEqualStrings("old", try tmp.dir.readFileAlloc(io, name, a, .limited(100)));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, try std.fmt.allocPrint(a, "{s}.old", .{name}), .{}));
        }
        try std.testing.expectEqualStrings(if (phase == .swapped) "candidate data" else "original data", try cwd.readFileAlloc(io, db_path, a, .limited(100)));
    }
}

const Fake = struct {
    const Mode = enum { healthy, never_ready, exits, wrong_nonce };
    mode: Mode,
    time_ms: i64 = 0,
    ready_calls: usize = 0,
    killed: bool = false,
    old_started: bool = false,
    launched: bool = false,

    fn takeSnapshot(_: *anyopaque, db_path: []const u8, path: []const u8) !void {
        try Io.Dir.copyFile(Io.Dir.cwd(), db_path, Io.Dir.cwd(), path, std.testing.io, .{});
    }
    fn launchTrial(context: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !u32 {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.launched = true;
        return 123456;
    }
    fn alive(context: *anyopaque) bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        return !self.killed and !(self.mode == .exits and self.ready_calls > 1);
    }
    fn kill(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.killed = true;
    }
    fn startOld(context: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.old_started = true;
    }
    fn pause(context: *anyopaque, milliseconds: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.time_ms += milliseconds;
    }
    fn now(context: *anyopaque) i64 {
        const self: *Fake = @ptrCast(@alignCast(context));
        return self.time_ms;
    }
    fn ready(context: *anyopaque, _: std.mem.Allocator, _: u16) !?Ready {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.ready_calls += 1;
        if (self.mode == .never_ready) return null;
        return .{ .nonce = if (self.mode == .wrong_nonce) "00000000000000000000000000000000" else "abcdef0123456789abcdef0123456789", .pid = 123456 };
    }
    fn commit(context: *anyopaque, _: std.mem.Allocator, _: u16, _: []const u8) !bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        return self.mode == .healthy;
    }
    fn driver(self: *Fake) Driver {
        return .{ .context = self, .take_snapshot = takeSnapshot, .launch_trial = launchTrial,
            .alive = alive, .kill = kill, .start_old = startOld, .pause = pause, .now = now,
            .probe = .{ .context = self, .ready = ready, .commit = commit } };
    }
};

test "guard trial commits healthy child and rolls back failure cases" {
    const io = std.testing.io;
    for ([_]Fake.Mode{ .healthy, .never_ready, .exits, .wrong_nonce }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
        const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
        try tmp.dir.writeFile(io, .{ .sub_path = "work.db", .data = "original data" });
        for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "new" });
            try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.old", .{name}), .data = "old" });
        }
        const value: journal_mod.Journal = .{
            .id = "0123456789abcdef0123456789abcdef", .from = "1.0.0", .to = "1.1.0", .phase = .swapped,
            .nonce = "abcdef0123456789abcdef0123456789", .snapshot = "update-snapshot-0123456789abcdef0123456789abcdef.db",
            .exe_dir = ".", .started_ms = 1,
        };
        try journal_mod.write(a, io, db_path, value);
        var fake: Fake = .{ .mode = mode };
        if (mode == .healthy) {
            try runTrial(a, io, db_path, root, fake.driver());
        } else {
            try std.testing.expectError(error.TrialFailed, runTrial(a, io, db_path, root, fake.driver()));
        }
        const result = (try journal_mod.read(a, io, db_path)).?;
        try std.testing.expect(fake.launched);
        try std.testing.expectEqual(if (mode == .healthy) journal_mod.Phase.committed else journal_mod.Phase.rolled_back, result.phase);
        try std.testing.expectEqual(mode != .healthy, fake.old_started);
        try std.testing.expectEqual(mode != .healthy, fake.killed);
        if (mode != .healthy) {
            try std.testing.expect(result.reason.len > 0);
            try std.testing.expectEqualStrings("old", try tmp.dir.readFileAlloc(io, "kowalskiw.exe", a, .limited(100)));
        }
    }
}
