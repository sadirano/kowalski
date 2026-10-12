//! `kowalski serve`: one daemon per user. It owns the database, recovers at
//! start, writes the heartbeat and answers the loopback HTTP API.
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const sqlite = @import("sqlite.zig");
const store_mod = @import("store.zig");
const api = @import("api.zig");
const zone = @import("zone.zig");
const clock = @import("clock.zig");
const events = @import("events.zig");
const worker = @import("worker.zig");
const contract = @import("kowalski_provider");
const provider_loader = @import("provider_loader.zig");
const tour_mod = @import("tour.zig");
const demo = @import("demo.zig");
const launch = @import("launch.zig");
const update = @import("update.zig");

extern "kernel32" fn CreateMutexW(attributes: ?*anyopaque, initial_owner: i32, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn WriteFile(file: windows.HANDLE, data: [*]const u8, len: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(file: windows.HANDLE, size: *i64) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;

const error_already_exists: u32 = 183;
const heartbeat_ms: i64 = 60_000;
const max_body: usize = 64 * 1024;
/// How long a console close, logoff or shutdown waits for state to be saved.
const close_grace_ms: i64 = 4_000;
/// How long a request waits for one provider call; the call itself goes on.
const provider_deadline_ms: i64 = 30_000;
/// A log over this size is moved to `<log>.1` at start, replacing the old one.
const max_log_bytes: i64 = 1024 * 1024;

pub const Options = struct {
    db_path: []const u8,
    trial_nonce: ?[]const u8 = null,
    /// Append the log here instead of stderr (the windowless daemon has none).
    log_path: ?[]const u8 = null,
};

const Daemon = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// Serializes every use of the database connection.
    mutex: Io.Mutex = .init,
    app: api.App,
    provider: ?worker.Worker = null,
    provider_table: ?*contract.Table = null,
    provider_file: ?provider_loader.Verified = null,
    db_path: []const u8,
    traits_allocator: std.mem.Allocator,
    /// One request's provider call at a time; the worker refuses a second.
    provider_turn: Io.Mutex = .init,
    stop: Io.Event = .unset,
    stopped: Io.Event = .unset,
    /// The guided tour's sandbox while one runs, served under /tour/api/.
    tour: ?*tour_mod.Tour = null,
    tour_path: []const u8 = "",
};

// The console control handler runs on a thread Windows creates; it can only
// reach the daemon through these.
var active: ?*Daemon = null;

fn controlHandler(kind: u32) callconv(.winapi) i32 {
    const d = active orelse return 0;
    switch (kind) {
        0, 1 => { // Ctrl+C, Ctrl+Break
            d.stop.set(d.io);
            return 1;
        },
        2, 5, 6 => { // close, logoff, shutdown: Windows ends the process when this returns
            d.stop.set(d.io);
            d.stopped.waitTimeout(d.io, .{ .duration = .{ .raw = .fromMilliseconds(close_grace_ms), .clock = .awake } }) catch {};
            return 1;
        },
        else => return 0,
    }
}

var log_file: ?windows.HANDLE = null;

fn log(comptime fmt: []const u8, args: anytype) void {
    const file = log_file orelse return std.debug.print("kowalski: " ++ fmt ++ "\n", args);
    var buffer: [1024]u8 = undefined;
    const now = clock.nowMs();
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(now, 1000)) };
    const date = seconds.getEpochDay().calculateYearDay();
    const month = date.calculateMonthDay();
    const time = seconds.getDaySeconds();
    var w: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    w.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z ", .{
        date.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    }) catch {};
    // A line that does not fit is cut, never dropped.
    w.print(fmt, args) catch {};
    buffer[w.end] = '\n';
    // One append-mode write per line, so lines from different threads never mix.
    _ = WriteFile(file, &buffer, @intCast(w.end + 1), null, null);
}

fn openLog(gpa: std.mem.Allocator, path: []const u8) !void {
    const name = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(name);
    const old_path = try std.fmt.allocPrint(gpa, "{s}.1", .{path});
    defer gpa.free(old_path);
    const old = try std.unicode.utf8ToUtf16LeAllocZ(gpa, old_path);
    defer gpa.free(old);
    const access = 0x0004 | 0x0080; // FILE_APPEND_DATA, FILE_READ_ATTRIBUTES (for the size)
    const share_all = 0x7;
    const open_always = 4;
    const normal = 0x80;
    const replace_existing = 0x1;
    var handle = CreateFileW(name, access, share_all, null, open_always, normal, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.LogFile;
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) != 0 and size > max_log_bytes) {
        _ = CloseHandle(handle);
        _ = MoveFileExW(name, old, replace_existing);
        handle = CreateFileW(name, access, share_all, null, open_always, normal, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.LogFile;
    }
    log_file = handle;
}

/// Log a failed delayed start before the new daemon has opened its own log.
pub fn logBeforeStart(gpa: std.mem.Allocator, db_path: []const u8, message: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(db_path) orelse ".", "daemon.log" });
    defer gpa.free(path);
    try openLog(gpa, path);
    defer if (log_file) |file| {
        log_file = null;
        _ = CloseHandle(file);
    };
    log("{s}", .{message});
}

fn onEvent(context: *anyopaque, kind: events.Kind) void {
    const d: *Daemon = @ptrCast(@alignCast(context));
    if (kind == .ending) {
        log("session ending", .{});
        d.stop.set(d.io);
        d.stopped.waitTimeout(d.io, .{ .duration = .{ .raw = .fromMilliseconds(close_grace_ms), .clock = .awake } }) catch {};
        return;
    }
    d.mutex.lockUncancelable(d.io);
    defer d.mutex.unlock(d.io);
    if (!shouldHeartbeat(&d.app)) return;
    const now = clock.nowMs();
    const store = d.app.store;
    switch (kind) {
        // A heartbeat at suspend makes resume close intervals at that moment.
        .suspending => store.onHeartbeat(now) catch |err| log("suspend heartbeat failed: {s}", .{@errorName(err)}),
        .resumed => {
            store.onResume(now) catch |err| return log("resume recovery failed: {s}", .{@errorName(err)});
            log("resumed: anything open was closed at the last heartbeat", .{});
        },
        .locked => {
            const paused = store.onLock(now) catch |err| return log("lock handling failed: {s}", .{@errorName(err)});
            if (paused) log("screen locked in a lock window: paused", .{});
        },
        .ending => unreachable,
    }
}

