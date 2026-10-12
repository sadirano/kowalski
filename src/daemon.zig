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
const provider_impl = @import("provider_impl");
const tour_mod = @import("tour.zig");
const demo = @import("demo.zig");

extern "kernel32" fn CreateMutexW(attributes: ?*anyopaque, initial_owner: i32, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
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
    var d: Daemon = .{ .io = io, .gpa = gpa, .app = .{ .store = &store, .port = port, .clock = clock.nowMs, .running_post = worker.runningPost } };
    // The tour's sandbox sits next to the database and never outlives a run.
    const tour_path = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(options.db_path) orelse ".", tour_mod.file_name });
    defer gpa.free(tour_path);
    tour_mod.removeFiles(io, tour_path);
    d.tour_path = tour_path;
    defer if (d.tour) |t| t.destroy(io);
    defer if (d.provider_table) |table| {
        if (worker.idle()) {
            table.deinit(table.context);
            std.heap.page_allocator.destroy(table);
        }
    };
    if (provider_impl.kowalskiProvider(contract.version)) |table| {
        if (table.version != contract.version) {
            d.app.provider_status = .{ .state = .unavailable, .reason = "provider speaks a different contract version" };
            log("provider answered version {d}, need {d}; running without it", .{ table.version, contract.version });
        } else {
            const InfoShape = struct { contracts: []const u32, name: []const u8, build: []const u8 };
            const info = std.json.parseFromSliceLeaky(InfoShape, traits_arena.allocator(), provider_impl.kowalskiProviderInfo().slice(), .{ .ignore_unknown_fields = true }) catch null;
            if (info) |metadata| {
                d.app.provider_status.name = try printableAscii(traits_arena.allocator(), metadata.name, 128);
                d.app.provider_status.build = try printableAscii(traits_arena.allocator(), metadata.build, 128);
                log("provider info: {s} ({s})", .{ d.app.provider_status.name, d.app.provider_status.build });
            } else log("provider info: invalid JSON", .{});
            const data_dir = try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(options.db_path) orelse ".", "providers", table.instance.slice() });
            defer gpa.free(data_dir);
            try std.Io.Dir.cwd().createDirPath(io, data_dir);
            const config = try std.json.Stringify.valueAlloc(gpa, .{ .contract = contract.version, .data_dir = data_dir }, .{});
            defer gpa.free(config);
            var context: ?*anyopaque = null;
            const status = table.init(table.context, .of(config), &context);
            defer if (status.message.ptr != null) table.free(context, status.message);
            if (status.code != 0) {
                const message = try printableAscii(traits_arena.allocator(), status.message.slice(), 200);
                d.app.provider_status.state = .unavailable;
                d.app.provider_status.reason = try std.fmt.allocPrint(traits_arena.allocator(), "init failed: {s}", .{message});
                log("provider init failed ({d}): {s}; running without it", .{ status.code, message });
            } else {
                const copy = try std.heap.page_allocator.create(contract.Table);
                copy.* = table.*;
                copy.context = context;
                d.provider_table = copy;
                d.provider = .{ .table = copy, .io = io, .late = onLate, .late_context = &d };
                d.app.provider = copy.instance.slice();
                d.app.provider_status.state = .loaded;
                try store.setSetting("provider_instance", copy.instance.slice(), clock.nowMs());
                d.app.traits = api.parseTraits(traits_arena.allocator(), copy.traits.slice());
                log("provider: {s}", .{copy.instance.slice()});
            }
        }
    }
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
    var accept_future = try io.concurrent(acceptLoop, .{ &d, &listener, &connections });
    var heartbeat_future = try io.concurrent(heartbeatLoop, .{&d});
    log("listening on http://127.0.0.1:{d} (database {s})", .{ port, options.db_path });

    d.stop.waitUncancelable(io);

    accept_future.cancel(io) catch {};
    connections.cancel(io);
    heartbeat_future.cancel(io) catch {};
    {
        d.mutex.lockUncancelable(io);
        defer d.mutex.unlock(io);
        store.onHeartbeat(clock.nowMs()) catch |err| log("final heartbeat failed: {s}", .{@errorName(err)});
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

test "provider status text is printable and capped" {
    const value = try printableAscii(std.testing.allocator, "a\x00\n\xffb", 4);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("a???", value);
}

fn heartbeatLoop(d: *Daemon) Io.Cancelable!void {
    while (true) {
        try d.io.sleep(.fromMilliseconds(heartbeat_ms), .awake);
        try d.mutex.lock(d.io);
        defer d.mutex.unlock(d.io);
        d.app.store.onHeartbeat(clock.nowMs()) catch |err| log("heartbeat failed: {s}", .{@errorName(err)});
        if (d.tour) |t| t.store.onHeartbeat(clock.nowMs()) catch {};
    }
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