fn onLate(context: *anyopaque, posting: i64, done: worker.Done) void {
    const d: *Daemon = @ptrCast(@alignCast(context));
    var arena = std.heap.ArenaAllocator.init(d.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    d.mutex.lockUncancelable(d.io);
    const line = api.lateResult(&d.app, a, posting, done) catch |err| {
        d.mutex.unlock(d.io);
        log("late posting #{d} update failed: {s}", .{ posting, @errorName(err) });
        return;
    };
    d.mutex.unlock(d.io);
    log("{s}", .{line});
}

pub fn serve(io: Io, gpa: std.mem.Allocator, options: Options) !void {
    if (options.log_path) |path| try openLog(gpa, path);
    defer if (log_file) |file| {
        log_file = null;
        _ = CloseHandle(file);
    };
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\sadirano-kowalski-daemon");
    const instance = CreateMutexW(null, 0, name) orelse return error.InstanceMutex;
    defer _ = CloseHandle(instance);
    if (GetLastError() == error_already_exists) {
        log("the daemon is already running", .{});
        return error.AlreadyRunning;
    }

    var db: sqlite.Db = .{};
    db.open(options.db_path) catch |err| {
        log("cannot open {s}: {s}", .{ options.db_path, db.message() });
        return err;
    };
    defer db.close();
    var store = try store_mod.Store.init(&db, gpa);
    try store.onStart(clock.nowMs());
    if (try store.reportingZone()) |id| {
        gpa.free(id);
    } else {
        const id = try zone.currentId(gpa);
        defer gpa.free(id);
        try store.setSetting("reporting_zone", id, clock.nowMs());
        log("reporting zone set to {s}", .{id});
    }
    const port = blk: {
        const value = try store.getSetting("http_port") orelse break :blk api.default_port;
        defer gpa.free(value);
        break :blk try std.fmt.parseInt(u16, value, 10);
    };

    var traits_arena = std.heap.ArenaAllocator.init(gpa);
    defer traits_arena.deinit();
    var d: Daemon = .{ .io = io, .gpa = gpa, .db_path = options.db_path, .traits_allocator = traits_arena.allocator(), .app = .{ .store = &store, .port = port, .clock = clock.nowMs, .running_post = worker.runningPost, .trial_nonce = options.trial_nonce } };
    // The tour's sandbox sits next to the database and never outlives a run.
    const tour_path = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(options.db_path) orelse ".", tour_mod.file_name });
    defer gpa.free(tour_path);
    tour_mod.removeFiles(io, tour_path);
    d.tour_path = tour_path;
    defer if (d.tour) |t| t.destroy(io);
    defer if (d.provider_file) |file| provider_loader.close(file);
    defer if (d.provider_table) |table| {
        if (worker.idle()) {
            table.deinit(table.context);
            std.heap.page_allocator.destroy(table);
        }
    };
    try startProvider(&d);
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = address.listen(io, .{}) catch |err| {
        log("cannot listen on 127.0.0.1:{d}: {s}", .{ port, @errorName(err) });
        return err;
    };
    defer listener.deinit(io);

    active = &d;
    defer active = null;
    // Without a console (kowalskiw) the event window's end-session message stands in.
    if (SetConsoleCtrlHandler(controlHandler, 1) == 0) log("no console control handler", .{});
    defer _ = SetConsoleCtrlHandler(controlHandler, 0);
    var window = events.Window.start(&d, onEvent) catch |err| {
        log("cannot create the event window: {s}", .{@errorName(err)});
        return err;
    };

    var connections: Io.Group = .init;
    d.app.trial_ready = true;
    var accept_future = try io.concurrent(acceptLoop, .{ &d, &listener, &connections });
    var heartbeat_future = try io.concurrent(heartbeatLoop, .{&d});
    log("listening on http://127.0.0.1:{d} (database {s})", .{ port, options.db_path });
    if (options.trial_nonce == null) update.cleanup(gpa, io, options.db_path) catch |err| log("update cleanup failed: {s}", .{@errorName(err)});

    d.stop.waitUncancelable(io);

    accept_future.cancel(io) catch {};
    connections.cancel(io);
    heartbeat_future.cancel(io) catch {};
    {
        d.mutex.lockUncancelable(io);
        defer d.mutex.unlock(io);
        if (shouldHeartbeat(&d.app)) store.onHeartbeat(clock.nowMs()) catch |err| log("final heartbeat failed: {s}", .{@errorName(err)});
    }
    log("stopped", .{});
    d.stopped.set(io);
    // After `stopped`: an end-session handler waiting on it holds the window thread.
    window.stop();
}

fn printableAscii(a: std.mem.Allocator, source: []const u8, limit: usize) ![]const u8 {
    const result = try a.alloc(u8, @min(source.len, limit));
    for (result, source[0..result.len]) |*dest, c| dest.* = if (std.ascii.isPrint(c)) c else '?';
    return result;
}

const Trust = struct { sha: []const u8, last_good: ?[]const u8, loading: ?[]const u8 };

fn readTrust(db: *sqlite.Db, a: std.mem.Allocator) !?Trust {
    var stmt = try db.prepare("SELECT sha256,last_good,loading FROM provider_trust WHERE id=1");
    defer stmt.finalize();
    if (try stmt.step() == .done) return null;
    return .{
        .sha = try a.dupe(u8, stmt.columnText(0).?),
        .last_good = if (stmt.columnText(1)) |value| try a.dupe(u8, value) else null,
        .loading = if (stmt.columnText(2)) |value| try a.dupe(u8, value) else null,
    };
}

fn markLoading(db: *sqlite.Db, sha: ?[]const u8) !void {
    var stmt = try db.prepare("UPDATE provider_trust SET loading=?1 WHERE id=1");
    defer stmt.finalize();
    try stmt.bindOptionalText(1, sha);
    _ = try stmt.step();
}

fn markGood(db: *sqlite.Db, sha: []const u8) !void {
    var stmt = try db.prepare("UPDATE provider_trust SET loading=NULL,last_good=?1 WHERE id=1");
    defer stmt.finalize();
    try stmt.bindText(1, sha);
    _ = try stmt.step();
}

fn approveTrust(db: *sqlite.Db, sha: []const u8, how: []const u8) !void {
    var stmt = try db.prepare("INSERT INTO provider_trust(id,sha256,how,approved_ms,loading) VALUES(1,?1,?2,?3,NULL) ON CONFLICT(id) DO UPDATE SET sha256=excluded.sha256,how=excluded.how,approved_ms=excluded.approved_ms,loading=NULL");
    defer stmt.finalize();
    try stmt.bindText(1, sha);
    try stmt.bindText(2, how);
    try stmt.bindI64(3, clock.nowMs());
    _ = try stmt.step();
}

fn startProvider(d: *Daemon) !void {
    const a = d.traits_allocator;
    const result = provider_loader.scan(d.io, a, d.db_path) catch |err| {
        d.app.provider_status = .{ .state = .unavailable, .reason = try std.fmt.allocPrint(a, "provider scan failed: {s}", .{@errorName(err)}) };
        return;
    };
    switch (result) {
        .none => return,
        .multiple => d.app.provider_status = .{ .state = .unavailable, .reason = "more than one DLL in the providers folder" },
        .candidate => |scanned| {
            var candidate = scanned;
            // Verify the cache even before displaying metadata as an approvable candidate.
            const checked = provider_loader.verified(a, d.db_path, candidate.sha256) catch |err| {
                d.app.provider_status = .{ .state = .unavailable, .reason = try std.fmt.allocPrint(a, "provider cache failed: {s}", .{@errorName(err)}) };
                return;
            };
            candidate.version = try provider_loader.versionInfo(a, checked.path);
            provider_loader.close(checked);
            const trust = try readTrust(d.app.store.db, a);
            if (trust == null or !std.mem.eql(u8, trust.?.sha, candidate.sha256)) {
                d.app.provider_status = .{ .state = .awaiting_approval, .candidate = candidate };
                if (trust) |previous| if (previous.last_good) |good| {
                    if (provider_loader.validHash(good)) {
                        try loadHash(d, good);
                        if (d.app.provider != null) d.app.provider_status.candidate = candidate;
                    }
                };
                return;
            }
            if (trust.?.loading) |loading| if (std.mem.eql(u8, loading, candidate.sha256)) {
                d.app.provider_status = .{ .state = .unavailable, .reason = "the provider stopped kowalski while starting; approve it again to retry", .candidate = candidate };
                return;
            };
            try loadHash(d, candidate.sha256);
        },
    }
}

fn loadHash(d: *Daemon, sha: []const u8) !void {
    const a = d.traits_allocator;
    const trust = try readTrust(d.app.store.db, a);
    if (trust) |current| if (current.loading) |loading| if (std.mem.eql(u8, loading, sha)) {
        d.app.provider_status.state = .unavailable;
        d.app.provider_status.reason = "the provider stopped kowalski while starting; approve it again to retry";
        return;
    };
    const verified = provider_loader.verified(a, d.db_path, sha) catch |err| {
        d.app.provider_status.state = .unavailable;
        d.app.provider_status.reason = try std.fmt.allocPrint(a, "provider cache failed: {s}", .{@errorName(err)});
        return;
    };
    var keep_file = false;
    defer if (!keep_file) provider_loader.close(verified);
    try markLoading(d.app.store.db, sha);
    defer markLoading(d.app.store.db, null) catch {};
    const module = provider_loader.load(a, verified) catch |err| {
        d.app.provider_status.state = .unavailable;
        d.app.provider_status.reason = try std.fmt.allocPrint(a, "provider DLL failed: {s}", .{@errorName(err)});
        return;
    };
    // Once Windows has loaded the module, retain the read lock for this process.
    d.provider_file = verified;
    keep_file = true;
    const table = module.entry(contract.version) orelse {
        d.app.provider_status = .{ .state = .unavailable, .reason = "provider speaks a different contract version", .candidate = d.app.provider_status.candidate };
        return;
    };
    if (table.version != contract.version) {
        d.app.provider_status = .{ .state = .unavailable, .reason = "provider speaks a different contract version", .candidate = d.app.provider_status.candidate };
        return;
    }
    const instance = table.instance.slice();
    if (instance.len == 0 or instance.len > 128) {
        d.app.provider_status.state = .unavailable;
        d.app.provider_status.reason = "invalid provider instance";
        return;
    }
    for (instance) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
        d.app.provider_status.state = .unavailable;
        d.app.provider_status.reason = "invalid provider instance";
        return;
    };
    const InfoShape = struct { name: []const u8, build: []const u8 };
    const info = std.json.parseFromSliceLeaky(InfoShape, a, module.info().slice(), .{ .ignore_unknown_fields = true }) catch null;
    if (info) |metadata| {
        d.app.provider_status.name = try printableAscii(a, metadata.name, 128);
        d.app.provider_status.build = try printableAscii(a, metadata.build, 128);
    }
    const data_dir = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(d.db_path) orelse ".", "providers", instance });
    try std.Io.Dir.cwd().createDirPath(d.io, data_dir);
    const config = try std.json.Stringify.valueAlloc(a, .{ .contract = contract.version, .data_dir = data_dir }, .{});
    var context: ?*anyopaque = null;
    const status = table.init(table.context, .of(config), &context);
    defer if (status.message.ptr != null) table.free(context, status.message);
    if (status.code != 0) {
        const message = try printableAscii(a, status.message.slice(), 200);
        d.app.provider_status.state = .unavailable;
        d.app.provider_status.reason = try std.fmt.allocPrint(a, "init failed: {s}", .{message});
        return;
    }
    const copy = try std.heap.page_allocator.create(contract.Table);
    copy.* = table.*;
    copy.context = context;
    d.provider_table = copy;
    d.provider = .{ .table = copy, .io = d.io, .late = onLate, .late_context = d };
    d.app.provider = copy.instance.slice();
    d.app.provider_status.state = .loaded;
    d.app.provider_status.reason = "";
    try d.app.store.setSetting("provider_instance", copy.instance.slice(), clock.nowMs());
    d.app.traits = api.parseTraits(a, copy.traits.slice());
    try markGood(d.app.store.db, sha);
    log("provider: {s}", .{copy.instance.slice()});
}

test "provider status text is printable and capped" {
    const value = try printableAscii(std.testing.allocator, "a\x00\n\xffb", 4);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("a???", value);
}

test "provider DLL discovery, approval, fallback and retry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
    const drop_dir = try std.fs.path.join(a, &.{ root, "providers" });
    const drop = try std.fs.path.join(a, &.{ drop_dir, "sample.dll" });
    var db: sqlite.Db = .{};
    try db.open(db_path);
    defer db.close();
    var store = try store_mod.Store.init(&db, a);
    var first: Daemon = .{ .io = io, .gpa = a, .db_path = db_path, .traits_allocator = a, .app = .{ .store = &store, .port = api.default_port, .clock = clock.nowMs } };
    try startProvider(&first);
    try std.testing.expectEqual(.none, first.app.provider_status.state);

    try std.Io.Dir.cwd().createDirPath(io, drop_dir);
    const source = @import("provider_test_options").example_dll;
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), drop, io, .{});
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(16 * 1024 * 1024));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source_bytes, &digest, .{});
    const expected_hex = std.fmt.bytesToHex(digest, .lower);
    try startProvider(&first);
    try std.testing.expectEqual(.awaiting_approval, first.app.provider_status.state);
    const candidate = first.app.provider_status.candidate.?;
    try std.testing.expectEqualStrings(&expected_hex, candidate.sha256);
    try std.testing.expectEqual(@as(u64, source_bytes.len), candidate.size);
    const wrong = api.Request{ .method = .POST, .target = "/api/provider/approve", .host = "127.0.0.1:47100", .marker = true, .body = "{\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"how\":\"compared\"}" };
    try std.testing.expectEqual(std.http.Status.conflict, providerCommand(&first, a, wrong).?.status);
    const approval_body = try std.json.Stringify.valueAlloc(a, .{ .sha256 = candidate.sha256, .how = "compared" }, .{});
    const approval = api.Request{ .method = .POST, .target = "/api/provider/approve", .host = "127.0.0.1:47100", .marker = true, .body = approval_body };
    const approved = providerCommand(&first, a, approval).?;
    try std.testing.expectEqual(std.http.Status.ok, approved.status);
    try std.testing.expect(std.mem.indexOf(u8, approved.body, "\"restart\":false") != null);
    try std.testing.expectEqual(.loaded, first.app.provider_status.state);
    try std.testing.expectEqualStrings("example", first.app.provider_status.name);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = drop, .data = "different bytes" });
    var second: Daemon = .{ .io = io, .gpa = a, .db_path = db_path, .traits_allocator = a, .app = .{ .store = &store, .port = api.default_port, .clock = clock.nowMs } };
    try startProvider(&second);
    try std.testing.expectEqual(.loaded, second.app.provider_status.state);
    try std.testing.expect(second.app.provider_status.candidate != null);
    try std.testing.expect(!std.mem.eql(u8, candidate.sha256, second.app.provider_status.candidate.?.sha256));

    const extra = try std.fs.path.join(a, &.{ drop_dir, "extra.dll" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = extra, .data = "other" });
    var third: Daemon = .{ .io = io, .gpa = a, .db_path = db_path, .traits_allocator = a, .app = .{ .store = &store, .port = api.default_port, .clock = clock.nowMs } };
    try startProvider(&third);
    try std.testing.expectEqual(.unavailable, third.app.provider_status.state);
    try std.testing.expectEqualStrings("more than one DLL in the providers folder", third.app.provider_status.reason);

    try std.Io.Dir.cwd().deleteFile(io, extra);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), drop, io, .{ .replace = true });
    try markLoading(&db, candidate.sha256);
    var fourth: Daemon = .{ .io = io, .gpa = a, .db_path = db_path, .traits_allocator = a, .app = .{ .store = &store, .port = api.default_port, .clock = clock.nowMs } };
    try startProvider(&fourth);
    try std.testing.expectEqual(.unavailable, fourth.app.provider_status.state);
    try std.testing.expect(fourth.app.provider_status.candidate != null);
    try std.testing.expectEqual(std.http.Status.ok, providerCommand(&fourth, a, approval).?.status);
    try std.testing.expectEqual(.loaded, fourth.app.provider_status.state);
    for ([_]*Daemon{ &first, &second, &fourth }) |d| {
        if (d.provider_table) |table| {
            table.deinit(table.context);
            std.heap.page_allocator.destroy(table);
        }
        if (d.provider_file) |file| provider_loader.close(file);
    }
}

fn heartbeatLoop(d: *Daemon) Io.Cancelable!void {
    while (true) {
        try d.io.sleep(.fromMilliseconds(heartbeat_ms), .awake);
        try d.mutex.lock(d.io);
        defer d.mutex.unlock(d.io);
        if (shouldHeartbeat(&d.app)) {
            d.app.store.onHeartbeat(clock.nowMs()) catch |err| log("heartbeat failed: {s}", .{@errorName(err)});
            if (d.tour) |t| t.store.onHeartbeat(clock.nowMs()) catch {};
        }
    }
}

fn shouldHeartbeat(app: *const api.App) bool { return app.trial_nonce == null; }

test "trial suppresses heartbeat until commit" {
    var app: api.App = .{ .store = undefined, .port = 0, .clock = clock.nowMs, .trial_nonce = "0123456789abcdef0123456789abcdef" };
    try std.testing.expect(!shouldHeartbeat(&app));
    app.trial_nonce = null;
    try std.testing.expect(shouldHeartbeat(&app));
}

/// POST /api/tour/start {"lang":".."} opens a fresh sandbox (replacing any
/// running one); POST /api/tour/finish discards it. Called with the lock held.
fn tourCommand(d: *Daemon, a: std.mem.Allocator, request: api.Request) ?api.Response {
    const path = if (std.mem.indexOfScalar(u8, request.target, '?')) |at| request.target[0..at] else request.target;
    const start = std.mem.eql(u8, path, "/api/tour/start");
    if (!start and !std.mem.eql(u8, path, "/api/tour/finish")) return null;
    if (api.refused(d.app.port, a, request)) |r| return r;
    if (request.method != .POST) return api.answer(a, .method_not_allowed, .{ .@"error" = "method" });
    if (d.tour) |t| {
        t.destroy(d.io);
        d.tour = null;
    }
    if (!start) return api.answer(a, .ok, .{ .ok = true });

    const Body = struct { lang: []const u8 = "en" };
    const body = std.json.parseFromSliceLeaky(Body, a, if (request.body.len > 0) request.body else "{}", .{ .ignore_unknown_fields = true }) catch
        return api.answer(a, .bad_request, .{ .@"error" = "body" });
    const lang = demo.langOf(body.lang) orelse return api.answer(a, .bad_request, .{ .@"error" = "lang" });
    d.tour = tour_mod.Tour.create(d.gpa, d.io, d.tour_path, lang, d.app.store, d.app.port, clock.nowMs) catch |err| {
        log("tour failed to start: {s}", .{@errorName(err)});
        return api.answer(a, .internal_server_error, .{ .@"error" = "tour", .message = @errorName(err) });
    };
    log("tour started ({s})", .{@tagName(lang)});
    return api.answer(a, .ok, .{ .ok = true });
}

/// Approval is handled by the daemon because it owns the DLL and the trust row.
/// Called with the database lock held.
fn providerCommand(d: *Daemon, a: std.mem.Allocator, request: api.Request) ?api.Response {
    const path = if (std.mem.indexOfScalar(u8, request.target, '?')) |at| request.target[0..at] else request.target;
    if (!std.mem.eql(u8, path, "/api/provider/approve")) return null;
    if (api.refused(d.app.port, a, request)) |r| return r;
    if (request.method != .POST) return api.answer(a, .method_not_allowed, .{ .@"error" = "method" });
    const Body = struct { sha256: []const u8, how: []const u8 };
    const body = std.json.parseFromSliceLeaky(Body, a, request.body, .{ .ignore_unknown_fields = true }) catch
        return api.answer(a, .bad_request, .{ .@"error" = "body" });
    if (!provider_loader.validHash(body.sha256) or
        !(std.mem.eql(u8, body.how, "compared") or std.mem.eql(u8, body.how, "accepted")))
        return api.answer(a, .bad_request, .{ .@"error" = "body" });
    const previous = d.app.provider_status.candidate orelse
        return api.answer(a, .conflict, .{ .@"error" = "candidate_changed" });
    if (!std.mem.eql(u8, body.sha256, previous.sha256))
        return api.answer(a, .conflict, .{ .@"error" = "candidate_changed" });
    const scanned = provider_loader.scan(d.io, a, d.db_path) catch
        return api.answer(a, .internal_server_error, .{ .@"error" = "provider_scan" });
    const current = switch (scanned) {
        .candidate => |candidate| candidate,
        else => return api.answer(a, .conflict, .{ .@"error" = "candidate_changed" }),
    };
    if (!std.mem.eql(u8, body.sha256, current.sha256))
        return api.answer(a, .conflict, .{ .@"error" = "candidate_changed" });
    const checked = provider_loader.verified(a, d.db_path, current.sha256) catch
        return api.answer(a, .conflict, .{ .@"error" = "candidate_changed" });
    provider_loader.close(checked);
    approveTrust(d.app.store.db, body.sha256, body.how) catch
        return api.answer(a, .internal_server_error, .{ .@"error" = "provider_trust" });
    const restart = d.app.provider != null;
    if (restart) {
        d.app.provider_status.candidate = null;
    } else {
        startProvider(d) catch
            return api.answer(a, .internal_server_error, .{ .@"error" = "provider_load" });
    }
    return api.answer(a, .ok, .{ .restart = restart, .status = d.app.provider_status });
}

/// Start a successor that waits for this process to release the DLL and mutex.
/// Called with the database lock held; stopping still happens after the reply.
fn restartCommand(d: *Daemon, a: std.mem.Allocator, request: api.Request) ?api.Response {
    const path = if (std.mem.indexOfScalar(u8, request.target, '?')) |at| request.target[0..at] else request.target;
    if (!std.mem.eql(u8, path, "/api/restart")) return null;
    if (api.refused(d.app.port, a, request)) |r| return r;
    if (request.method != .POST) return api.answer(a, .method_not_allowed, .{ .@"error" = "method" });
    const command = launch.backgroundCommand(a, d.db_path, GetCurrentProcessId()) catch |err| {
        log("restart command failed: {s}", .{@errorName(err)});
        return api.answer(a, .internal_server_error, .{ .@"error" = "restart_spawn" });
    };
    launch.spawn(a, command) catch |err| {
        log("restart spawn failed: {s}", .{@errorName(err)});
        return api.answer(a, .internal_server_error, .{ .@"error" = "restart_spawn" });
    };
    d.app.stop_requested = true;
    return api.answer(a, .ok, .{ .restarting = true });
}

fn disabledUpdateResponse(a: std.mem.Allocator, repo: []const u8, method: std.http.Method) ?api.Response {
    if (repo.len != 0) return null;
    return if (method == .GET)
        api.answer(a, .ok, .{ .state = "disabled" })
    else
        api.answer(a, .bad_request, .{ .@"error" = "update_disabled", .message = "updates are turned off in this build" });
}

fn removeUpdateJournal(a: std.mem.Allocator, io: Io, db_path: []const u8) void {
    const path = std.fs.path.join(a, &.{ std.fs.path.dirname(db_path) orelse ".", "update.json" }) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "empty update repo gives a disabled API answer" {
    const a = std.testing.allocator;
    try std.testing.expect(disabledUpdateResponse(a, "someone/fork", .GET) == null);
    const response = disabledUpdateResponse(a, "", .GET).?;
    defer a.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("{\"state\":\"disabled\"}", response.body);
}

fn updateCommand(d: *Daemon, a: std.mem.Allocator, request: api.Request) ?api.Response {
    const path = if (std.mem.indexOfScalar(u8, request.target, '?')) |at| request.target[0..at] else request.target;
    const is_update = std.mem.eql(u8, path, "/api/update");
    const is_ack = std.mem.eql(u8, path, "/api/update/ack");
    if (!is_update and !is_ack) return null;
    if (api.updateRefused(d.app.port, a, request)) |r| return r;
    if (is_ack) {
        if (request.method != .POST) return api.answer(a, .method_not_allowed, .{ .@"error" = "method" });
        const Ack = struct { id: []const u8 };
        const body = std.json.parseFromSliceLeaky(Ack, a, request.body, .{ .ignore_unknown_fields = true }) catch return api.answer(a, .bad_request, .{ .@"error" = "body" });
        var last = (@import("update_journal.zig").read(a, d.io, d.db_path) catch return api.answer(a, .internal_server_error, .{ .@"error" = "journal" })) orelse return api.answer(a, .not_found, .{ .@"error" = "not_found" });
        if (!std.mem.eql(u8, last.id, body.id) or (last.phase != .committed and last.phase != .rolled_back)) return api.answer(a, .conflict, .{ .@"error" = "id" });
        last.ack = true;
        @import("update_journal.zig").write(a, d.io, d.db_path, last) catch return api.answer(a, .internal_server_error, .{ .@"error" = "journal" });
        return api.answer(a, .ok, .{ .ack = true });
    }
    const fetcher: update.Fetcher = .{ .context = @ptrCast(d), .get = update.httpGet };
    if (request.method == .GET) {
        const saved = @import("update_journal.zig").read(a, d.io, d.db_path) catch return api.answer(a, .internal_server_error, .{ .@"error" = "journal" });
        const last = update.outcome(saved);
        if (std.mem.eql(u8, request.target, "/api/update?outcome=1")) return api.answer(a, .ok, .{ .last = last });
        if (disabledUpdateResponse(a, update.release_repo, request.method) != null) return api.answer(a, .ok, .{ .state = "disabled", .last = last });
        const result = update.check(a, d.io, fetcher) catch |err| {
            log("update check failed: {s}", .{@errorName(err)});
            return api.answer(a, .bad_gateway, .{ .@"error" = "update_check", .message = @errorName(err) });
        };
        return switch (result) {
            .up_to_date => api.answer(a, .ok, .{ .state = "up_to_date", .version = update.current_version, .repo = update.release_repo, .last = last }),
            .available => |release| api.answer(a, .ok, .{ .state = "available", .current = update.current_version, .version = release.version, .notes_url = release.notes_url, .size = release.size, .digest = release.digest, .signed = release.signed, .repo = update.release_repo, .last = last }),
        };
    }
    if (request.method != .POST) return api.answer(a, .method_not_allowed, .{ .@"error" = "method" });
    const Body = struct { version: ?[]const u8 = null, file: ?[]const u8 = null };
    const body = std.json.parseFromSliceLeaky(Body, a, request.body, .{ .ignore_unknown_fields = true }) catch
        return api.answer(a, .bad_request, .{ .@"error" = "body" });
    const version = if (body.file) |file| update.versionFromFile(file) orelse return api.answer(a, .bad_request, .{ .@"error" = "file" }) else body.version orelse return api.answer(a, .bad_request, .{ .@"error" = "version" });
    if (body.file != null and !request.local_file) return api.answer(a, .forbidden, .{ .@"error" = "file_cli_only" });
    if (update.parseVersion(version) == null) return api.answer(a, .bad_request, .{ .@"error" = "version" });
    var installed = update.install(a, d.io, fetcher, d.db_path, version, body.file) catch |err| {
        log("update install failed: {s}", .{@errorName(err)});
        const message: []const u8 = switch (err) {
            error.UnsignedRelease => "this release is not signed; kowalski will not install it",
            error.BadSignature => "The release signature does not match; kowalski did not install it.",
            else => @errorName(err),
        };
        const code: []const u8 = switch (err) {
            error.UnsignedRelease => "update_unsigned",
            error.BadSignature => "update_bad_signature",
            else => "update_install",
        };
        return api.answer(a, .internal_server_error, .{ .@"error" = code, .message = message });
    };
    const new_journal = update.newJournal(a, version) catch |err| {
        installed.swap.rollback(a, d.io);
        installed.lock.release();
        return api.answer(a, .internal_server_error, .{ .@"error" = "journal", .message = @errorName(err) });
    };
    @import("update_journal.zig").write(a, d.io, d.db_path, new_journal) catch |err| {
        installed.swap.rollback(a, d.io);
        installed.lock.release();
        return api.answer(a, .internal_server_error, .{ .@"error" = "journal", .message = @errorName(err) });
    };
    const command = std.fmt.allocPrint(a, "\"{s}\\kowalskiw.exe.old\" --update-guard --db \"{s}\" --after {d}", .{ installed.swap.exe_dir, d.db_path, GetCurrentProcessId() }) catch |err| {
        installed.swap.rollback(a, d.io);
        installed.lock.release();
        removeUpdateJournal(a, d.io, d.db_path);
        return api.answer(a, .internal_server_error, .{ .@"error" = "restart_spawn", .message = @errorName(err) });
    };
    launch.spawn(a, command) catch |err| {
        installed.swap.rollback(a, d.io);
        installed.lock.release();
        removeUpdateJournal(a, d.io, d.db_path);
        return api.answer(a, .internal_server_error, .{ .@"error" = "restart_spawn", .message = @errorName(err) });
    };
    installed.lock.release();
    d.app.stop_requested = true;
    return api.answer(a, .ok, .{ .restarting = true });
}

test "update outcome API reports once and acknowledges matching id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
    const value: @import("update_journal.zig").Journal = .{
        .id = "0123456789abcdef0123456789abcdef", .from = "1.0.0", .to = "1.1.0", .phase = .rolled_back,
        .nonce = "abcdef0123456789abcdef0123456789", .snapshot = "snapshot.db", .exe_dir = ".",
        .reason = "readiness timeout", .started_ms = 1,
    };
    try @import("update_journal.zig").write(a, io, db_path, value);
    var d: Daemon = .{ .io = io, .gpa = a, .app = .{ .store = undefined, .port = api.default_port, .clock = clock.nowMs }, .db_path = db_path, .traits_allocator = a };
    const get: api.Request = .{ .method = .GET, .target = "/api/update?outcome=1", .host = "127.0.0.1:47100", .marker = true };
    const before = updateCommand(&d, a, get).?;
    try std.testing.expectEqual(std.http.Status.ok, before.status);
    try std.testing.expect(std.mem.indexOf(u8, before.body, "readiness timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, before.body, "\"nonce\"") == null);
    const wrong = updateCommand(&d, a, .{ .method = .POST, .target = "/api/update/ack", .host = get.host, .marker = true, .body = "{\"id\":\"bad\"}" }).?;
    try std.testing.expectEqual(std.http.Status.conflict, wrong.status);
    const ack = updateCommand(&d, a, .{ .method = .POST, .target = "/api/update/ack", .host = get.host, .marker = true, .body = "{\"id\":\"0123456789abcdef0123456789abcdef\"}" }).?;
    try std.testing.expectEqual(std.http.Status.ok, ack.status);
    const after = updateCommand(&d, a, get).?;
    try std.testing.expectEqualStrings("{\"last\":null}", after.body);
}

fn acceptLoop(d: *Daemon, listener: *Io.net.Server, connections: *Io.Group) Io.Cancelable!void {
    while (true) {
        const stream = listener.accept(d.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log("accept failed: {s}", .{@errorName(err)});
                try d.io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
        };
        connections.concurrent(d.io, serveConnection, .{ d, stream }) catch {
            stream.close(d.io);
        };
    }
}

fn respond(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) void {
    req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    }) catch {};
}

const UiFile = struct { path: []const u8, body: []const u8, kind: []const u8 };

const html = "text/html; charset=utf-8";
const js = "text/javascript; charset=utf-8";
const css = "text/css; charset=utf-8";

/// The dashboard, compiled in. A file the page references must be listed
/// here (a test checks it).
const ui_files = [_]UiFile{
    .{ .path = "/", .body = @embedFile("ui/index.html"), .kind = html },
    .{ .path = "/index.html", .body = @embedFile("ui/index.html"), .kind = html },
    .{ .path = "/favicon.svg", .body = @embedFile("ui/favicon.svg"), .kind = "image/svg+xml" },
    // Installed-app pieces; the service worker sits at the root for its scope.
    .{ .path = "/manifest.webmanifest", .body = @embedFile("ui/manifest.webmanifest"), .kind = "application/manifest+json" },
    .{ .path = "/sw.js", .body = @embedFile("ui/sw.js"), .kind = js },
    .{ .path = "/icon-192.png", .body = @embedFile("ui/icon-192.png"), .kind = "image/png" },
    .{ .path = "/icon-512.png", .body = @embedFile("ui/icon-512.png"), .kind = "image/png" },
    .{ .path = "/vendor/chart-4.4.0.min.js", .body = @embedFile("ui/vendor/chart-4.4.0.min.js"), .kind = js },
    .{ .path = "/ui/app.css", .body = @embedFile("ui/app.css"), .kind = css },
    .{ .path = "/ui/util.js", .body = @embedFile("ui/util.js"), .kind = js },
    .{ .path = "/ui/i18n.js", .body = @embedFile("ui/i18n.js"), .kind = js },
    .{ .path = "/ui/state.js", .body = @embedFile("ui/state.js"), .kind = js },
    .{ .path = "/ui/layout.js", .body = @embedFile("ui/layout.js"), .kind = js },
    .{ .path = "/ui/header.js", .body = @embedFile("ui/header.js"), .kind = js },
    .{ .path = "/ui/cards.js", .body = @embedFile("ui/cards.js"), .kind = js },
    .{ .path = "/ui/settings.js", .body = @embedFile("ui/settings.js"), .kind = js },
    .{ .path = "/ui/post.js", .body = @embedFile("ui/post.js"), .kind = js },
    .{ .path = "/ui/switch.js", .body = @embedFile("ui/switch.js"), .kind = js },
    .{ .path = "/ui/search.js", .body = @embedFile("ui/search.js"), .kind = js },
    .{ .path = "/ui/newtask.js", .body = @embedFile("ui/newtask.js"), .kind = js },
    .{ .path = "/ui/keys.js", .body = @embedFile("ui/keys.js"), .kind = js },
    .{ .path = "/ui/day.js", .body = @embedFile("ui/day.js"), .kind = js },
    .{ .path = "/ui/summary.js", .body = @embedFile("ui/summary.js"), .kind = js },
    .{ .path = "/ui/history.js", .body = @embedFile("ui/history.js"), .kind = js },
    .{ .path = "/ui/sidebar.js", .body = @embedFile("ui/sidebar.js"), .kind = js },
    .{ .path = "/ui/report.js", .body = @embedFile("ui/report.js"), .kind = js },
    .{ .path = "/ui/charts.js", .body = @embedFile("ui/charts.js"), .kind = js },
    .{ .path = "/ui/tour.js", .body = @embedFile("ui/tour.js"), .kind = js },
    .{ .path = "/ui/boot.js", .body = @embedFile("ui/boot.js"), .kind = js },
};

fn uiFile(path: []const u8) ?UiFile {
    for (ui_files) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

/// The dashboard: same loopback Host rule as the API, GET only.
fn serveUi(req: *std.http.Server.Request, request: api.Request, port: u16) void {
    const host = request.host orelse return respond(req, .forbidden, "{\"error\":\"host\"}");
    if (!api.hostAllowed(port, host)) return respond(req, .forbidden, "{\"error\":\"host\"}");
    if (request.method != .GET) return respond(req, .method_not_allowed, "{\"error\":\"method\"}");
    const path = if (std.mem.indexOfScalar(u8, request.target, '?')) |at| request.target[0..at] else request.target;
    const file = uiFile(path) orelse return respond(req, .not_found, "{\"error\":\"not_found\"}");
    req.respond(file.body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = file.kind },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-frame-options", .value = "DENY" },
            .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'" },
        },
    }) catch {};
}

fn serveConnection(d: *Daemon, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(d.io);
    var arena_state = std.heap.ArenaAllocator.init(d.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(d.io, &read_buffer);
    var writer = stream.writer(d.io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = server.receiveHead() catch return;

    // Header slices die once the body is read, so copy what the API needs.
    var request: api.Request = .{
        .method = req.head.method,
        .target = a.dupe(u8, req.head.target) catch return,
        .host = null,
    };
    var hosts: usize = 0;
    var headers = req.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            hosts += 1;
            request.host = a.dupe(u8, header.value) catch return;
        } else if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            request.origin = a.dupe(u8, header.value) catch return;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-kowalski")) {
            request.marker = std.mem.eql(u8, header.value, "1");
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-kowalski-local-file")) {
            request.local_file = std.mem.eql(u8, header.value, "1");
        }
    }
    if (hosts != 1) request.host = null;

    // The tour's API is the same API on its sandbox.
    const in_tour = std.mem.startsWith(u8, request.target, "/tour/api/");
    if (in_tour) request.target = request.target["/tour".len..];

    // Everything outside /api/ is the dashboard, compiled into the binary.
    if (!std.mem.startsWith(u8, request.target, "/api/")) {
        serveUi(&req, request, d.app.port);
        return;
    }

    // Without Content-Length or chunked encoding a request has no body (RFC 9112 6.3).
    const has_body = req.head.content_length != null or req.head.transfer_encoding == .chunked;
    if (req.head.method.requestHasBody() and has_body) {
        if (req.head.content_length) |len| if (len > max_body) {
            respond(&req, .payload_too_large, "{\"error\":\"too_large\"}");
            return;
        };
        var body_buffer: [4096]u8 = undefined;
        // A body can carry login answers: leave no copy behind.
        defer @memset(&body_buffer, 0);
        const body_reader = req.readerExpectContinue(&body_buffer) catch return;
        request.body = body_reader.allocRemaining(a, .limited(max_body)) catch {
            respond(&req, .bad_request, "{\"error\":\"body\"}");
            return;
        };
    }

    defer @memset(@constCast(request.body), 0);
    if (d.app.trial_nonce != null and request.method != .GET and !std.mem.eql(u8, request.target, "/api/update/commit")) {
        if (api.refused(d.app.port, a, request)) |r| return respond(&req, r.status, r.body);
        return respond(&req, .service_unavailable, "{\"error\":\"updating\"}");
    }
    if (in_tour) {
        // The tour's provider answers at once, so it runs under the lock:
        // a finish cannot pull the sandbox out from under it.
        try d.mutex.lock(d.io);
        defer d.mutex.unlock(d.io);
        const t = d.tour orelse return respond(&req, .conflict, "{\"error\":\"no_tour\",\"message\":\"no tour is running\"}");
        var response = api.handle(&t.app, a, request);
        while (response.followup) |next| {
            const outcome = worker.runInline(&t.table, a, next.call()) catch worker.Outcome.busy;
            response = api.proceed(&t.app, a, next, outcome);
        }
        return respond(&req, response.status, response.body);
    }

    var response = blk: {
        try d.mutex.lock(d.io);
        defer d.mutex.unlock(d.io);
        if (tourCommand(d, a, request)) |r| break :blk r;
        if (restartCommand(d, a, request)) |r| break :blk r;
        if (updateCommand(d, a, request)) |r| break :blk r;
        if (providerCommand(d, a, request)) |r| break :blk r;
        break :blk api.handle(&d.app, a, request);
    };
    // Provider calls run without the database lock.
    while (response.followup) |next| {
        // A call that could not be started was never made, like `busy`.
        const outcome = blk: {
            try d.provider_turn.lock(d.io);
            defer d.provider_turn.unlock(d.io);
            break :blk d.provider.?.run(a, next.call(), provider_deadline_ms) catch .busy;
        };
        try d.mutex.lock(d.io);
        defer d.mutex.unlock(d.io);
        response = api.proceed(&d.app, a, next, outcome);
    }
    respond(&req, response.status, response.body);
    if (d.app.stop_requested) d.stop.set(d.io);
}

test "every local file the dashboard references is served" {
    const page = uiFile("/").?.body;
    var count: usize = 0;
    var ui_count: usize = 0;
    for ([_][]const u8{ "src=\"/", "href=\"/" }) |attr| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, page, at, attr)) |found| {
            const start = found + attr.len - 1;
            const end = std.mem.indexOfScalarPos(u8, page, start, '"') orelse return error.Unterminated;
            const path = page[start..end];
            if (uiFile(path) == null) {
                std.debug.print("not served: {s}\n", .{path});
                return error.NotServed;
            }
            count += 1;
            if (std.mem.startsWith(u8, path, "/ui/")) ui_count += 1;
            at = end;
        }
    }
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(usize, 21), ui_count); // stylesheet and 20 scripts
}
