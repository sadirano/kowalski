//! HTTP API as a pure function: request in, response out. The daemon owns the
//! sockets and serializes calls; tests drive `handle` directly.
//!
//! A request that needs the provider answers with a `followup` instead: the
//! caller runs that provider call without the database lock, then passes the
//! outcome to `proceed`, which may ask for another call.
const std = @import("std");
const store_mod = @import("store.zig");
const days = @import("days.zig");
const zone = @import("zone.zig");
const query = @import("query.zig");
const worker = @import("worker.zig");
const sessions = @import("sessions.zig");
const Store = store_mod.Store;

pub const default_port: u16 = 47100;

/// Settings the API may change; anything else is refused.
pub const setting_keys = [_][]const u8{
    "reporting_zone",  "daily_work_minutes", "lunch_minutes",     "http_port",
    "post_sessions",
    // Dashboard preferences.
    "ui_day_order",    "ui_sidebar_days",    "ui_hide_weekends",  "ui_show_keys",      "ui_show_add_entry", "ui_chart_visible", "ui_tour_offered", "ui_single_keys", "ui_open_on_launch",
    "ui_chart_days",   "ui_left_collapsed",  "ui_lang",           "ui_summary_format", "ui_autofill_obs",   "ui_links",
    "ui_time_format",  "ui_chart_view",      "ui_chart_hidden",
    // Paid break windows, overriding the provider's: "08:00-12:00=15,13:00-18:00=15"; empty is none.
    "paid_breaks",
    // Windows where a screen lock pauses: "17:00-23:59"; empty is none.
    "lock_pause",
};

pub const App = struct {
    store: *Store,
    port: u16,
    clock: *const fn () i64,
    /// Set by POST /api/shutdown; the daemon stops after answering.
    stop_requested: bool = false,
    /// Binding instance of the compiled-in provider; null without one.
    provider: ?[]const u8 = null,
    provider_status: ProviderStatus = .{},
    /// The provider's static traits; empty without one.
    traits: Traits = .{},
    running_post: ?*const fn () ?i64 = null,
};

pub const ProviderStatus = struct {
    state: enum { none, loaded, unavailable } = .none,
    name: []const u8 = "",
    build: []const u8 = "",
    reason: []const u8 = "",
};

const SessionRecord = struct { id: i64, session: sessions.Session };
const SessionChain = struct {
    day: []const u8,
    task: i64,
    ref: []const u8,
    text: ?[]const u8,
    title: []const u8,
    day_over: bool,
    task_open: bool,
    settings: std.json.ArrayHashMap([]const u8),
    options: std.json.ArrayHashMap(bool),
    limit: usize,
    confirmed: std.ArrayList(SessionRecord) = .empty,
};

pub const Followup = union(enum) {
    fields,
    /// Without a task, only looks the ref up.
    lookup: struct { task: ?i64, ref: []const u8 },
    quote: struct {
        day: []const u8,
        task: i64,
        ref: []const u8,
        request: []const u8,
        fingerprint: []const u8,
        text: ?[]const u8,
        day_over: bool,
        task_open: bool,
        total_focus_ms: i64,
        dry_run: bool = false,
        title: []const u8 = "",
        settings: std.json.ArrayHashMap([]const u8) = .{},
        options: std.json.ArrayHashMap(bool) = .{},
        session: ?sessions.Session = null,
        all_sessions: ?[]sessions.Session = null,
        chain: ?*SessionChain = null,
    },
    post: struct { posting: i64, request: []const u8, session: ?sessions.Session = null, chain: ?*SessionChain = null },
    /// Day statuses: quotes `items[next]`, then the next one.
    status: *StatusJob,
    login_prompts,
    /// JSON answers; wiped once the call returns.
    login: []u8,

    pub fn call(f: Followup) worker.Call {
        return switch (f) {
            .fields => .fields,
            .lookup => |l| .{ .lookup = l.ref },
            .quote => |q| .{ .quote = q.request },
            .post => |p| .{ .post = .{ .posting = p.posting, .request = p.request } },
            .status => |j| .{ .quote = j.items[j.next].request },
            .login_prompts => .login_prompts,
            .login => |answers| .{ .login = answers },
        };
    }
};

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    /// Null when absent or sent more than once.
    host: ?[]const u8,
    origin: ?[]const u8 = null,
    marker: bool = false,
    body: []const u8 = "",
};

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
    /// When set, `body` is not sent: run this provider call, then `proceed`.
    followup: ?Followup = null,
};

const Fail = struct {
    status: std.http.Status,
    code: []const u8,
    message: []const u8 = "",
    candidates: ?[]const query.Task = null,
};

fn send(a: std.mem.Allocator, status: std.http.Status, value: anytype) Response {
    const body = std.json.Stringify.valueAlloc(a, value, .{}) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"OutOfMemory\"}" };
    return .{ .status = status, .body = body };
}

fn fail(a: std.mem.Allocator, f: Fail) Response {
    return send(a, f.status, .{ .@"error" = f.code, .message = f.message, .candidates = f.candidates });
}

fn errorResponse(a: std.mem.Allocator, err: anyerror) Response {
    const status: std.http.Status = switch (err) {
        error.UnknownTask, error.UnknownInterval, error.UnknownNote => .not_found,
        error.Stale, error.Overlap, error.NoteOutside, error.OpenEnd, error.NotMergeable, error.TaskHasPostings, error.TaskOpen => .conflict,
        error.InvalidRange => .bad_request,
        error.NoFocus, error.NoOpenInterval, error.AlreadyOpen, error.SomethingOpen, error.BindingConflict, error.PostingBlocked, error.PostingInFlight, error.InvalidState, error.NoProvider, error.NotBound, error.NothingToPost, error.SessionOpen => .conflict,
        error.UnknownPosting => .not_found,
        error.ProviderOutput => .bad_gateway,
        error.EmptyText, error.InvalidSetting, error.UnknownZone, error.InvalidTime, error.InvalidDate, error.InvalidSchedule => .bad_request,
        else => .internal_server_error,
    };
    return fail(a, .{ .status = status, .code = @errorName(err) });
}

pub fn hostAllowed(port: u16, host: []const u8) bool {
    var buf: [32]u8 = undefined;
    const ip = std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port}) catch return false;
    if (std.mem.eql(u8, host, ip)) return true;
    var buf2: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buf2, "localhost:{d}", .{port}) catch return false;
    return std.ascii.eqlIgnoreCase(host, name);
}

fn originAllowed(port: u16, origin: []const u8) bool {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, origin, prefix)) return false;
    return hostAllowed(port, origin[prefix.len..]);
}

/// The host, header and origin rules every API request passes: the refusal,
/// or null when the request may go on.
pub fn refused(port: u16, a: std.mem.Allocator, req: Request) ?Response {
    const host = req.host orelse return fail(a, .{ .status = .forbidden, .code = "host" });
    if (!hostAllowed(port, host)) return fail(a, .{ .status = .forbidden, .code = "host" });
    switch (req.method) {
        .GET => {},
        .POST, .PATCH, .DELETE => {
            if (!req.marker) return fail(a, .{ .status = .forbidden, .code = "header", .message = "changes need X-Kowalski: 1" });
            if (req.origin) |origin| if (!originAllowed(port, origin)) return fail(a, .{ .status = .forbidden, .code = "origin" });
        },
        else => return fail(a, .{ .status = .method_not_allowed, .code = "method" }),
    }
    return null;
}

/// A JSON answer, for the routes the daemon itself serves.
pub fn answer(a: std.mem.Allocator, status: std.http.Status, value: anytype) Response {
    return send(a, status, value);
}

pub fn handle(app: *App, a: std.mem.Allocator, req: Request) Response {
    if (refused(app.port, a, req)) |r| return r;
    const question = std.mem.indexOfScalar(u8, req.target, '?');
    const path = if (question) |at| req.target[0..at] else req.target;
    const params = if (question) |at| req.target[at + 1 ..] else "";
    return route(app, a, req, path, params) catch |err| errorResponse(a, err);
}

fn is(req: Request, method: std.http.Method, path: []const u8, want: []const u8) bool {
    return req.method == method and std.mem.eql(u8, path, want);
}

fn route(app: *App, a: std.mem.Allocator, req: Request, path: []const u8, params: []const u8) !Response {
    if (is(req, .GET, path, "/api/health")) return send(a, .ok, .{ .ok = true });
    if (try history(app, a, req, path)) |r| return r;
    if (is(req, .GET, path, "/api/search")) return search(app, a, params);
    if (is(req, .GET, path, "/api/daytotals")) return dayTotals(app, a, params);
    if (is(req, .GET, path, "/api/frequent")) return frequentTasks(app, a, params);
    if (is(req, .GET, path, "/api/chart")) return chart(app, a, params);
    if (is(req, .GET, path, "/api/days")) return dayList(app, a, params);
    if (is(req, .GET, path, "/api/provider/login")) {
        if (app.provider == null) return error.NoProvider;
        return .{ .status = .ok, .body = "", .followup = .login_prompts };
    }
    if (is(req, .POST, path, "/api/provider/login")) {
        if (app.provider == null) return error.NoProvider;
        // The answers go to the provider as sent, unparsed here so no copy of
        // a secret is left behind; the provider checks them.
        const body = std.mem.trim(u8, req.body, " \t\r\n");
        if (body.len <= 2 or body[0] != '{' or body[body.len - 1] != '}') return badRequest(a, "body");
        return .{ .status = .ok, .body = "", .followup = .{ .login = try a.dupe(u8, req.body) } };
    }
    if (is(req, .GET, path, "/api/lookup")) {
        if (app.provider == null) return error.NoProvider;
        const ref = std.mem.trim(u8, try param(a, params, "ref") orelse "", " \t");
        if (ref.len == 0) return badRequest(a, "ref");
        return .{ .status = .ok, .body = "", .followup = .{ .lookup = .{ .task = null, .ref = ref } } };
    }
    if (is(req, .GET, path, "/api/state")) return state(app, a);
    if (is(req, .POST, path, "/api/shutdown")) {
        app.stop_requested = true;
        return send(a, .ok, .{ .ok = true });
    }
    if (is(req, .GET, path, "/api/tasks")) {
        const limit = if (try param(a, params, "limit")) |v| std.fmt.parseInt(u32, v, 10) catch return badRequest(a, "limit") else 50;
        return send(a, .ok, .{ .tasks = try query.listTasks(app.store, a, try param(a, params, "q"), @min(limit, 1000)) });
    }
    if (req.method == .POST and std.mem.startsWith(u8, path, "/api/tasks/") and std.mem.endsWith(u8, path, "/bind")) {
        const id = std.fmt.parseInt(i64, path["/api/tasks/".len .. path.len - "/bind".len], 10) catch return notFound(a);
        return bindTask(app, a, id, req.body);
    }
    if (is(req, .GET, path, "/api/provider")) {
        if (app.provider == null) return send(a, .ok, .{ .instance = null, .fields = [_]u8{}, .settings = [_]u8{}, .post_options = [_]u8{}, .sessions = false, .status = app.provider_status });
        return .{ .status = .ok, .body = "", .followup = .fields };
    }
    if (is(req, .GET, path, "/api/postings")) return offers(app, a, try param(a, params, "date"));
    if (is(req, .POST, path, "/api/postings")) return startPosting(app, a, req.body);
    if (req.method == .POST and std.mem.startsWith(u8, path, "/api/postings/") and std.mem.endsWith(u8, path, "/resolve")) {
        const id = std.fmt.parseInt(i64, path["/api/postings/".len .. path.len - "/resolve".len], 10) catch return notFound(a);
        const body = try parseBody(struct { posted: bool }, a, req.body) orelse return badRequest(a, "body");
        _ = try query.posting(app.store, a, id) orelse return error.UnknownPosting;
        if (app.running_post) |running_post| if (running_post() == id) return error.PostingInFlight;
        try app.store.resolveUnknown(id, body.posted, null, app.clock());
        return send(a, .ok, .{ .posting = (try query.posting(app.store, a, id)).? });
    }
    if (std.mem.startsWith(u8, path, "/api/tasks/")) {
        const id = std.fmt.parseInt(i64, path["/api/tasks/".len..], 10) catch return notFound(a);
        if (req.method == .GET) {
            const t = try query.task(app.store, a, id) orelse return error.UnknownTask;
            return send(a, .ok, .{ .task = t, .fields = try query.fields(app.store, a, id) });
        }
        if (req.method == .PATCH) {
            const body = try parseBody(struct { title: []const u8 }, a, req.body) orelse return badRequest(a, "body");
            try app.store.setTitle(id, std.mem.trim(u8, body.title, " \t"), app.clock());
            return send(a, .ok, .{ .task = (try query.task(app.store, a, id)).? });
        }
    }
    if (is(req, .POST, path, "/api/tasks")) {
        const body = try parseBody(struct { title: []const u8 }, a, req.body) orelse return badRequest(a, "body");
        const id = try app.store.createTask(std.mem.trim(u8, body.title, " \t"), app.clock());
        return send(a, .created, .{ .task = (try query.task(app.store, a, id)).? });
    }
    if (is(req, .POST, path, "/api/switch") or is(req, .POST, path, "/api/parallel")) {
        const body = try parseBody(struct { task: []const u8, text: ?[]const u8 = null }, a, req.body) orelse return badRequest(a, "body");
        var created = false;
        const id = switch (try query.resolve(app.store, a, body.task)) {
            .found => |id| id,
            .ambiguous => |list| return ambiguous(a, list),
            .none => blk: {
                const title = std.mem.trim(u8, body.task, " \t");
                if (title.len > 0 and title[0] == '#') return error.UnknownTask;
                created = true;
                break :blk try app.store.createTask(title, app.clock());
            },
        };
        const text = if (body.text) |t| if (std.mem.trim(u8, t, " \t").len == 0) null else t else null;
        const interval = if (std.mem.eql(u8, path, "/api/switch"))
            try app.store.switchTo(id, text, app.clock())
        else
            try app.store.openParallel(id, text, app.clock());
        return send(a, .ok, .{ .interval = interval, .task = (try query.task(app.store, a, id)).?, .created = created });
    }
    if (is(req, .POST, path, "/api/stop")) {
        const body = try parseBody(struct { task: []const u8 }, a, req.body) orelse return badRequest(a, "body");
        const id = switch (try resolveExisting(app, a, body.task)) {
            .id => |id| id,
            .response => |r| return r,
        };
        try app.store.stop(id, app.clock());
        return send(a, .ok, .{ .task = (try query.task(app.store, a, id)).? });
    }
    if (is(req, .POST, path, "/api/pause")) {
        try app.store.pause(app.clock());
        return state(app, a);
    }
    if (is(req, .POST, path, "/api/resume")) {
        try app.store.@"resume"(app.clock());
        return state(app, a);
    }
    if (is(req, .POST, path, "/api/notes")) {
        const body = try parseBody(struct { task: ?[]const u8 = null, text: []const u8, interval: ?i64 = null, at_ms: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        if (body.interval) |interval| {
            const at = body.at_ms orelse return badRequest(a, "at_ms");
            const note = try app.store.addNoteAt(interval, at, std.mem.trim(u8, body.text, " \t\r\n"), app.clock());
            return send(a, .created, .{ .note = note });
        }
        var target: ?i64 = null;
        if (body.task) |t| switch (try resolveExisting(app, a, t)) {
            .id => |id| target = id,
            .response => |r| return r,
        };
        const text = std.mem.trim(u8, body.text, " \t\r\n");
        const note = try app.store.addNote(target, text, app.clock());
        return send(a, .created, .{ .note = note });
    }
    if (is(req, .GET, path, "/api/day")) return day(app, a, try param(a, params, "date"));
    if (is(req, .GET, path, "/api/summary")) {
        const date = try dateParam(app, a, try param(a, params, "date"));
        return send(a, .ok, .{ .date = date.text, .text = try summaryOf(app, a, date.text) });
    }
    if (is(req, .POST, path, "/api/summary")) {
        const body = try parseBody(struct { date: []const u8, text: []const u8 }, a, req.body) orelse return badRequest(a, "body");
        const date = try dateParam(app, a, body.date);
        try app.store.setDaySummary(date.text, std.mem.trim(u8, body.text, " \t\r\n"), app.clock());
        return send(a, .ok, .{ .date = date.text, .text = try summaryOf(app, a, date.text) });
    }
    if (is(req, .GET, path, "/api/settings")) return send(a, .ok, .{ .settings = try query.settings(app.store, a) });
    if (is(req, .PATCH, path, "/api/settings")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, req.body, .{}) catch return badRequest(a, "body");
        if (parsed != .object) return badRequest(a, "body");
        var batch: std.ArrayList(Store.SettingChange) = .empty;
        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            if (!knownSetting(app, entry.key_ptr.*)) return fail(a, .{ .status = .bad_request, .code = "UnknownSetting", .message = entry.key_ptr.* });
            const value: ?[]const u8 = switch (entry.value_ptr.*) {
                .string => |v| v,
                .null => null,
                else => return fail(a, .{ .status = .bad_request, .code = "InvalidSetting", .message = entry.key_ptr.* }),
            };
            if (!validUi(app, entry.key_ptr.*, value)) return fail(a, .{ .status = .bad_request, .code = "InvalidSetting", .message = entry.key_ptr.* });
            try batch.append(a, .{ .key = entry.key_ptr.*, .value = value });
        }
        for (batch.items) |c| app.store.validateSetting(c.key, c.value) catch |err| {
            return fail(a, .{ .status = .bad_request, .code = @errorName(err), .message = c.key });
        };
        app.store.setSettings(batch.items, app.clock()) catch |err| {
            return fail(a, .{ .status = .bad_request, .code = @errorName(err), .message = "settings" });
        };
        return send(a, .ok, .{ .settings = try query.settings(app.store, a) });
    }
    return notFound(a);
}

fn knownSetting(app: *const App, key: []const u8) bool {
    for (setting_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return providerSetting(app, key) != null;
}

fn notFound(a: std.mem.Allocator) Response {
    return fail(a, .{ .status = .not_found, .code = "not_found" });
}

fn badRequest(a: std.mem.Allocator, what: []const u8) Response {
    return fail(a, .{ .status = .bad_request, .code = "bad_request", .message = what });
}

fn ambiguous(a: std.mem.Allocator, list: []const query.Task) Response {
    return fail(a, .{ .status = .conflict, .code = "AmbiguousTask", .message = "several tasks match; use #id", .candidates = list });
}

const Existing = union(enum) { id: i64, response: Response };

/// An existing task, or the response to send instead (ambiguous match).
fn resolveExisting(app: *App, a: std.mem.Allocator, text: []const u8) !Existing {
    return switch (try query.resolve(app.store, a, text)) {
        .found => |id| .{ .id = id },
        .none => error.UnknownTask,
        .ambiguous => |list| .{ .response = ambiguous(a, list) },
    };
}

fn parseBody(comptime T: type, a: std.mem.Allocator, body: []const u8) !?T {
    return std.json.parseFromSliceLeaky(T, a, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn param(a: std.mem.Allocator, params: []const u8, name: []const u8) !?[]const u8 {
    var parts = std.mem.splitScalar(u8, params, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.mem.eql(u8, part[0..eq], name)) continue;
        const decoded = try a.dupe(u8, part[eq + 1 ..]);
        std.mem.replaceScalar(u8, decoded, '+', ' ');
        return std.Uri.percentDecodeInPlace(decoded);
    }
    return null;
}

pub const Date = struct { year: u16, month: u16, day: u16, text: []const u8 };

pub fn parseDate(a: std.mem.Allocator, text: []const u8) !Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(u16, text[5..7], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(u16, text[8..10], 10) catch return error.InvalidDate;
    if (year < 1970 or month < 1 or month > 12 or d < 1 or d > std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return error.InvalidDate;
    return .{ .year = year, .month = month, .day = d, .text = try a.dupe(u8, text) };
}

fn loadZone(app: *App, a: std.mem.Allocator) !zone.Zone {
    const id = try app.store.reportingZone() orelse return zone.Zone.load("UTC");
    defer app.store.allocator.free(id);
    _ = a;
    return zone.Zone.load(id);
}

fn dateParam(app: *App, a: std.mem.Allocator, text: ?[]const u8) !Date {
    if (text) |t| return parseDate(a, t);
    const z = try loadZone(app, a);
    const today = try z.dateOf(app.clock());
    return .{ .year = today.year, .month = today.month, .day = today.day, .text = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ today.year, today.month, today.day }) };
}

fn summaryOf(app: *App, a: std.mem.Allocator, date: []const u8) !?[]const u8 {
    const text = try app.store.daySummary(date) orelse return null;
    defer app.store.allocator.free(text);
    return try a.dupe(u8, text);
}

/// The day's lunch breaks: the recorded ones (older data), else the day's
/// longest pause between worked spans of at least half the minimum break
/// (10 minutes or more), so a short coffee break stays a paid break.
fn lunchesOf(app: *App, a: std.mem.Allocator, bounds: zone.Zone.Bounds) ![]query.Span {
    const now = app.clock();
    const recorded = try query.lunchesBetween(app.store, a, bounds.start_ms, bounds.end_ms, now);
    if (recorded.len > 0) return recorded;
    const least: i64 = @as(i64, @max(10, (try app.store.lunchMinutes()) / 2)) * 60_000;
    var best: ?query.Span = null;
    var reach: ?i64 = null;
    for (try query.intervalsBetween(app.store, a, bounds.start_ms, bounds.end_ms)) |i| {
        const end = i.end_ms orelse now;
        if (reach) |r| {
            if (i.start_ms - r >= least) {
                if (best == null or i.start_ms - r > best.?.end_ms - best.?.start_ms) best = .{ .start_ms = r, .end_ms = i.start_ms };
            }
            reach = @max(r, end);
        } else reach = end;
    }
    const out = try a.alloc(query.Span, if (best != null) 1 else 0);
    if (best) |b| out[0] = b;
    return out;
}

/// The day's schedule, with the provider's paid break windows placed on it
/// and the day's lunch breaks.
fn scheduleFor(app: *App, a: std.mem.Allocator, bounds: zone.Zone.Bounds) !days.Schedule {
    var windows: std.ArrayList(days.PaidWindow) = .empty;
    for (try paidBreaks(app, a)) |p| {
        const start = bounds.start_ms + @as(i64, p.from_min) * 60_000;
        const end = @min(bounds.end_ms, bounds.start_ms + @as(i64, p.to_min) * 60_000);
        if (end > start) try windows.append(a, .{ .start_ms = start, .end_ms = end, .allow_ms = @as(i64, p.minutes) * 60_000 });
    }
    var lunches: std.ArrayList(days.Span) = .empty;
    for (try lunchesOf(app, a, bounds)) |l| try lunches.append(a, .{ .start_ms = l.start_ms, .end_ms = l.end_ms });
    return .{
        .daily_work_minutes = try app.store.dailyWorkMinutes(),
        .lunch_minutes = try app.store.lunchMinutes(),
        .paid = windows.items,
        .lunches = lunches.items,
    };
}

const Numbers = struct {
    total_ms: i64,
    paid_break_ms: i64,
    hops: u32,
    working: bool,
    first_start_ms: ?i64,
    remaining_ms: i64,
    clock_out_ms: ?i64,
    expected_return_ms: ?i64,
    earliest_clock_out_ms: ?i64,
};

fn numbersOf(n: days.DayNumbers) Numbers {
    return .{
        .total_ms = n.total_ms,
        .paid_break_ms = n.paid_break_ms,
        .hops = n.hops,
        .working = n.working,
        .first_start_ms = n.first_start_ms,
        .remaining_ms = n.remaining_ms,
        .clock_out_ms = n.clock_out_ms,
        .expected_return_ms = n.expected_return_ms,
        .earliest_clock_out_ms = n.earliest_clock_out_ms,
    };
}

fn zoneName(app: *App, a: std.mem.Allocator) ![]const u8 {
    const id = try app.store.reportingZone() orelse return "UTC";
    defer app.store.allocator.free(id);
    return a.dupe(u8, id);
}

fn state(app: *App, a: std.mem.Allocator) !Response {
    const now = app.clock();
    const z = try loadZone(app, a);
    const today = try dateParam(app, a, null);
    const bounds = try z.dayBounds(today.year, today.month, today.day);
    const n = try days.dayNumbers(app.store, a, bounds.start_ms, bounds.end_ms, now, try scheduleFor(app, a, bounds));
    const open = try query.openIntervals(app.store, a);
    var focus: ?query.Interval = null;
    var parallel: std.ArrayList(query.Interval) = .empty;
    for (open) |interval| {
        if (std.mem.eql(u8, interval.role, "focus")) focus = interval else try parallel.append(a, interval);
    }
    return send(a, .ok, .{
        .now_ms = now,
        .zone = try zoneName(app, a),
        .date = today.text,
        .provider = app.provider,
        .link = app.traits.link,
        // The provider's paid break windows, shown when no override is set.
        .provider_paid_breaks = app.traits.paid_breaks,
        .lunch_open = try query.lunchOpen(app.store),
        .focus = focus,
        .focus_fields = if (focus) |f| try query.fields(app.store, a, f.task.id) else &.{},
        .parallel = parallel.items,
        .saved = try query.savedSet(app.store, a),
        .numbers = numbersOf(n),
        .daily_work_minutes = try app.store.dailyWorkMinutes(),
    });
}

fn day(app: *App, a: std.mem.Allocator, text: ?[]const u8) !Response {
    const date = try dateParam(app, a, text);
    const z = try loadZone(app, a);
    const bounds = try z.dayBounds(date.year, date.month, date.day);
    const n = try days.dayNumbers(app.store, a, bounds.start_ms, bounds.end_ms, app.clock(), try scheduleFor(app, a, bounds));
    const TaskTotal = struct { task: query.Task, fields: []query.Field, focus_ms: i64, hops: u32 };
    var totals: std.ArrayList(TaskTotal) = .empty;
    for (n.tasks) |t| try totals.append(a, .{ .task = (try query.task(app.store, a, t.task_id)).?, .fields = try query.fields(app.store, a, t.task_id), .focus_ms = t.focus_ms, .hops = t.hops });
    std.mem.sort(TaskTotal, totals.items, {}, struct {
        fn lessThan(_: void, l: TaskTotal, r: TaskTotal) bool {
            return l.focus_ms > r.focus_ms;
        }
    }.lessThan);
    const intervals = try query.intervalsBetween(app.store, a, bounds.start_ms, bounds.end_ms);
    // Tasks seen only in parallel still get their fields, for the report.
    var others: std.ArrayList(TaskTotal) = .empty;
    for (intervals) |i| {
        const known = for (totals.items) |t| {
            if (t.task.id == i.task.id) break true;
        } else for (others.items) |t| {
            if (t.task.id == i.task.id) break true;
        } else false;
        if (!known) try others.append(a, .{ .task = i.task, .fields = try query.fields(app.store, a, i.task.id), .focus_ms = 0, .hops = 0 });
    }
    try totals.appendSlice(a, others.items);
    var last_end: ?i64 = null;
    if (!n.working) for (intervals) |i| {
        if (std.mem.eql(u8, i.role, "focus")) if (i.end_ms) |e| {
            last_end = @min(bounds.end_ms, @max(last_end orelse e, e));
        };
    };
    const lunches = try lunchesOf(app, a, bounds);
    const lunch_open = try query.lunchOpen(app.store);
    return send(a, .ok, .{
        .date = date.text,
        .zone = try zoneName(app, a),
        .start_ms = bounds.start_ms,
        .end_ms = bounds.end_ms,
        .numbers = numbersOf(n),
        .tasks = totals.items,
        .intervals = intervals,
        .summary = try summaryOf(app, a, date.text),
        .lunch_out_ms = if (lunches.len > 0) lunches[0].start_ms else null,
        .lunch_back_ms = if (lunches.len > 0 and !(lunch_open and lunches[lunches.len - 1].end_ms >= app.clock())) lunches[lunches.len - 1].end_ms else null,
        .last_end_ms = last_end,
        .changed_after_posting = try query.changedAfterPosting(app.store, date.text),
    });
}

// ---------------------------------------------------------------- traits

pub const PaidBreak = struct { from_min: u16, to_min: u16, minutes: u16 };

/// What the compiled-in provider allows (see `traits` in the contract).
pub const Traits = struct {
    sessions: bool = false,
    /// Opens a ref: `{ref}` is replaced by the percent-encoded ref.
    link: ?[]const u8 = null,
    paid_breaks: []const PaidBreak = &.{},
    /// Kept as `provider.<name>` settings and sent with every post.
    settings: []const ProviderSetting = &.{},
    /// Chosen per post in the Post dialog (or `post -o`) and sent with it.
    post_options: []const PostOption = &.{},
};

pub const SettingChoice = struct { value: []const u8, label: []const u8, labels: ?std.json.Value = null };

/// `type` is "choice" (one of `choices`) or "text" (one line, up to 200 bytes).
pub const ProviderSetting = struct {
    name: []const u8,
    label: []const u8,
    labels: ?std.json.Value = null,
    hint: ?[]const u8 = null,
    hints: ?std.json.Value = null,
    type: []const u8,
    choices: []const SettingChoice = &.{},
    default: []const u8 = "",
};

/// `type` is "bool", the only kind so far.
pub const PostOption = struct {
    name: []const u8,
    label: []const u8,
    labels: ?std.json.Value = null,
    hint: ?[]const u8 = null,
    hints: ?std.json.Value = null,
    type: []const u8 = "bool",
};

const max_declared = 16;

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// One line of text, as a text setting holds.
fn validLine(text: []const u8) bool {
    if (text.len > 200 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

fn validProviderValue(s: ProviderSetting, value: []const u8) bool {
    if (std.mem.eql(u8, s.type, "text")) return validLine(value);
    for (s.choices) |c| if (std.mem.eql(u8, c.value, value)) return true;
    return false;
}

fn declaredSettings(a: std.mem.Allocator, raw: []const ProviderSetting) []const ProviderSetting {
    var list: std.ArrayList(ProviderSetting) = .empty;
    for (raw) |s| {
        if (!validName(s.name) or s.label.len == 0 or list.items.len >= max_declared) continue;
        const choice = std.mem.eql(u8, s.type, "choice");
        if (!choice and !std.mem.eql(u8, s.type, "text")) continue;
        if (choice and s.choices.len == 0) continue;
        var kept = s;
        // A choice always has a value: the declared default, else the first.
        if (choice and !validProviderValue(s, s.default)) kept.default = s.choices[0].value;
        if (!choice and !validLine(s.default)) kept.default = "";
        list.append(a, kept) catch return list.items;
    }
    return list.items;
}

fn declaredOptions(a: std.mem.Allocator, raw: []const PostOption) []const PostOption {
    var list: std.ArrayList(PostOption) = .empty;
    for (raw) |o| {
        if (!validName(o.name) or o.label.len == 0 or !std.mem.eql(u8, o.type, "bool") or list.items.len >= max_declared) continue;
        list.append(a, o) catch return list.items;
    }
    return list.items;
}

const provider_prefix = "provider.";

/// The provider setting a `provider.<name>` key names, if it declared one.
fn providerSetting(app: *const App, key: []const u8) ?ProviderSetting {
    if (!std.mem.startsWith(u8, key, provider_prefix)) return null;
    for (app.traits.settings) |s| if (std.mem.eql(u8, s.name, key[provider_prefix.len..])) return s;
    return null;
}

/// Every declared provider setting, stored or default, as a post sends them.
fn providerValues(app: *App, a: std.mem.Allocator) !std.json.ArrayHashMap([]const u8) {
    var values: std.json.ArrayHashMap([]const u8) = .{};
    for (app.traits.settings) |s| {
        const key = try std.mem.concat(a, u8, &.{ provider_prefix, s.name });
        const stored = try app.store.getSetting(key);
        const value = if (stored) |v| blk: {
            defer app.store.allocator.free(v);
            break :blk if (validProviderValue(s, v)) try a.dupe(u8, v) else s.default;
        } else s.default;
        try values.map.put(a, s.name, value);
    }
    return values;
}

fn clockMinutes(text: []const u8, allow_end: bool) ?u16 {
    if (text.len != 5 or text[2] != ':') return null;
    const h = std.fmt.parseInt(u16, text[0..2], 10) catch return null;
    const m = std.fmt.parseInt(u16, text[3..5], 10) catch return null;
    if (m > 59) return null;
    if (h == 24 and m == 0 and allow_end) return 1440;
    if (h > 23) return null;
    return h * 60 + m;
}

/// Reads the `paid_breaks` setting: "HH:MM-HH:MM=minutes" items joined by
/// commas. Null when any item is malformed.
pub fn parsePaidBreaks(a: std.mem.Allocator, text: []const u8) !?[]const PaidBreak {
    var list: std.ArrayList(PaidBreak) = .empty;
    var items = std.mem.tokenizeScalar(u8, text, ',');
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse return null;
        const dash = std.mem.indexOfScalar(u8, item[0..eq], '-') orelse return null;
        const from = clockMinutes(item[0..dash], false) orelse return null;
        const to = clockMinutes(item[dash + 1 .. eq], true) orelse return null;
        const minutes = std.fmt.parseInt(u16, item[eq + 1 ..], 10) catch return null;
        if (from >= to or minutes < 1 or minutes > 240 or list.items.len >= 8) return null;
        try list.append(a, .{ .from_min = from, .to_min = to, .minutes = minutes });
    }
    return list.items;
}

/// The paid breaks in force: the user's setting, else the provider's.
fn paidBreaks(app: *App, a: std.mem.Allocator) ![]const PaidBreak {
    const text = try app.store.getSetting("paid_breaks") orelse return app.traits.paid_breaks;
    defer app.store.allocator.free(text);
    return try parsePaidBreaks(a, text) orelse app.traits.paid_breaks;
}

/// Reads a provider's static traits. A malformed part is dropped, never fatal:
/// the provider still works without it.
pub fn parseTraits(a: std.mem.Allocator, json: []const u8) Traits {
    if (json.len == 0) return .{};
    const Raw = struct {
        link: ?[]const u8 = null,
        paid_breaks: []const struct { from: []const u8, to: []const u8, minutes: u16 } = &.{},
    };
    const raw = std.json.parseFromSliceLeaky(Raw, a, json, .{ .ignore_unknown_fields = true }) catch return .{};
    var traits: Traits = .{};
    if (std.json.parseFromSliceLeaky(struct { sessions: bool = false }, a, json, .{ .ignore_unknown_fields = true })) |parsed| traits.sessions = parsed.sessions else |_| {}
    if (raw.link) |link| {
        const web = std.mem.startsWith(u8, link, "https://") or std.mem.startsWith(u8, link, "http://");
        if (web and std.mem.indexOf(u8, link, "{ref}") != null) traits.link = link;
    }
    var list: std.ArrayList(PaidBreak) = .empty;
    for (raw.paid_breaks) |p| {
        const from = clockMinutes(p.from, false) orelse continue;
        const to = clockMinutes(p.to, true) orelse continue;
        if (from >= to or p.minutes < 1 or p.minutes > 240 or list.items.len >= 8) continue;
        list.append(a, .{ .from_min = from, .to_min = to, .minutes = p.minutes }) catch return traits;
    }
    traits.paid_breaks = list.items;
    if (std.json.parseFromSliceLeaky(struct { settings: []const ProviderSetting = &.{} }, a, json, .{ .ignore_unknown_fields = true })) |d| {
        traits.settings = declaredSettings(a, d.settings);
    } else |_| {}
    if (std.json.parseFromSliceLeaky(struct { post_options: []const PostOption = &.{} }, a, json, .{ .ignore_unknown_fields = true })) |d| {
        traits.post_options = declaredOptions(a, d.post_options);
    } else |_| {}
    return traits;
}

// ---------------------------------------------------------------- calendar

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn civilDays(year: i64, month: i64, d: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn fromCivilDays(a: std.mem.Allocator, n: i64) !Date {
    const z = n + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d), .text = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)) }) };
}

fn dayIndex(date: Date) i64 {
    return civilDays(date.year, date.month, date.day);
}

fn isWeekend(n: i64) bool {
    const weekday = @mod(n + 4, 7); // 1970-01-01 was a Thursday; 0 is Sunday
    return weekday == 0 or weekday == 6;
}

fn numbersOn(app: *App, a: std.mem.Allocator, z: *const zone.Zone, date: Date) !days.DayNumbers {
    const bounds = try z.dayBounds(date.year, date.month, date.day);
    return days.dayNumbers(app.store, a, bounds.start_ms, bounds.end_ms, app.clock(), try scheduleFor(app, a, bounds));
}

fn intParam(a: std.mem.Allocator, params: []const u8, name: []const u8, default: u32, max: u32) !?u32 {
    const text = try param(a, params, name) orelse return default;
    const v = std.fmt.parseInt(u32, text, 10) catch return null;
    if (v < 1) return null;
    return @min(v, max);
}

/// Adds the focus span [start, end) to `totals`, day by day.
fn spreadByDay(a: std.mem.Allocator, z: *const zone.Zone, totals: *std.StringArrayHashMapUnmanaged(i64), start: i64, end: i64) !void {
    var at = start;
    var guard: u32 = 0;
    while (at < end and guard < 400) : (guard += 1) {
        const d = try z.dateOf(at);
        const bounds = try z.dayBounds(d.year, d.month, d.day);
        const part = @min(end, bounds.end_ms) - at;
        const key = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
        const slot = try totals.getOrPut(a, key);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += part;
        at = bounds.end_ms;
    }
}

fn search(app: *App, a: std.mem.Allocator, params: []const u8) !Response {
    const q = std.mem.trim(u8, try param(a, params, "q") orelse "", " \t");
    if (q.len == 0) return send(a, .ok, .{ .results = [_]u8{} });
    const limit = try intParam(a, params, "limit", 25, 100) orelse return badRequest(a, "limit");
    const z = try loadZone(app, a);
    const now = app.clock();
    const DayTotal = struct { date: []const u8, total_ms: i64 };
    const Result = struct {
        task: query.Task,
        fields: []query.Field,
        snippet: ?[]const u8,
        total_ms: i64,
        day_count: usize,
        last_date: ?[]const u8,
        /// Most recent first, at most 12.
        days: []DayTotal,
    };
    var results: std.ArrayList(Result) = .empty;
    for (try query.search(app.store, a, q, limit)) |found| {
        var totals: std.StringArrayHashMapUnmanaged(i64) = .empty;
        var total: i64 = 0;
        for (try query.focusSpans(app.store, a, found.task.id)) |span| {
            const end = span.end_ms orelse now;
            if (end <= span.start_ms) continue;
            total += end - span.start_ms;
            try spreadByDay(a, &z, &totals, span.start_ms, end);
        }
        const keys = totals.keys();
        var list: std.ArrayList(DayTotal) = .empty;
        var i = keys.len;
        while (i > 0 and list.items.len < 12) {
            i -= 1;
            try list.append(a, .{ .date = keys[i], .total_ms = totals.values()[i] });
        }
        try results.append(a, .{
            .task = found.task,
            .fields = try query.fields(app.store, a, found.task.id),
            .snippet = found.snippet,
            .total_ms = total,
            .day_count = keys.len,
            .last_date = if (keys.len > 0) keys[keys.len - 1] else null,
            .days = list.items,
        });
    }
    return send(a, .ok, .{ .results = results.items });
}

fn dayTotals(app: *App, a: std.mem.Allocator, params: []const u8) !Response {
    const from = try parseDate(a, try param(a, params, "from") orelse return badRequest(a, "from"));
    const to = try parseDate(a, try param(a, params, "to") orelse return badRequest(a, "to"));
    const first = dayIndex(from);
    const last = dayIndex(to);
    if (last < first or last - first > 62) return badRequest(a, "range");
    const z = try loadZone(app, a);
    var totals: std.json.ArrayHashMap(i64) = .{};
    var n = first;
    while (n <= last) : (n += 1) {
        const date = try fromCivilDays(a, n);
        const numbers = try numbersOn(app, a, &z, date);
        if (numbers.total_ms > 0) try totals.map.put(a, date.text, numbers.total_ms);
    }
    return send(a, .ok, .{ .totals = totals });
}

fn frequentTasks(app: *App, a: std.mem.Allocator, params: []const u8) !Response {
    const day_count = try intParam(a, params, "days", 30, 365) orelse return badRequest(a, "days");
    const limit = try intParam(a, params, "limit", 8, 50) orelse return badRequest(a, "limit");
    const now = app.clock();
    const Item = struct { task: query.Task, fields: []query.Field, focus_ms: i64 };
    var list: std.ArrayList(Item) = .empty;
    for (try query.frequent(app.store, a, now - @as(i64, day_count) * 86_400_000, now, limit)) |f| {
        try list.append(a, .{ .task = f.task, .fields = try query.fields(app.store, a, f.task.id), .focus_ms = f.focus_ms });
    }
    return send(a, .ok, .{ .tasks = list.items });
}

/// Focus per day over the last `days` days, one series per task or per
/// value of a provider field.
fn chart(app: *App, a: std.mem.Allocator, params: []const u8) !Response {
    const day_count = try intParam(a, params, "days", 14, 90) orelse return badRequest(a, "days");
    const group = try param(a, params, "group") orelse "task";
    const z = try loadZone(app, a);
    const today = dayIndex(try dateParam(app, a, null));
    var dates: std.ArrayList([]const u8) = .empty;
    const Series = struct { label: []const u8, total_ms: i64 = 0, ms: []i64 };
    var series: std.StringArrayHashMapUnmanaged(Series) = .empty;
    var col: usize = 0;
    while (col < day_count) : (col += 1) {
        const date = try fromCivilDays(a, today - @as(i64, @intCast(day_count - 1 - col)));
        try dates.append(a, date.text);
        const numbers = try numbersOn(app, a, &z, date);
        for (numbers.tasks) |t| {
            if (t.focus_ms <= 0) continue;
            const task = (try query.task(app.store, a, t.task_id)).?;
            const label: []const u8 = if (std.mem.eql(u8, group, "task"))
                (if (task.ref) |r| try std.fmt.allocPrint(a, "{s} {s}", .{ r, task.title }) else task.title)
            else blk: {
                for (try query.fields(app.store, a, t.task_id)) |f| if (std.mem.eql(u8, f.name, group)) break :blk f.value;
                break :blk "-";
            };
            const key = if (std.mem.eql(u8, group, "task")) try std.fmt.allocPrint(a, "#{d}", .{t.task_id}) else label;
            const slot = try series.getOrPut(a, key);
            if (!slot.found_existing) {
                const ms = try a.alloc(i64, day_count);
                @memset(ms, 0);
                slot.value_ptr.* = .{ .label = label, .ms = ms };
            }
            slot.value_ptr.ms[col] += t.focus_ms;
            slot.value_ptr.total_ms += t.focus_ms;
        }
    }
    const list = try a.dupe(Series, series.values());
    std.mem.sort(Series, list, {}, struct {
        fn lessThan(_: void, l: Series, r: Series) bool {
            return l.total_ms > r.total_ms;
        }
    }.lessThan);
    return send(a, .ok, .{ .dates = dates.items, .series = list });
}

// ---------------------------------------------------------------- day status

/// One bound task with focus time on one listed day.
const StatusItem = struct {
    row: usize,
    request: []const u8,
    in_flight: bool,
    confirmed: bool,
    /// The quote says something is left to post; null until quoted.
    left: ?bool = null,
    failed: bool = false,
};

const DayRow = struct {
    date: []const u8,
    total_ms: i64,
    paid_break_ms: i64,
    /// none (nothing to post), posted, partial, unposted, unknown (a post's
    /// outcome is not known), changed (edited after posting), error.
    status: []const u8 = "none",
    changed_after_posting: bool,
};

pub const StatusJob = struct {
    rows: []DayRow,
    items: []StatusItem,
    next: usize,

    fn advance(job: *StatusJob, from: usize) ?usize {
        var i = from;
        while (i < job.items.len) : (i += 1) if (!job.items[i].in_flight) return i;
        return null;
    }
};

/// The last `count` days (work days with `weekends=0`), oldest first, each
/// with its focus total and posting status. The status asks the provider's
/// quote for every bound task, one call at a time; nothing is posted.
fn dayList(app: *App, a: std.mem.Allocator, params: []const u8) !Response {
    const session_mode = try sessionsMode(app);
    const count = try intParam(a, params, "count", 7, 90) orelse return badRequest(a, "count");
    const weekends = !std.mem.eql(u8, try param(a, params, "weekends") orelse "1", "0");
    const z = try loadZone(app, a);
    var n = dayIndex(try dateParam(app, a, null));
    var picked: std.ArrayList(Date) = .empty;
    var guard: u32 = 0;
    while (picked.items.len < count and guard < 200) : ({
        n -= 1;
        guard += 1;
    }) {
        if (!weekends and isWeekend(n)) continue;
        try picked.append(a, try fromCivilDays(a, n));
    }
    std.mem.reverse(Date, picked.items);
    const now = app.clock();
    var rows: std.ArrayList(DayRow) = .empty;
    var items: std.ArrayList(StatusItem) = .empty;
    for (picked.items) |date| {
        const bounds = try z.dayBounds(date.year, date.month, date.day);
        const numbers = try days.dayNumbers(app.store, a, bounds.start_ms, bounds.end_ms, now, try scheduleFor(app, a, bounds));
        const row = rows.items.len;
        try rows.append(a, .{ .date = date.text, .total_ms = numbers.total_ms, .paid_break_ms = numbers.paid_break_ms, .changed_after_posting = try query.changedAfterPosting(app.store, date.text) });
        const instance = app.provider orelse continue;
        for (numbers.tasks) |t| {
            if (t.focus_ms <= 0) continue;
            const b = try query.binding(app.store, a, t.task_id) orelse continue;
            if (!std.mem.eql(u8, b.instance, instance)) continue;
            const posted = try query.postedOn(app.store, a, date.text, instance, b.ref);
            const remaining = if (session_mode) try remainingFor(app, a, date, t.task_id, instance, b.ref) else Remaining{ .pieces = &.{}, .open_session = false };
            const request = try std.json.Stringify.valueAlloc(a, .{
                .day = date.text, .ref = b.ref, .day_over = now >= bounds.end_ms, .task_open = try query.taskOpen(app.store, t.task_id),
                .total_focus_ms = if (session_mode) focusLength(remaining.pieces) else t.focus_ms,
                .posted = if (session_mode) &.{} else posted,
            }, .{});
            try items.append(a, .{ .row = row, .request = request, .in_flight = try app.store.isBlocked(date.text, instance, b.ref), .confirmed = posted.len > 0 });
        }
    }
    const job = try a.create(StatusJob);
    job.* = .{ .rows = rows.items, .items = items.items, .next = 0 };
    if (job.advance(0)) |first| {
        job.next = first;
        return .{ .status = .ok, .body = "", .followup = .{ .status = job } };
    }
    return finishStatus(a, job);
}

fn finishStatus(a: std.mem.Allocator, job: *StatusJob) Response {
    for (job.rows, 0..) |*row, r| {
        var counted: usize = 0;
        var in_flight = false;
        var failed = false;
        var left: usize = 0;
        var confirmed: usize = 0;
        for (job.items) |item| {
            if (item.row != r) continue;
            if (item.in_flight) {
                in_flight = true;
                counted += 1;
                continue;
            }
            if (item.failed) {
                failed = true;
                continue;
            }
            const has_left = item.left orelse false;
            // Not postable and never posted: it does not count.
            if (!has_left and !item.confirmed) continue;
            counted += 1;
            if (has_left) left += 1;
            if (item.confirmed) confirmed += 1;
        }
        row.status = if (in_flight)
            "unknown"
        else if (failed)
            "error"
        else if (counted == 0)
            "none"
        else if (left == 0)
            (if (row.changed_after_posting) "changed" else "posted")
        else if (confirmed == 0)
            "unposted"
        else
            "partial";
    }
    return send(a, .ok, .{ .days = job.rows });
}

// ---------------------------------------------------------------- history

const SeenBody = struct { start_ms: i64, end_ms: ?i64 = null };

fn seenOf(b: SeenBody) Store.Span {
    return .{ .start_ms = b.start_ms, .end_ms = b.end_ms };
}

fn idBetween(path: []const u8, prefix: []const u8, suffix: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix) or path.len <= prefix.len + suffix.len) return null;
    return std.fmt.parseInt(i64, path[prefix.len .. path.len - suffix.len], 10) catch null;
}

fn history(app: *App, a: std.mem.Allocator, req: Request, path: []const u8) !?Response {
    if (is(req, .POST, path, "/api/intervals")) {
        const body = try parseBody(struct { task: []const u8, role: []const u8 = "focus", start_ms: i64, end_ms: i64 }, a, req.body) orelse return badRequest(a, "body");
        const role = std.meta.stringToEnum(store_mod.Role, body.role) orelse return badRequest(a, "role");
        const id = switch (try resolveExisting(app, a, body.task)) {
            .id => |id| id,
            .response => |r| return r,
        };
        const interval = try app.store.addInterval(id, role, body.start_ms, body.end_ms, app.clock());
        return send(a, .created, .{ .interval = interval });
    }
    if (is(req, .POST, path, "/api/intervals/merge")) {
        const Side = struct { id: i64, start_ms: i64, end_ms: ?i64 = null };
        const body = try parseBody(struct { first: Side, second: Side }, a, req.body) orelse return badRequest(a, "body");
        try app.store.mergeIntervals(body.first.id, .{ .start_ms = body.first.start_ms, .end_ms = body.first.end_ms }, body.second.id, .{ .start_ms = body.second.start_ms, .end_ms = body.second.end_ms }, app.clock());
        return send(a, .ok, .{ .interval = body.first.id });
    }
    if (req.method == .POST) if (idBetween(path, "/api/tasks/", "/delete")) |id| {
        try app.store.deleteTask(id, app.clock());
        return send(a, .ok, .{ .deleted = id });
    };
    if (req.method == .POST) if (idBetween(path, "/api/intervals/", "/move")) |id| {
        const body = try parseBody(struct { seen: SeenBody, task: i64, from_ms: ?i64 = null, to_ms: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        const part: ?Store.Part = if (body.from_ms != null and body.to_ms != null) .{ .from = body.from_ms.?, .to = body.to_ms.? } else null;
        const moved = try app.store.moveInterval(id, seenOf(body.seen), body.task, part, app.clock());
        return send(a, .ok, .{ .interval = moved, .task = body.task });
    };
    if (req.method == .POST) if (idBetween(path, "/api/intervals/", "/delete")) |id| {
        const body = try parseBody(struct { seen: SeenBody }, a, req.body) orelse return badRequest(a, "body");
        try app.store.deleteInterval(id, seenOf(body.seen), app.clock());
        return send(a, .ok, .{ .deleted = id });
    };
    if (req.method == .PATCH) if (idBetween(path, "/api/intervals/", "")) |id| {
        const body = try parseBody(struct { seen: SeenBody, start_ms: i64, end_ms: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        try app.store.editInterval(id, seenOf(body.seen), body.start_ms, body.end_ms, app.clock());
        return send(a, .ok, .{ .interval = id });
    };
    if (req.method == .POST) if (idBetween(path, "/api/notes/", "/delete")) |id| {
        try app.store.deleteNote(id, app.clock());
        return send(a, .ok, .{ .deleted = id });
    };
    if (req.method == .PATCH) if (idBetween(path, "/api/notes/", "")) |id| {
        const body = try parseBody(struct { text: []const u8, at_ms: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        try app.store.editNote(id, std.mem.trim(u8, body.text, " \t\r\n"), body.at_ms, app.clock());
        return send(a, .ok, .{ .note = id });
    };
    return null;
}

const ui_flags = [_][]const u8{ "ui_hide_weekends", "ui_show_keys", "ui_show_add_entry", "ui_chart_visible", "ui_left_collapsed", "ui_autofill_obs", "ui_links", "ui_tour_offered", "ui_single_keys", "ui_open_on_launch", "post_sessions" };

/// Dashboard preferences: checked here, since the store does not know them.
fn validUi(app: *const App, key: []const u8, value: ?[]const u8) bool {
    const v = value orelse return true;
    if (providerSetting(app, key)) |s| return validProviderValue(s, v);
    for (ui_flags) |f| if (std.mem.eql(u8, key, f)) return std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "1");
    const Choice = struct { key: []const u8, values: []const []const u8 };
    const choices = [_]Choice{
        .{ .key = "ui_day_order", .values = &.{ "oldest", "newest" } },
        .{ .key = "ui_lang", .values = &.{ "en", "pt", "ja" } },
        .{ .key = "ui_summary_format", .values = &.{ "grouped", "chronological" } },
        .{ .key = "ui_time_format", .values = &.{ "system", "24", "12" } },
        .{ .key = "ui_chart_view", .values = &.{ "bars", "lanes" } },
    };
    for (choices) |c| if (std.mem.eql(u8, key, c.key)) {
        for (c.values) |allowed| if (std.mem.eql(u8, v, allowed)) return true;
        return false;
    };
    if (std.mem.eql(u8, key, "paid_breaks")) {
        var buffer: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        return (parsePaidBreaks(fba.allocator(), v) catch return false) != null;
    }
    // Provider fields kept off the chart tabs, as a JSON list of names.
    if (std.mem.eql(u8, key, "ui_chart_hidden")) {
        if (v.len > 1024) return false;
        var buffer: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        _ = std.json.parseFromSliceLeaky([]const []const u8, fba.allocator(), v, .{}) catch return false;
        return true;
    }
    if (std.mem.eql(u8, key, "ui_sidebar_days") or std.mem.eql(u8, key, "ui_chart_days")) {
        const n = std.fmt.parseInt(u16, v, 10) catch return false;
        return n >= 1 and n <= 90;
    }
    return true;
}

// ---------------------------------------------------------------- provider

fn bindTask(app: *App, a: std.mem.Allocator, id: i64, raw: []const u8) !Response {
    const instance = app.provider orelse return error.NoProvider;
    const body = try parseBody(struct { ref: []const u8 }, a, raw) orelse return badRequest(a, "body");
    const ref = std.mem.trim(u8, body.ref, " \t");
    if (ref.len == 0) return badRequest(a, "ref");
    _ = try query.task(app.store, a, id) orelse return error.UnknownTask;
    if (try app.store.taskByBinding(instance, ref)) |bound| if (bound != id) return error.BindingConflict;
    return .{ .status = .ok, .body = "", .followup = .{ .lookup = .{ .task = id, .ref = try a.dupe(u8, ref) } } };
}

const Offer = struct {
    task: query.Task,
    ref: ?[]const u8,
    total_focus_ms: i64,
    blocked: bool,
    /// Bound to this provider, with focus time, and not blocked by a call in flight.
    postable: bool,
    postings: []query.Posting,
    sessions: []sessions.Session,
    open_session: bool,
};

fn sessionsMode(app: *App) !bool {
    if (!app.traits.sessions) return false;
    const value = try app.store.getSetting("post_sessions") orelse return false;
    defer app.store.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

const Remaining = struct { pieces: []sessions.Session, open_session: bool };

fn remainingFor(app: *App, a: std.mem.Allocator, date: Date, task: i64, instance: []const u8, ref: []const u8) !Remaining {
    const z = try loadZone(app, a);
    const bounds = try z.dayBounds(date.year, date.month, date.day);
    const focus = try query.focusOnDay(app.store, a, task, bounds.start_ms, bounds.end_ms);
    const coverage = try query.coverageOn(app.store, a, date.text, instance, ref);
    const focus_spans = try a.alloc(sessions.Span, focus.spans.len);
    for (focus.spans, 0..) |span, i| focus_spans[i] = .{ .start_ms = span.start_ms, .end_ms = span.end_ms };
    const covered_spans = try a.alloc(sessions.Span, coverage.len);
    for (coverage, 0..) |span, i| covered_spans[i] = .{ .start_ms = span.start_ms, .end_ms = span.end_ms };
    const pieces = try sessions.remaining(a, &z, bounds.start_ms, bounds.end_ms, focus_spans, covered_spans);
    return .{ .pieces = pieces, .open_session = focus.open_session };
}

fn focusLength(pieces: []const sessions.Session) i64 {
    var total: i64 = 0;
    for (pieces) |piece| total += piece.end_ms - piece.start_ms;
    return total;
}

fn postedIds(a: std.mem.Allocator, chain: *const SessionChain) ![]i64 {
    const ids = try a.alloc(i64, chain.confirmed.items.len);
    for (chain.confirmed.items, 0..) |item, i| ids[i] = item.id;
    return ids;
}

fn sessionPosting(a: std.mem.Allocator, row: query.Posting, piece: sessions.Session) !std.json.Value {
    const raw = try std.json.Stringify.valueAlloc(a, row, .{});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    var value = parsed;
    try value.object.put(a, "start", .{ .string = piece.start });
    try value.object.put(a, "end", .{ .string = piece.end });
    return value;
}

fn chainSuccess(app: *App, a: std.mem.Allocator, chain: *SessionChain) !Response {
    var rows: std.ArrayList(std.json.Value) = .empty;
    for (chain.confirmed.items) |item| try rows.append(a, try sessionPosting(a, (try query.posting(app.store, a, item.id)).?, item.session));
    return send(a, .created, .{ .posting = rows.items[rows.items.len - 1], .postings = rows.items });
}

fn nextSessionQuote(app: *App, a: std.mem.Allocator, chain: *SessionChain) !?Response {
    if (chain.confirmed.items.len >= chain.limit) return null;
    const date = try dateParam(app, a, chain.day);
    if (try app.store.isBlocked(chain.day, app.provider.?, chain.ref))
        return try postingError(a, chain, .conflict, "PostingBlocked", "");
    if (try query.hasTotalPosting(app.store, chain.day, app.provider.?, chain.ref))
        return try postingError(a, chain, .conflict, "PostedAsTotal", "this day was posted as a total; turn off posting by session to post the rest");
    const remaining = try remainingFor(app, a, date, chain.task, app.provider.?, chain.ref);
    if (remaining.pieces.len == 0) return null;
    const piece = remaining.pieces[0];
    const fingerprint = try query.postedFingerprint(app.store, a, chain.day, app.provider.?, chain.ref);
    const request = try std.json.Stringify.valueAlloc(a, .{
        .day = chain.day, .ref = chain.ref, .day_over = chain.day_over,
        .task_open = try query.taskOpen(app.store, chain.task),
        .total_focus_ms = piece.end_ms - piece.start_ms, .posted = @as([]const query.Posted, &.{}),
    }, .{});
    return .{ .status = .ok, .body = "", .followup = .{ .quote = .{
        .day = chain.day, .task = chain.task, .ref = chain.ref, .request = request,
        .fingerprint = fingerprint.text, .text = chain.text, .day_over = chain.day_over,
        .task_open = try query.taskOpen(app.store, chain.task),
        .total_focus_ms = piece.end_ms - piece.start_ms, .title = chain.title,
        .settings = chain.settings, .options = chain.options, .session = piece, .chain = chain,
    } } };
}

fn focusOn(app: *App, a: std.mem.Allocator, date: Date) ![]days.TaskNumbers {
    const z = try loadZone(app, a);
    const bounds = try z.dayBounds(date.year, date.month, date.day);
    const n = try days.dayNumbers(app.store, a, bounds.start_ms, bounds.end_ms, app.clock(), try scheduleFor(app, a, bounds));
    return n.tasks;
}

fn offers(app: *App, a: std.mem.Allocator, text: ?[]const u8) !Response {
    const date = try dateParam(app, a, text);
    const mode = try sessionsMode(app);
    var list: std.ArrayList(Offer) = .empty;
    for (try focusOn(app, a, date)) |t| {
        const b = try query.binding(app.store, a, t.task_id);
        const mine = if (b) |v| app.provider != null and std.mem.eql(u8, v.instance, app.provider.?) else false;
        const blocked = if (mine) try app.store.isBlocked(date.text, b.?.instance, b.?.ref) else false;
        const remaining = if (mode and mine) try remainingFor(app, a, date, t.task_id, b.?.instance, b.?.ref) else Remaining{ .pieces = &.{}, .open_session = false };
        const total = if (mode and mine) try query.hasTotalPosting(app.store, date.text, b.?.instance, b.?.ref) else false;
        try list.append(a, .{
            .task = (try query.task(app.store, a, t.task_id)).?,
            .ref = if (mine) b.?.ref else null,
            .total_focus_ms = t.focus_ms,
            .blocked = blocked,
            .postable = mine and t.focus_ms > 0 and !blocked and (!mode or (remaining.pieces.len > 0 and !total)),
            .postings = try query.postingsOn(app.store, a, date.text, t.task_id),
            // A day posted as a total cannot take sessions: none are offered.
            .sessions = if (total) &.{} else remaining.pieces,
            .open_session = remaining.open_session,
        });
    }
    return send(a, .ok, .{ .date = date.text, .instance = app.provider, .sessions_mode = mode, .offers = list.items });
}

fn startPosting(app: *App, a: std.mem.Allocator, raw: []const u8) !Response {
    const instance = app.provider orelse return error.NoProvider;
    const body = try parseBody(struct { date: ?[]const u8 = null, task: []const u8, text: ?[]const u8 = null, dry_run: bool = false, options: std.json.ArrayHashMap(bool) = .{} }, a, raw) orelse return badRequest(a, "body");
    // Every declared option goes out, false unless chosen; an unknown one is refused.
    var options: std.json.ArrayHashMap(bool) = .{};
    for (app.traits.post_options) |o| try options.map.put(a, o.name, body.options.map.get(o.name) orelse false);
    for (body.options.map.keys()) |name| if (!options.map.contains(name)) return fail(a, .{ .status = .bad_request, .code = "UnknownOption", .message = name });
    const id = switch (try resolveExisting(app, a, body.task)) {
        .id => |id| id,
        .response => |r| return r,
    };
    const b = try query.binding(app.store, a, id) orelse return error.NotBound;
    if (!std.mem.eql(u8, b.instance, instance)) return error.NotBound;
    const date = try dateParam(app, a, body.date);
    if (try app.store.isBlocked(date.text, instance, b.ref)) return error.PostingBlocked;
    const mode = try sessionsMode(app);
    if (mode and try query.hasTotalPosting(app.store, date.text, instance, b.ref))
        return fail(a, .{ .status = .conflict, .code = "PostedAsTotal", .message = "this day was posted as a total; turn off posting by session to post the rest" });
    const remaining = if (mode) try remainingFor(app, a, date, id, instance, b.ref) else Remaining{ .pieces = &.{}, .open_session = false };
    if (mode and remaining.pieces.len == 0) {
        if (remaining.open_session) return fail(a, .{ .status = .conflict, .code = "SessionOpen", .message = "stop the running session to post it" });
        return error.NothingToPost;
    }
    var focus_ms: i64 = 0;
    for (try focusOn(app, a, date)) |t| {
        if (t.task_id == id) focus_ms = t.focus_ms;
    }
    if (focus_ms <= 0 and !mode) return error.NothingToPost;
    const z = try loadZone(app, a);
    const bounds = try z.dayBounds(date.year, date.month, date.day);
    const day_over = app.clock() >= bounds.end_ms;
    const task_open = try query.taskOpen(app.store, id);
    const posted = if (mode) &.{} else try query.postedOn(app.store, a, date.text, instance, b.ref);
    const fingerprint = try query.postedFingerprint(app.store, a, date.text, instance, b.ref);
    const request = try std.json.Stringify.valueAlloc(a, .{
        .day = date.text, .ref = b.ref, .day_over = day_over, .task_open = task_open,
        .total_focus_ms = if (mode) (if (body.dry_run) focusLength(remaining.pieces) else remaining.pieces[0].end_ms - remaining.pieces[0].start_ms) else focus_ms, .posted = posted,
    }, .{});
    return .{ .status = .ok, .body = "", .followup = .{ .quote = .{
        .day = date.text, .task = id, .ref = b.ref, .request = request,
        .fingerprint = fingerprint.text, .text = body.text, .day_over = day_over,
        .task_open = task_open, .total_focus_ms = if (mode) (if (body.dry_run) focusLength(remaining.pieces) else remaining.pieces[0].end_ms - remaining.pieces[0].start_ms) else focus_ms, .dry_run = body.dry_run,
        .title = (try query.task(app.store, a, id)).?.title,
        .settings = try providerValues(app, a), .options = options,
        .session = if (mode and !body.dry_run) remaining.pieces[0] else null,
        .all_sessions = if (mode) remaining.pieces else null,
        .chain = if (mode and !body.dry_run) blk: {
            const chain = try a.create(SessionChain);
            chain.* = .{ .day = date.text, .task = id, .ref = b.ref, .text = body.text,
                .title = (try query.task(app.store, a, id)).?.title, .day_over = day_over,
                .task_open = task_open, .settings = try providerValues(app, a),
                .options = options, .limit = remaining.pieces.len };
            break :blk chain;
        } else null,
    } } };
}

fn providerFailure(a: std.mem.Allocator, outcome: worker.Outcome, posting: ?query.Posting) Response {
    return switch (outcome) {
        .busy => send(a, .service_unavailable, .{ .@"error" = "ProviderBusy", .message = "an earlier provider call has not returned", .posting = posting }),
        .deadline => send(a, .gateway_timeout, .{ .@"error" = "ProviderTimeout", .message = "the provider did not answer in time", .posting = posting }),
        .done => |d| send(a, .bad_gateway, .{
            .@"error" = "ProviderFailed",
            .code = d.code,
            .message = d.message,
            .retry_safe = d.retry_safe,
            .outcome_known = d.outcome_known,
            .posting = posting,
        }),
    };
}

fn postingError(a: std.mem.Allocator, chain: ?*SessionChain, status: std.http.Status, code: []const u8, message: []const u8) !Response {
    if (chain) |c| return send(a, status, .{ .@"error" = code, .message = message, .posted = try postedIds(a, c) });
    return fail(a, .{ .status = status, .code = code, .message = message });
}

fn chainProviderFailure(a: std.mem.Allocator, outcome: worker.Outcome, posting: ?query.Posting, piece: ?sessions.Session, chain: *const SessionChain) !Response {
    const ids = try postedIds(a, chain);
    const shaped: ?std.json.Value = if (posting) |row| try sessionPosting(a, row, piece.?) else null;
    return switch (outcome) {
        .busy => send(a, .service_unavailable, .{ .@"error" = "ProviderBusy", .message = "an earlier provider call has not returned", .posting = shaped, .posted = ids }),
        .deadline => send(a, .gateway_timeout, .{ .@"error" = "ProviderTimeout", .message = "the provider did not answer in time", .posting = shaped, .posted = ids }),
        .done => |d| send(a, .bad_gateway, .{ .@"error" = "ProviderFailed", .code = d.code, .message = d.message, .retry_safe = d.retry_safe, .outcome_known = d.outcome_known, .posting = shaped, .posted = ids }),
    };
}

/// Continues a request after its provider call; `outcome` is what the call returned.
pub fn proceed(app: *App, a: std.mem.Allocator, f: Followup, outcome: worker.Outcome) Response {
    return proceedInner(app, a, f, outcome) catch |err| {
        const base = errorResponse(a, err);
        const chain: ?*SessionChain = switch (f) {
            .quote => |q| q.chain,
            .post => |p| p.chain,
            else => null,
        };
        const c = chain orelse return base;
        const shaped: ?std.json.Value = switch (f) {
            .post => |p| blk: {
                const row = query.posting(app.store, a, p.posting) catch null;
                break :blk if (row) |value| sessionPosting(a, value, p.session.?) catch null else null;
            },
            else => null,
        };
        return send(a, base.status, .{ .@"error" = @errorName(err), .posting = shaped, .posted = postedIds(a, c) catch &.{} });
    };
}

fn failureMessage(outcome: worker.Outcome) []const u8 {
    return switch (outcome) {
        .busy => "an earlier provider call has not returned",
        .deadline => "the provider did not answer in time",
        .done => |d| d.message,
    };
}

fn succeeded(outcome: worker.Outcome) bool {
    return outcome == .done and outcome.done.ok();
}

const Accepted = struct { text: ?[]const u8 = null, micro: ?i64 = null, data: ?[]const u8 = null };

fn acceptedOutput(a: std.mem.Allocator, out: []const u8) !Accepted {
    if (out.len == 0) return .{};
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, out, .{}) catch return error.ProviderOutput;
    if (value != .object) return error.ProviderOutput;
    var accepted: Accepted = .{};
    if (value.object.get("amount_text")) |v| {
        if (v != .string or v.string.len == 0) return error.ProviderOutput;
        accepted.text = v.string;
    }
    if (value.object.get("amount_micro")) |v| {
        if (v != .integer or v.integer < 0) return error.ProviderOutput;
        accepted.micro = v.integer;
    }
    if (value.object.get("data")) |v| accepted.data = try std.json.Stringify.valueAlloc(a, v, .{});
    return accepted;
}

fn proceedInner(app: *App, a: std.mem.Allocator, f: Followup, outcome: worker.Outcome) !Response {
    switch (f) {
        .login_prompts => {
            if (!succeeded(outcome)) return providerFailure(a, outcome, null);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, outcome.done.out, .{}) catch return error.ProviderOutput;
            return send(a, .ok, .{ .prompts = parsed });
        },
        .login => |answers| {
            @memset(answers, 0);
            if (!succeeded(outcome)) return providerFailure(a, outcome, null);
            return send(a, .ok, .{ .signed_in = true });
        },
        .fields => {
            if (!succeeded(outcome)) return providerFailure(a, outcome, null);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, outcome.done.out, .{}) catch return error.ProviderOutput;
            return send(a, .ok, .{ .instance = app.provider, .fields = parsed, .settings = app.traits.settings, .post_options = app.traits.post_options, .sessions = app.traits.sessions, .status = app.provider_status });
        },
        .lookup => |l| {
            if (!succeeded(outcome)) {
                const task = l.task orelse return providerFailure(a, outcome, null);
                // A bind keeps the ref even when the provider cannot confirm it
                // (unknown number, down, slow); the fields stay empty.
                try app.store.bind(task, app.provider.?, l.ref, app.clock());
                return send(a, .ok, .{ .task = (try query.task(app.store, a, task)).?, .fields = try query.fields(app.store, a, task), .lookup_error = failureMessage(outcome) });
            }
            const Found = struct { title: ?[]const u8 = null, fields: std.json.ArrayHashMap([]const u8) = .{} };
            const found = std.json.parseFromSliceLeaky(Found, a, outcome.done.out, .{ .ignore_unknown_fields = true }) catch return error.ProviderOutput;
            const task = l.task orelse return send(a, .ok, .{ .ref = l.ref, .title = found.title, .fields = found.fields });
            var values: std.ArrayList(Store.FieldValue) = .empty;
            var it = found.fields.map.iterator();
            while (it.next()) |e| try values.append(a, .{ .name = e.key_ptr.*, .value = e.value_ptr.* });
            try app.store.bindWithFields(task, app.provider.?, l.ref, values.items, app.clock());
            return send(a, .ok, .{ .task = (try query.task(app.store, a, task)).?, .remote_title = found.title, .fields = try query.fields(app.store, a, task) });
        },
        .quote => |r| {
            if (!succeeded(outcome)) return if (r.chain) |chain| try chainProviderFailure(a, outcome, null, null, chain) else providerFailure(a, outcome, null);
            const Quote = struct { post: bool, reason: []const u8, amount_text: []const u8, amount_micro: i64 };
            const quoted = std.json.parseFromSliceLeaky(Quote, a, outcome.done.out, .{ .ignore_unknown_fields = true }) catch return error.ProviderOutput;
            if (!quoted.post) return postingError(a, r.chain, .conflict, "PostingRefused", quoted.reason);
            if (quoted.amount_micro <= 0 or quoted.amount_text.len == 0) return error.NothingToPost;
            const instance = app.provider orelse return error.NoProvider;
            const binding = try query.binding(app.store, a, r.task) orelse return error.NotBound;
            if (!std.mem.eql(u8, binding.instance, instance) or !std.mem.eql(u8, binding.ref, r.ref))
                return postingError(a, r.chain, .conflict, "QuoteStale", "postings changed while quoting; try again");
            const fingerprint = try query.postedFingerprint(app.store, a, r.day, instance, r.ref);
            if (fingerprint.in_flight or !std.mem.eql(u8, fingerprint.text, r.fingerprint))
                return postingError(a, r.chain, .conflict, "QuoteStale", "postings changed while quoting; try again");
            // A dry run shows what a post would send and stops there.
            if (r.dry_run) {
                if (r.all_sessions) |all| return send(a, .ok, .{ .day = r.day, .task = r.task, .ref = r.ref, .amount_text = quoted.amount_text, .amount_micro = quoted.amount_micro, .sessions = all });
                return send(a, .ok, .{ .day = r.day, .task = r.task, .ref = r.ref, .amount_text = quoted.amount_text, .amount_micro = quoted.amount_micro });
            }
            if (r.session != null and try query.hasTotalPosting(app.store, r.day, instance, r.ref))
                return postingError(a, r.chain, .conflict, "PostedAsTotal", "this day was posted as a total; turn off posting by session to post the rest");
            if (try app.store.isBlocked(r.day, instance, r.ref)) {
                if (r.chain != null) return postingError(a, r.chain, .conflict, "PostingBlocked", "");
                return error.PostingBlocked;
            }
            const id = app.store.startPostingChecked(r.day, r.task, instance, r.ref, quoted.amount_text, quoted.amount_micro, app.clock(), if (r.session) |s| sessions.Span{ .start_ms = s.start_ms, .end_ms = s.end_ms } else null, r.fingerprint) catch |err| {
                if (err == error.PostingBlocked and r.chain != null) return postingError(a, r.chain, .conflict, "PostingBlocked", "");
                return err;
            };
            const common = .{
                .posting_id = id,
                .day = r.day,
                .ref = r.ref,
                .amount_text = quoted.amount_text,
                .amount_micro = quoted.amount_micro,
                .text = r.text,
                .day_over = r.day_over,
                .task_open = r.task_open,
                .total_focus_ms = r.total_focus_ms,
                .title = r.title,
                .settings = r.settings,
                .options = r.options,
            };
            const request = if (r.session) |piece| try std.json.Stringify.valueAlloc(a, .{
                .posting_id = common.posting_id, .day = common.day, .ref = common.ref,
                .amount_text = common.amount_text, .amount_micro = common.amount_micro,
                .text = common.text, .day_over = common.day_over, .task_open = common.task_open,
                .total_focus_ms = common.total_focus_ms, .title = common.title,
                .settings = common.settings, .options = common.options,
                .start = piece.start, .end = piece.end,
            }, .{}) else try std.json.Stringify.valueAlloc(a, common, .{});
            return .{ .status = .ok, .body = "", .followup = .{ .post = .{ .posting = id, .request = request, .session = r.session, .chain = r.chain } } };
        },
        .status => |job| {
            const item = &job.items[job.next];
            if (succeeded(outcome)) {
                const Quote = struct { post: bool, amount_micro: i64 = 0 };
                if (std.json.parseFromSliceLeaky(Quote, a, outcome.done.out, .{ .ignore_unknown_fields = true })) |q| {
                    item.left = q.post and q.amount_micro > 0;
                } else |_| item.failed = true;
            } else item.failed = true;
            if (job.advance(job.next + 1)) |next| {
                job.next = next;
                return .{ .status = .ok, .body = "", .followup = .{ .status = job } };
            }
            return finishStatus(a, job);
        },
        .post => |p| {
            const now = app.clock();
            switch (outcome) {
                .done => |d| if (d.ok()) {
                    const accepted = acceptedOutput(a, d.out) catch {
                        try app.store.markUnknown(p.posting, now);
                        return error.ProviderOutput;
                    };
                    try app.store.confirmPosting(p.posting, accepted.text, accepted.micro, accepted.data, now);
                    if (p.chain) |chain| {
                        try chain.confirmed.append(a, .{ .id = p.posting, .session = p.session.? });
                        if (try nextSessionQuote(app, a, chain)) |next| return next;
                        return chainSuccess(app, a, chain);
                    }
                    return send(a, .created, .{ .posting = (try query.posting(app.store, a, p.posting)).? });
                } else if (d.outcome_known) {
                    try app.store.postingFailed(p.posting, now);
                } else try app.store.markUnknown(p.posting, now),
                // The call was never made.
                .busy => try app.store.postingFailed(p.posting, now),
                .deadline => app.store.markUnknown(p.posting, now) catch |err| switch (err) {
                    // A late result settled it before this request got the lock.
                    error.InvalidState => {
                        const row = (try query.posting(app.store, a, p.posting)).?;
                        if (std.mem.eql(u8, row.state, "confirmed")) {
                            if (p.chain) |chain| {
                                try chain.confirmed.append(a, .{ .id = p.posting, .session = p.session.? });
                                if (try nextSessionQuote(app, a, chain)) |next| return next;
                                return chainSuccess(app, a, chain);
                            }
                            return send(a, .created, .{ .posting = row });
                        }
                        return if (p.chain) |chain| try chainProviderFailure(a, outcome, row, p.session, chain) else providerFailure(a, outcome, row);
                    },
                    else => return err,
                },
            }
            return if (p.chain) |chain| try chainProviderFailure(a, outcome, try query.posting(app.store, a, p.posting), p.session, chain) else providerFailure(a, outcome, try query.posting(app.store, a, p.posting));
        },
    }
}

/// Applies a post result that arrived after its request timed out.
pub fn lateResult(app: *App, a: std.mem.Allocator, posting: i64, done: worker.Done) ![]const u8 {
    const p = try query.posting(app.store, a, posting) orelse return try std.fmt.allocPrint(a, "late posting #{d} ignored", .{posting});
    // Still `sending` when the result beats the timed-out request to the lock.
    const sending = std.mem.eql(u8, p.state, "sending");
    if (!sending and !std.mem.eql(u8, p.state, "unknown")) return try std.fmt.allocPrint(a, "late posting #{d} ignored", .{posting});
    if (done.ok()) {
        const accepted = acceptedOutput(a, done.out) catch return try std.fmt.allocPrint(a, "late posting #{d} has invalid output", .{posting});
        try app.store.confirmPosting(posting, accepted.text, accepted.micro, accepted.data, app.clock());
        return try std.fmt.allocPrint(a, "late posting #{d} confirmed", .{posting});
    }
    if (done.outcome_known) {
        if (sending) try app.store.postingFailed(posting, app.clock()) else try app.store.resolveUnknown(posting, false, null, app.clock());
        return try std.fmt.allocPrint(a, "late posting #{d} cancelled", .{posting});
    }
    return try std.fmt.allocPrint(a, "late posting #{d} remains unknown", .{posting});
}

// ---------------------------------------------------------------- tests

const sqlite = @import("sqlite.zig");

var test_now: i64 = 0;
fn testClock() i64 {
    return test_now;
}

const Fixture = struct {
    db: sqlite.Db = .{},
    store: Store = undefined,
    app: App = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    post_outcome: ?worker.Outcome = null,
    stale_second_quote: bool = false,
    deadline_ms: i64 = 5_000,
    mutex: std.Io.Mutex = .init,

    fn init(f: *Fixture) !void {
        try f.db.open(":memory:");
        f.store = try Store.init(&f.db, std.testing.allocator);
        try f.store.setSetting("reporting_zone", "UTC", 0);
        f.app = .{ .store = &f.store, .port = 47100, .clock = testClock, .running_post = worker.runningPost };
        f.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        test_now = 1_773_100_000_000; // 2026-03-09T23:46:40Z
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.db.close();
    }

    fn late(context: *anyopaque, posting: i64, done: worker.Done) void {
        const f: *Fixture = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        f.mutex.lockUncancelable(std.testing.io);
        defer f.mutex.unlock(std.testing.io);
        _ = lateResult(&f.app, a, posting, done) catch unreachable;
    }

    /// Runs follow-up provider calls the way the daemon does, through the
    /// real worker and the fake provider. `post_outcome` replaces the post call.
    fn call(f: *Fixture, method: std.http.Method, target: []const u8, body: []const u8) Response {
        const a = f.arena.allocator();
        f.mutex.lockUncancelable(std.testing.io);
        var r = handle(&f.app, a, .{ .method = method, .target = target, .host = "127.0.0.1:47100", .marker = true, .body = body });
        f.mutex.unlock(std.testing.io);
        while (r.followup) |next| {
            const w: worker.Worker = .{ .table = &worker.Fake.table, .io = std.testing.io, .late = late, .late_context = f };
            const outcome = if (next == .post and f.post_outcome != null)
                f.post_outcome.?
            else
                w.run(a, next.call(), f.deadline_ms) catch unreachable;
            if (f.stale_second_quote and next == .quote and next.quote.chain != null and next.quote.chain.?.confirmed.items.len == 1) {
                f.stale_second_quote = false;
                const q = next.quote;
                const injected = f.store.startPosting(q.day, q.task, f.app.provider.?, q.ref, "0.25", 250_000, test_now, .{ .start_ms = q.session.?.end_ms + 3_600_000, .end_ms = q.session.?.end_ms + 3_660_000 }) catch unreachable;
                f.store.confirmPosting(injected, null, null, null, test_now) catch unreachable;
            }
            f.mutex.lockUncancelable(std.testing.io);
            r = proceed(&f.app, a, next, outcome);
            f.mutex.unlock(std.testing.io);
        }
        return r;
    }

    /// Moves the clock forward with a heartbeat each minute, as the daemon does.
    fn advance(f: *Fixture, ms: i64) !void {
        const end = test_now + ms;
        while (test_now < end) {
            test_now = @min(end, test_now + 60_000);
            try f.store.onHeartbeat(test_now);
        }
    }

    fn get(f: *Fixture, comptime T: type, target: []const u8) !T {
        const r = f.call(.GET, target, "");
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        return std.json.parseFromSliceLeaky(T, f.arena.allocator(), r.body, .{ .ignore_unknown_fields = true });
    }
};

test "requests need loopback host, marker and same origin" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .GET, .target = "/api/health", .host = null }).status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .GET, .target = "/api/health", .host = "evil.test:47100" }).status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .GET, .target = "/api/health", .host = "127.0.0.1:47101" }).status);
    try std.testing.expectEqual(std.http.Status.ok, handle(&f.app, a, .{ .method = .GET, .target = "/api/health", .host = "localhost:47100" }).status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .POST, .target = "/api/pause", .host = "127.0.0.1:47100" }).status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .POST, .target = "/api/pause", .host = "127.0.0.1:47100", .marker = true, .origin = "http://evil.test" }).status);
    try std.testing.expectEqual(std.http.Status.ok, handle(&f.app, a, .{ .method = .POST, .target = "/api/pause", .host = "127.0.0.1:47100", .marker = true, .origin = "http://127.0.0.1:47100" }).status);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, handle(&f.app, a, .{ .method = .PUT, .target = "/api/pause", .host = "127.0.0.1:47100", .marker = true }).status);
    // GET never changes anything: a mutation route under GET is not found.
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.GET, "/api/pause", "").status);
}

test "switch creates, resolves and runs parallel work with targeted notes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var r = f.call(.POST, "/api/switch", "{\"task\":\"Login page\"}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"created\":true") != null);
    try f.advance(60_000);
    r = f.call(.POST, "/api/parallel", "{\"task\":\"Build\"}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try f.advance(60_000);
    r = f.call(.POST, "/api/notes", "{\"text\":\"focus note\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    r = f.call(.POST, "/api/notes", "{\"task\":\"build\",\"text\":\"compiling\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    r = f.call(.POST, "/api/notes", "{\"task\":\"#99\",\"text\":\"x\"}");
    try std.testing.expectEqual(std.http.Status.not_found, r.status);
    r = f.call(.POST, "/api/switch", "{\"task\":\"login PAGE\"}");
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"created\":false") != null);

    const State = struct {
        focus: ?struct { task: query.Task, notes: []query.Note },
        parallel: []struct { task: query.Task, notes: []query.Note },
        numbers: Numbers,
    };
    const s = try f.get(State, "/api/state");
    try std.testing.expectEqualStrings("Login page", s.focus.?.task.title);
    try std.testing.expectEqual(@as(usize, 1), s.focus.?.notes.len);
    try std.testing.expectEqual(@as(usize, 1), s.parallel.len);
    try std.testing.expectEqualStrings("compiling", s.parallel[0].notes[0].text);
    try std.testing.expect(s.numbers.working);

    r = f.call(.POST, "/api/pause", "");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    r = f.call(.POST, "/api/notes", "{\"text\":\"lost\"}");
    try std.testing.expectEqual(std.http.Status.conflict, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "NoFocus") != null);
    try f.advance(60_000);
    r = f.call(.POST, "/api/resume", "");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    const after = try f.get(State, "/api/state");
    try std.testing.expectEqual(@as(usize, 1), after.parallel.len);
    try std.testing.expect(after.focus != null);
    r = f.call(.POST, "/api/stop", "{\"task\":\"Build\"}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
}

test "a task is deleted unless it is running" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Spare\"}");
    _ = f.call(.POST, "/api/switch", "{\"task\":\"Busy\"}");
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/tasks/2/delete", "").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/1/delete", "").status);
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.GET, "/api/tasks/1", "").status);
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.POST, "/api/tasks/1/delete", "").status);
}

test "ambiguous titles ask for an id" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Same\"}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"same\"}");
    const r = f.call(.POST, "/api/switch", "{\"task\":\"SAME\"}");
    try std.testing.expectEqual(std.http.Status.conflict, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "AmbiguousTask") != null);
    const ok = f.call(.POST, "/api/switch", "{\"task\":\"#2\"}");
    try std.testing.expectEqual(std.http.Status.ok, ok.status);
    const stop = f.call(.POST, "/api/stop", "{\"task\":\"same\"}");
    try std.testing.expectEqual(std.http.Status.conflict, stop.status);
    try std.testing.expect(std.mem.indexOf(u8, stop.body, "\"candidates\":[") != null);
}

test "day totals, timeline and summary" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    test_now = 1_773_136_800_000; // 2026-03-10T10:00Z
    _ = f.call(.POST, "/api/switch", "{\"task\":\"A\",\"text\":\"first\"}");
    try f.advance(3_600_000);
    _ = f.call(.POST, "/api/parallel", "{\"task\":\"B\"}");
    try f.advance(1_800_000);
    _ = f.call(.POST, "/api/switch", "{\"task\":\"B\"}");
    try f.advance(600_000);
    _ = f.call(.POST, "/api/switch", "{\"task\":\"A\"}");
    try f.advance(600_000);
    var r = f.call(.POST, "/api/summary", "{\"date\":\"2026-03-10\",\"text\":\"good day\"}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    const Day = struct {
        numbers: Numbers,
        tasks: []struct { task: query.Task, focus_ms: i64, hops: u32 },
        intervals: []struct { role: []const u8 },
        summary: ?[]const u8,
    };
    const d = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(i64, 3_600_000 + 1_800_000 + 600_000 + 600_000), d.numbers.total_ms);
    try std.testing.expectEqual(@as(u32, 1), d.numbers.hops);
    try std.testing.expectEqualStrings("A", d.tasks[0].task.title);
    try std.testing.expectEqual(@as(usize, 4), d.intervals.len);
    try std.testing.expectEqualStrings("parallel", d.intervals[1].role);
    try std.testing.expectEqualStrings("good day", d.summary.?);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.GET, "/api/day?date=2026-02-30", "").status);
    r = f.call(.POST, "/api/summary", "{\"date\":\"2026-03-10\",\"text\":\"\"}");
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"text\":null") != null);
}

test "settings accept known keys only and validate" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"daily_work_minutes\":\"480\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"nope\":\"1\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"daily_work_minutes\":\"0\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"http_port\":\"80\"}").status);
    try std.testing.expectEqual(@as(u16, 480), try f.store.dailyWorkMinutes());
}

test "settings change together or not at all" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"lunch_minutes\":\"45\"}").status);
    // One bad key keeps the others unchanged.
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"daily_work_minutes\":\"420\",\"lunch_minutes\":\"30\",\"http_port\":\"80\"}").status);
    try std.testing.expectEqual(@as(u16, 510), try f.store.dailyWorkMinutes());
    try std.testing.expectEqual(@as(u16, 45), try f.store.lunchMinutes());
}

fn contains(body: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, body, part) != null;
}

/// A fixture with the fake provider and 61 minutes of focus on task #1 today.
fn postingFixture(f: *Fixture) !void {
    try f.init();
    f.app.provider = "fake";
    test_now = 1_773_136_800_000; // 2026-03-10T10:00Z
    _ = f.call(.POST, "/api/switch", "{\"task\":\"Ticket\"}");
    try f.advance(61 * 60_000);
    _ = f.call(.POST, "/api/switch", "{\"task\":\"Other\"}");
}

fn sessionFixture(f: *Fixture) !i64 {
    try f.init();
    f.app.provider = "fake";
    f.app.traits = parseTraits(f.arena.allocator(), "{\"sessions\":true}");
    const bounds = try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10);
    test_now = bounds.end_ms + 12 * 3_600_000;
    const task_id = try f.store.createTask("Focus", test_now);
    try f.store.bind(task_id, "fake", "R-1", test_now);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"post_sessions\":\"1\"}").status);
    return task_id;
}

test "sessions chain posts exact coverage and only new sessions later" {
    var f: Fixture = .{};
    const task_id = try sessionFixture(&f);
    defer f.deinit();
    const start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    const h: i64 = 3_600_000;
    const m: i64 = 60_000;
    _ = try f.store.addInterval(task_id, .focus, start + 9*h, start + 10*h, test_now);
    _ = try f.store.addInterval(task_id, .focus, start + 10*h + 20*m, start + 11*h + 50*m, test_now);
    worker.Fake.post_calls = 0;
    worker.Fake.post_code = 0;
    const r = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    try std.testing.expect(contains(r.body, "\"postings\":["));
    try std.testing.expectEqual(@as(u32, 2), worker.Fake.post_calls);
    try std.testing.expect(contains(worker.Fake.requests[0][0..worker.Fake.request_lens[0]], "\"start\":\"09:00\",\"end\":\"10:00\""));
    try std.testing.expect(contains(worker.Fake.requests[1][0..worker.Fake.request_lens[1]], "\"start\":\"10:20\",\"end\":\"11:50\""));
    const rows = try query.postingsOn(&f.store, f.arena.allocator(), "2026-03-10", task_id);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(start + 9*h, rows[0].covered_start_ms.?);
    try std.testing.expectEqual(start + 11*h + 50*m, rows[1].covered_end_ms.?);
    _ = try f.store.addInterval(task_id, .focus, start + 12*h, start + 13*h, test_now);
    const second = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.created, second.status);
    try std.testing.expectEqual(@as(u32, 3), worker.Fake.post_calls);
    try std.testing.expect(contains(second.body, "\"start\":\"12:00\""));
}

test "second session quote becoming stale keeps earlier confirmed id" {
    var f: Fixture = .{};
    const task_id = try sessionFixture(&f);
    defer f.deinit();
    const day_start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    _ = try f.store.addInterval(task_id, .focus, day_start + 9 * 3_600_000, day_start + 10 * 3_600_000, test_now);
    _ = try f.store.addInterval(task_id, .focus, day_start + 11 * 3_600_000, day_start + 12 * 3_600_000, test_now);
    f.stale_second_quote = true;
    worker.Fake.post_code = 0;
    worker.Fake.post_calls = 0;
    const response = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.conflict, response.status);
    try std.testing.expect(contains(response.body, "\"error\":\"QuoteStale\""));
    try std.testing.expect(contains(response.body, "\"posted\":[1]"));
    try std.testing.expectEqual(@as(u32, 1), worker.Fake.post_calls);
    const first = (try query.posting(&f.store, f.arena.allocator(), 1)).?;
    try std.testing.expectEqualStrings("confirmed", first.state);
}

test "session chain stops after a known second-post failure" {
    var f: Fixture = .{};
    const task_id = try sessionFixture(&f);
    defer f.deinit();
    const day_start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    for ([_]i64{ 9, 10, 11 }) |hour| _ = try f.store.addInterval(task_id, .focus, day_start + hour * 3_600_000, day_start + hour * 3_600_000 + 30 * 60_000, test_now);
    worker.Fake.post_calls = 0;
    worker.Fake.fail_on_call = 2;
    worker.Fake.post_code = 55;
    worker.Fake.post_known = 1;
    defer { worker.Fake.fail_on_call = 0; worker.Fake.post_code = 0; }
    const r = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.bad_gateway, r.status);
    try std.testing.expect(contains(r.body, "\"posted\":[1]"));
    try std.testing.expect(contains(r.body, "\"start\":\"10:00\",\"end\":\"10:30\""));
    try std.testing.expectEqual(@as(u32, 2), worker.Fake.post_calls);
    const rows = try query.postingsOn(&f.store, f.arena.allocator(), "2026-03-10", task_id);
    try std.testing.expectEqualStrings("confirmed", rows[0].state);
    try std.testing.expectEqualStrings("cancelled", rows[1].state);
    const offered = f.call(.GET, "/api/postings?date=2026-03-10", "");
    try std.testing.expect(contains(offered.body, "\"start\":\"11:00\""));
    try std.testing.expect(contains(offered.body, "\"start\":\"10:00\""));
}

test "session chain unknown second post blocks further posting" {
    var f: Fixture = .{};
    const task_id = try sessionFixture(&f);
    defer f.deinit();
    const day_start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    for ([_]i64{ 9, 10, 11 }) |hour| _ = try f.store.addInterval(task_id, .focus, day_start + hour * 3_600_000, day_start + hour * 3_600_000 + 30 * 60_000, test_now);
    worker.Fake.post_calls = 0;
    worker.Fake.fail_on_call = 2;
    worker.Fake.post_code = 55;
    worker.Fake.post_known = 0;
    defer { worker.Fake.fail_on_call = 0; worker.Fake.post_code = 0; worker.Fake.post_known = 1; }
    const r = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.bad_gateway, r.status);
    try std.testing.expect(contains(r.body, "\"posted\":[1]"));
    try std.testing.expect(contains(r.body, "\"start\":\"10:00\",\"end\":\"10:30\""));
    const rows = try query.postingsOn(&f.store, f.arena.allocator(), "2026-03-10", task_id);
    try std.testing.expectEqualStrings("unknown", rows[1].state);
    try std.testing.expect(try f.store.isBlocked("2026-03-10", "fake", "R-1"));
}

test "session edits offer only extra coverage and suppress equal rounded endpoints" {
    var f: Fixture = .{};
    const task_id = try sessionFixture(&f);
    defer f.deinit();
    const day_start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    const h: i64 = 3_600_000;
    const original = try f.store.addInterval(task_id, .focus, day_start + 9*h, day_start + 10*h, test_now);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}").status);
    try f.store.editInterval(original, .{ .start_ms = day_start + 9*h, .end_ms = day_start + 10*h }, day_start + 9*h, day_start + 10*h + 30*60_000, test_now);
    var offered = f.call(.GET, "/api/postings?date=2026-03-10", "");
    try std.testing.expect(contains(offered.body, "\"start\":\"10:00\",\"end\":\"10:30\""));
    _ = try f.store.addInterval(task_id, .focus, day_start + 11*h + 10_000, day_start + 11*h + 25_000, test_now);
    _ = try f.store.addInterval(task_id, .focus, day_start + 12*h + 29_000, day_start + 12*h + 31_000, test_now);
    offered = f.call(.GET, "/api/postings?date=2026-03-10", "");
    try std.testing.expect(!contains(offered.body, "\"start\":\"11:00\""));
    try std.testing.expect(contains(offered.body, "\"start\":\"12:00\",\"end\":\"12:01\""));
}

test "running session waits and a total posting prevents session mode" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.app.provider = "fake";
    f.app.traits = parseTraits(f.arena.allocator(), "{\"sessions\":true}");
    const day_start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    test_now = day_start + 10*3_600_000;
    const task_id = try f.store.createTask("Focus", test_now);
    try f.store.bind(task_id, "fake", "R-1", test_now);
    _ = try f.store.switchTo(task_id, null, test_now);
    try f.advance(5*60_000);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"post_sessions\":\"1\"}").status);
    const open = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.conflict, open.status);
    try std.testing.expect(contains(open.body, "SessionOpen"));
    try std.testing.expect(contains(f.call(.GET, "/api/postings?date=2026-03-10", "").body, "\"open_session\":true"));
    _ = f.call(.POST, "/api/pause", "");
    _ = f.call(.PATCH, "/api/settings", "{\"post_sessions\":\"0\"}");
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}").status);
    _ = f.call(.PATCH, "/api/settings", "{\"post_sessions\":\"1\"}");
    const total = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.conflict, total.status);
    try std.testing.expect(contains(total.body, "PostedAsTotal"));
}

test "provider settings and post options reach the post request" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    f.app.traits = parseTraits(f.arena.allocator(),
        \\{"settings":[{"name":"mode","label":"Mode","type":"choice","choices":[{"value":"a","label":"A"},{"value":"b","label":"B"}]},
        \\ {"name":"note","label":"Note","type":"text","default":"x"},
        \\ {"name":"Bad Name","label":"No","type":"text"},{"name":"odd","label":"Odd","type":"choice"}],
        \\ "post_options":[{"name":"internal","label":"Internal","type":"bool"},{"name":"text_opt","label":"T","type":"text"}]}
    );
    try std.testing.expectEqual(@as(usize, 2), f.app.traits.settings.len);
    try std.testing.expectEqualStrings("a", f.app.traits.settings[0].default);
    try std.testing.expectEqual(@as(usize, 1), f.app.traits.post_options.len);
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"post_options\":[{\"name\":\"internal\""));

    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"provider.mode\":\"b\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"provider.mode\":\"c\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"provider.other\":\"b\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"provider.note\":\"two\nlines\"}").status);

    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/postings", "{\"task\":\"T-1\",\"options\":{\"nope\":true}}").status);
    const r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\",\"options\":{\"internal\":true}}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    const sent = worker.Fake.last_post[0..worker.Fake.last_post_len];
    try std.testing.expect(contains(sent, "\"title\":\"Ticket\""));
    try std.testing.expect(contains(sent, "\"settings\":{\"mode\":\"b\",\"note\":\"x\"}"));
    try std.testing.expect(contains(sent, "\"options\":{\"internal\":true}"));
}

test "posting needs a binding and can post a later difference" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    var r = f.call(.GET, "/api/postings", "");
    try std.testing.expect(contains(r.body, "\"postable\":false"));
    r = f.call(.POST, "/api/postings", "{\"task\":\"Ticket\"}");
    try std.testing.expectEqual(std.http.Status.conflict, r.status);
    try std.testing.expect(contains(r.body, "NotBound"));

    r = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expect(contains(r.body, "\"value\":\"Example\""));
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/tasks/2/bind", "{\"ref\":\"T-1\"}").status);
    // A ref the provider does not know is still bound, with the reason.
    try std.testing.expect(contains(f.call(.POST, "/api/tasks", "{\"title\":\"Unknown\"}").body, "\"id\":3"));
    r = f.call(.POST, "/api/tasks/3/bind", "{\"ref\":\"missing\"}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expect(contains(r.body, "\"lookup_error\":\"no such ticket\""));
    try std.testing.expect(contains(r.body, "\"ref\":\"missing\""));
    try std.testing.expectEqual(std.http.Status.bad_gateway, f.call(.GET, "/api/lookup?ref=missing", "").status);
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"label\":\"Client\""));

    const before = worker.Fake.posted.load(.acquire);
    r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\",\"date\":\"2026-03-10\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    try std.testing.expect(contains(r.body, "\"state\":\"confirmed\""));
    try std.testing.expect(contains(r.body, "\"amount_text\":\"1.25\""));
    try std.testing.expect(contains(r.body, "\"amount_micro\":1250000"));
    try std.testing.expectEqual(before + 1, worker.Fake.posted.load(.acquire));
    r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\"}");
    try std.testing.expectEqual(std.http.Status.conflict, r.status);
    try std.testing.expect(contains(r.body, "NothingToPost"));
    try std.testing.expectEqual(before + 1, worker.Fake.posted.load(.acquire));
    _ = f.call(.POST, "/api/switch", "{\"task\":\"Ticket\"}");
    try f.advance(30 * 60_000);
    _ = f.call(.POST, "/api/switch", "{\"task\":\"Other\"}");
    r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    try std.testing.expect(contains(r.body, "\"amount_text\":\"0.50\""));
    try std.testing.expect(contains(r.body, "\"amount_micro\":500000"));
    try std.testing.expectEqual(@as(i64, 2), blk: {
        var stmt = try f.db.prepare("SELECT count(*) FROM postings WHERE state='confirmed' AND external_ref='T-1'");
        defer stmt.finalize();
        _ = try stmt.step();
        break :blk stmt.columnI64(0);
    });
    r = f.call(.POST, "/api/postings", "{\"task\":\"Other\"}");
    try std.testing.expect(contains(r.body, "NotBound"));
}

test "a dry run quotes without posting" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    const before = worker.Fake.posted.load(.acquire);
    const r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\",\"date\":\"2026-03-10\",\"dry_run\":true}");
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expect(contains(r.body, "\"amount_text\":\"1.25\""));
    try std.testing.expectEqual(before, worker.Fake.posted.load(.acquire));
    try std.testing.expect(!contains(f.call(.GET, "/api/postings?date=2026-03-10", "").body, "\"state\""));
}

test "provider policy can refuse a quote" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    worker.Fake.fake_policy_past_only = true;
    defer worker.Fake.fake_policy_past_only = false;
    const r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\"}");
    try std.testing.expectEqual(std.http.Status.conflict, r.status);
    try std.testing.expect(contains(r.body, "PostingRefused"));
    try std.testing.expect(contains(r.body, "day not over"));
}

test "a changed ledger makes an earlier quote stale" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    const a = f.arena.allocator();
    const started = handle(&f.app, a, .{ .method = .POST, .target = "/api/postings", .host = "127.0.0.1:47100", .marker = true, .body = "{\"task\":\"#1\"}" });
    const quote_call = started.followup.?;
    const w: worker.Worker = .{ .table = &worker.Fake.table, .io = std.testing.io };
    const outcome = try w.run(a, quote_call.call(), 5_000);
    const id = try f.store.startPosting("2026-03-10", 1, "fake", "T-1", "0.25", 250_000, test_now, null);
    try f.store.confirmPosting(id, null, null, null, test_now);
    const r = proceed(&f.app, a, quote_call, outcome);
    try std.testing.expectEqual(std.http.Status.conflict, r.status);
    try std.testing.expect(contains(r.body, "QuoteStale"));
}

test "post accepts the provider's adjusted amount and data" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    worker.Fake.post_output = "{\"amount_text\":\"1.20\",\"amount_micro\":1200000,\"data\":{\"receipt\":7}}";
    defer worker.Fake.post_output = null;
    const r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    try std.testing.expect(contains(r.body, "\"amount_text\":\"1.20\""));
    try std.testing.expect(contains(r.body, "\"amount_micro\":1200000"));
    try std.testing.expect(contains(r.body, "\\\"receipt\\\":7"));
    try std.testing.expectEqual(@as(i64, 1), worker.Fake.seen_posting.load(.acquire));
}

test "rebinding starts a new posted history for the new ref" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/postings", "{\"task\":\"#1\"}").status);
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-2\"}");
    const r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
    try std.testing.expect(contains(r.body, "\"amount_text\":\"1.25\""));
    try std.testing.expect(contains(r.body, "\"external_ref\":\"T-2\""));
    const old = (try query.posting(&f.store, f.arena.allocator(), 1)).?;
    try std.testing.expectEqualStrings("T-1", old.external_ref);
}

test "a failed post with a known outcome is cancelled and can be retried" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    worker.Fake.post_code = 400;
    worker.Fake.post_known = 1;
    var r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    worker.Fake.post_code = 0;
    try std.testing.expectEqual(std.http.Status.bad_gateway, r.status);
    try std.testing.expect(contains(r.body, "\"state\":\"cancelled\""));
    r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.created, r.status);
}

test "an unknown outcome or a timeout blocks the day until resolved" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    worker.Fake.post_code = 500;
    worker.Fake.post_known = 0;
    var r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    worker.Fake.post_code = 0;
    worker.Fake.post_known = 1;
    try std.testing.expectEqual(std.http.Status.bad_gateway, r.status);
    try std.testing.expect(contains(r.body, "\"state\":\"unknown\""));
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/postings", "{\"task\":\"#1\"}").status);
    r = f.call(.POST, "/api/postings/1/resolve", "{\"posted\":false}");
    try std.testing.expect(contains(r.body, "\"state\":\"cancelled\""));

    f.post_outcome = .deadline;
    r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    f.post_outcome = null;
    try std.testing.expectEqual(std.http.Status.gateway_timeout, r.status);
    try std.testing.expect(contains(r.body, "\"state\":\"unknown\""));
    r = f.call(.POST, "/api/postings/2/resolve", "{\"posted\":true}");
    try std.testing.expect(contains(r.body, "\"state\":\"confirmed\""));
    try std.testing.expect(contains(f.call(.POST, "/api/postings", "{\"task\":\"#1\"}").body, "NothingToPost"));
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.POST, "/api/postings/9/resolve", "{\"posted\":true}").status);
}

test "late post completion confirms unknown and cannot be resolved while running" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"slow\"}");
    f.deadline_ms = 50;
    worker.Fake.release.store(false, .release);
    defer worker.Fake.release.store(true, .release);
    const r = f.call(.POST, "/api/postings", "{\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.gateway_timeout, r.status);
    try std.testing.expect(contains(r.body, "\"state\":\"unknown\""));
    try std.testing.expectEqual(@as(?i64, 1), worker.runningPost());
    const resolving = f.call(.POST, "/api/postings/1/resolve", "{\"posted\":false}");
    try std.testing.expectEqual(std.http.Status.conflict, resolving.status);
    try std.testing.expect(contains(resolving.body, "PostingInFlight"));
    worker.Fake.release.store(true, .release);
    while (worker.runningPost() != null) std.Thread.yield() catch {};
    const p = (try query.posting(&f.store, f.arena.allocator(), 1)).?;
    try std.testing.expectEqualStrings("confirmed", p.state);
    const after = f.call(.POST, "/api/postings/1/resolve", "{\"posted\":false}");
    try std.testing.expectEqual(std.http.Status.conflict, after.status);
    try std.testing.expect(contains(after.body, "InvalidState"));
}

test "without a provider posting and binding are refused" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"instance\":null"));
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}").status);
    try std.testing.expect(contains(f.call(.POST, "/api/postings", "{\"task\":\"#1\"}").body, "NoProvider"));
}

test "provider status is included with and without a provider" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"status\":{\"state\":\"none\""));
    f.app.provider = "fake";
    f.app.provider_status = .{ .state = .loaded, .name = "Fake", .build = "test" };
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"status\":{\"state\":\"loaded\""));
}

test "history creates and edits intervals with range and stale checks" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const start: i64 = 1_773_129_600_000; // 2026-03-10T08:00Z
    test_now = start + 4 * 3_600_000;
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    const added = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 3_600_000 }));
    try std.testing.expectEqual(std.http.Status.created, added.status);
    const id = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, added.body, .{})).interval;
    const overlap = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start + 1_800_000, start + 5_400_000 }));
    try std.testing.expectEqual(std.http.Status.conflict, overlap.status);
    try std.testing.expect(contains(overlap.body, "Overlap"));
    const invalid = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start + 7_200_000, start + 7_200_000 }));
    try std.testing.expectEqual(std.http.Status.bad_request, invalid.status);
    try std.testing.expect(contains(invalid.body, "InvalidRange"));
    const edit = try std.fmt.allocPrint(a, "{{\"seen\":{{\"start_ms\":{d},\"end_ms\":{d}}},\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 3_600_000, start, start + 2_700_000 });
    const target = try std.fmt.allocPrint(a, "/api/intervals/{d}", .{id});
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, target, edit).status);
    const stale = f.call(.PATCH, target, edit);
    try std.testing.expectEqual(std.http.Status.conflict, stale.status);
    try std.testing.expect(contains(stale.body, "Stale"));
    const viewed = try f.get(struct { numbers: Numbers, intervals: []struct { end_ms: ?i64 } }, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(i64, 2_700_000), viewed.numbers.total_ms);
    try std.testing.expectEqual(@as(?i64, start + 2_700_000), viewed.intervals[0].end_ms);
    const opened = f.call(.POST, "/api/switch", "{\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.ok, opened.status);
    const open_id = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, opened.body, .{ .ignore_unknown_fields = true })).interval;
    const open_edit = f.call(.PATCH, try std.fmt.allocPrint(a, "/api/intervals/{d}", .{open_id}), try std.fmt.allocPrint(a, "{{\"seen\":{{\"start_ms\":{d},\"end_ms\":null}},\"start_ms\":{d},\"end_ms\":null}}", .{ test_now, test_now - 60_000 }));
    try std.testing.expectEqual(std.http.Status.ok, open_edit.status);
    const open_state = try f.get(struct { focus: ?struct { start_ms: i64, end_ms: ?i64 } }, "/api/state");
    try std.testing.expectEqual(test_now - 60_000, open_state.focus.?.start_ms);
    try std.testing.expectEqual(@as(?i64, null), open_state.focus.?.end_ms);
}

test "history merges and deletes closed intervals" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const start: i64 = 1_773_129_600_000;
    test_now = start + 4 * 3_600_000;
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    const first_response = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 1_800_000 }));
    const second_response = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start + 3_600_000, start + 5_400_000 }));
    try std.testing.expectEqual(std.http.Status.created, first_response.status);
    try std.testing.expectEqual(std.http.Status.created, second_response.status);
    const first = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, first_response.body, .{})).interval;
    const second = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, second_response.body, .{})).interval;
    const merged = f.call(.POST, "/api/intervals/merge", try std.fmt.allocPrint(a, "{{\"first\":{{\"id\":{d},\"start_ms\":{d},\"end_ms\":{d}}},\"second\":{{\"id\":{d},\"start_ms\":{d},\"end_ms\":{d}}}}}", .{ first, start, start + 1_800_000, second, start + 3_600_000, start + 5_400_000 }));
    try std.testing.expectEqual(std.http.Status.ok, merged.status);
    try std.testing.expect(contains(merged.body, try std.fmt.allocPrint(a, "\"interval\":{d}", .{first})));
    const Day = struct { numbers: Numbers, intervals: []struct { id: i64 } };
    const joined = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(i64, 5_400_000), joined.numbers.total_ms);
    try std.testing.expectEqual(@as(usize, 1), joined.intervals.len);
    try std.testing.expectEqual(first, joined.intervals[0].id);
    const deleted = f.call(.POST, try std.fmt.allocPrint(a, "/api/intervals/{d}/delete", .{first}), try std.fmt.allocPrint(a, "{{\"seen\":{{\"start_ms\":{d},\"end_ms\":{d}}}}}", .{ start, start + 5_400_000 }));
    try std.testing.expectEqual(std.http.Status.ok, deleted.status);
    const empty = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(i64, 0), empty.numbers.total_ms);
    try std.testing.expectEqual(@as(usize, 0), empty.intervals.len);
}

test "timed notes can be added moved edited and deleted" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const start: i64 = 1_773_129_600_000;
    test_now = start + 3_600_000;
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    const interval = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, test_now }));
    try std.testing.expectEqual(std.http.Status.created, interval.status);
    const id = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, interval.body, .{})).interval;
    const added = f.call(.POST, "/api/notes", try std.fmt.allocPrint(a, "{{\"interval\":{d},\"at_ms\":{d},\"text\":\"first\"}}", .{ id, start + 900_000 }));
    try std.testing.expectEqual(std.http.Status.created, added.status);
    const note = (try std.json.parseFromSliceLeaky(struct { note: i64 }, a, added.body, .{})).note;
    const target = try std.fmt.allocPrint(a, "/api/notes/{d}", .{note});
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, target, try std.fmt.allocPrint(a, "{{\"text\":\"second\",\"at_ms\":{d}}}", .{start + 1_200_000})).status);
    const Day = struct { intervals: []struct { notes: []query.Note } };
    const viewed = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(usize, 1), viewed.intervals[0].notes.len);
    try std.testing.expectEqualStrings("second", viewed.intervals[0].notes[0].text);
    try std.testing.expectEqual(start + 1_200_000, viewed.intervals[0].notes[0].at_ms);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, target, "{\"text\":\"third\"}").status);
    const text_only = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqualStrings("third", text_only.intervals[0].notes[0].text);
    try std.testing.expectEqual(start + 1_200_000, text_only.intervals[0].notes[0].at_ms);
    const outside = f.call(.POST, "/api/notes", try std.fmt.allocPrint(a, "{{\"interval\":{d},\"at_ms\":{d},\"text\":\"outside\"}}", .{ id, start - 1 }));
    try std.testing.expectEqual(std.http.Status.conflict, outside.status);
    try std.testing.expect(contains(outside.body, "NoteOutside"));
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, try std.fmt.allocPrint(a, "/api/notes/{d}/delete", .{note}), "").status);
    const after = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(usize, 0), after.intervals[0].notes.len);
}

test "the provider login runs through the API" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    const prompts = f.call(.GET, "/api/provider/login", "");
    try std.testing.expectEqual(std.http.Status.ok, prompts.status);
    try std.testing.expect(contains(prompts.body, "\"name\":\"token\""));
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/provider/login", "{\"token\":\"abc\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/provider/login", "{}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/provider/login", "[1]").status);
}

test "the day's lunch is the longest pause in the lunch window" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    test_now = 1_773_136_800_000; // 2026-03-10T10:00Z; the window is 11:30-13:30
    _ = f.call(.POST, "/api/switch", "{\"task\":\"A\"}");
    try f.advance(30 * 60_000);
    _ = f.call(.POST, "/api/pause", ""); // 10:30-10:50, outside the window
    try f.advance(20 * 60_000);
    _ = f.call(.POST, "/api/resume", "");
    try f.advance(70 * 60_000);
    _ = f.call(.POST, "/api/pause", ""); // 12:00-12:05 is too short
    try f.advance(5 * 60_000);
    _ = f.call(.POST, "/api/resume", "");
    try f.advance(5 * 60_000);
    const out = test_now; // 12:10
    _ = f.call(.POST, "/api/pause", "");
    try f.advance(50 * 60_000);
    const back = test_now; // 13:00
    _ = f.call(.POST, "/api/resume", "");
    try f.advance(30 * 60_000);
    const Day = struct { lunch_out_ms: ?i64, lunch_back_ms: ?i64 };
    const lunch_day = try f.get(Day, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(?i64, out), lunch_day.lunch_out_ms);
    try std.testing.expectEqual(@as(?i64, back), lunch_day.lunch_back_ms);
}

test "lookup stays unbound while provider fields appear in state and search" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    f.app.provider = "fake";
    f.app.traits = parseTraits(a, "{\"link\":\"https://example.invalid/{ref}\"}");
    test_now = 1_773_136_800_000; // 2026-03-10T10:00Z
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/switch", "{\"task\":\"A\"}").status);
    try f.advance(3_600_000);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/notes", "{\"text\":\"needle in note\"}").status);
    const looked = f.call(.GET, "/api/lookup?ref=T-9", "");
    try std.testing.expectEqual(std.http.Status.ok, looked.status);
    try std.testing.expect(contains(looked.body, "\"ref\":\"T-9\""));
    try std.testing.expect(contains(looked.body, "\"title\":\"Remote title\""));
    try std.testing.expect(contains(looked.body, "\"client\":\"Example\""));
    const before = try f.get(struct { task: query.Task }, "/api/tasks/1");
    try std.testing.expectEqual(@as(?[]const u8, null), before.task.ref);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-9\"}").status);
    const state_view = try f.get(struct { link: ?[]const u8, focus_fields: []query.Field }, "/api/state");
    try std.testing.expectEqualStrings("https://example.invalid/{ref}", state_view.link.?);
    try std.testing.expectEqual(@as(usize, 1), state_view.focus_fields.len);
    try std.testing.expectEqualStrings("client", state_view.focus_fields[0].name);
    try std.testing.expectEqualStrings("Example", state_view.focus_fields[0].value);

    const Search = struct { results: []struct { task: query.Task, fields: []query.Field, snippet: ?[]const u8, total_ms: i64, day_count: usize, last_date: ?[]const u8, days: []struct { date: []const u8, total_ms: i64 } } };
    const by_note = try f.get(Search, "/api/search?q=needle");
    try std.testing.expectEqual(@as(usize, 1), by_note.results.len);
    try std.testing.expectEqualStrings("needle in note", by_note.results[0].snippet.?);
    try std.testing.expectEqual(@as(i64, 3_600_000), by_note.results[0].total_ms);
    try std.testing.expectEqual(@as(usize, 1), by_note.results[0].day_count);
    try std.testing.expectEqualStrings("2026-03-10", by_note.results[0].last_date.?);
    try std.testing.expectEqualStrings("2026-03-10", by_note.results[0].days[0].date);
    try std.testing.expectEqual(@as(i64, 3_600_000), by_note.results[0].days[0].total_ms);
    const by_field = try f.get(Search, "/api/search?q=Example");
    try std.testing.expectEqual(@as(usize, 1), by_field.results.len);
    try std.testing.expectEqual(@as(?[]const u8, null), by_field.results[0].snippet);
    try std.testing.expectEqualStrings("Example", by_field.results[0].fields[0].value);
}

test "day totals frequent tasks and charts count focus only" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    f.app.provider = "fake";
    const today: i64 = 1_773_129_600_000; // 2026-03-10T08:00Z
    const yesterday = today - 86_400_000;
    test_now = today + 7_200_000;
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"B\"}");
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/2/bind", "{\"ref\":\"T-2\"}").status);
    const a_focus = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ yesterday, yesterday + 3_600_000 }));
    const b_focus = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#2\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ today, today + 1_800_000 }));
    const b_parallel = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#2\",\"role\":\"parallel\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ yesterday, yesterday + 3_600_000 }));
    try std.testing.expectEqual(std.http.Status.created, a_focus.status);
    try std.testing.expectEqual(std.http.Status.created, b_focus.status);
    try std.testing.expectEqual(std.http.Status.created, b_parallel.status);
    const totals = f.call(.GET, "/api/daytotals?from=2026-03-09&to=2026-03-10", "");
    try std.testing.expectEqual(std.http.Status.ok, totals.status);
    try std.testing.expect(contains(totals.body, "\"2026-03-09\":3600000"));
    try std.testing.expect(contains(totals.body, "\"2026-03-10\":1800000"));
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.GET, "/api/daytotals?from=2026-01-01&to=2026-03-10", "").status);
    const frequent = try f.get(struct { tasks: []struct { task: query.Task, fields: []query.Field, focus_ms: i64 } }, "/api/frequent?days=30&limit=8");
    try std.testing.expectEqual(@as(usize, 2), frequent.tasks.len);
    try std.testing.expectEqualStrings("A", frequent.tasks[0].task.title);
    try std.testing.expectEqual(@as(i64, 3_600_000), frequent.tasks[0].focus_ms);
    try std.testing.expectEqual(@as(i64, 1_800_000), frequent.tasks[1].focus_ms);
    const Chart = struct { dates: [][]const u8, series: []struct { label: []const u8, total_ms: i64, ms: []i64 } };
    const by_task = try f.get(Chart, "/api/chart?days=7&group=task");
    try std.testing.expectEqual(@as(usize, 7), by_task.dates.len);
    try std.testing.expectEqualStrings("2026-03-09", by_task.dates[5]);
    try std.testing.expectEqualStrings("2026-03-10", by_task.dates[6]);
    try std.testing.expectEqual(@as(usize, 2), by_task.series.len);
    try std.testing.expectEqual(@as(i64, 3_600_000), by_task.series[0].ms[5]);
    try std.testing.expectEqual(@as(i64, 1_800_000), by_task.series[1].ms[6]);
    const by_client = try f.get(Chart, "/api/chart?days=7&group=client");
    try std.testing.expectEqual(@as(usize, 1), by_client.series.len);
    try std.testing.expectEqualStrings("Example", by_client.series[0].label);
    try std.testing.expectEqual(@as(i64, 5_400_000), by_client.series[0].total_ms);
    try std.testing.expectEqual(@as(i64, 3_600_000), by_client.series[0].ms[5]);
    try std.testing.expectEqual(@as(i64, 1_800_000), by_client.series[0].ms[6]);
    const posted = f.call(.POST, "/api/postings", "{\"task\":\"#2\",\"date\":\"2026-03-10\"}");
    try std.testing.expectEqual(std.http.Status.created, posted.status);
    try std.testing.expect(contains(posted.body, "\"amount_micro\":500000"));
}

test "day status follows binding posting and reduced history" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const start: i64 = 1_773_043_200_000; // 2026-03-09T08:00Z
    test_now = 1_773_136_800_000; // 2026-03-10T10:00Z
    f.app.provider = "fake";
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    const added = f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 3_660_000 }));
    try std.testing.expectEqual(std.http.Status.created, added.status);
    const id = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, added.body, .{})).interval;
    const Days = struct { days: []struct { date: []const u8, status: []const u8, total_ms: i64, changed_after_posting: bool } };
    const unbound = try f.get(Days, "/api/days?count=3");
    try std.testing.expectEqual(@as(usize, 3), unbound.days.len);
    try std.testing.expectEqualStrings("2026-03-09", unbound.days[1].date);
    try std.testing.expectEqualStrings("none", unbound.days[1].status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}").status);
    const bound = try f.get(Days, "/api/days?count=3");
    try std.testing.expectEqualStrings("unposted", bound.days[1].status);
    const posted = f.call(.POST, "/api/postings", "{\"task\":\"#1\",\"date\":\"2026-03-09\"}");
    try std.testing.expectEqual(std.http.Status.created, posted.status);
    const confirmed = try f.get(Days, "/api/days?count=3");
    try std.testing.expectEqualStrings("posted", confirmed.days[1].status);
    test_now += 60_000;
    const edit = f.call(.PATCH, try std.fmt.allocPrint(a, "/api/intervals/{d}", .{id}), try std.fmt.allocPrint(a, "{{\"seen\":{{\"start_ms\":{d},\"end_ms\":{d}}},\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 3_660_000, start, start + 1_800_000 }));
    try std.testing.expectEqual(std.http.Status.ok, edit.status);
    const changed = try f.get(Days, "/api/days?count=3");
    try std.testing.expectEqualStrings("changed", changed.days[1].status);
    try std.testing.expect(changed.days[1].changed_after_posting);
    try std.testing.expectEqual(@as(i64, 1_800_000), changed.days[1].total_ms);
}

test "day status keeps unknown posting while quoting other days" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const march8: i64 = 1_772_956_800_000; // 2026-03-08T08:00Z
    const march9 = march8 + 86_400_000;
    test_now = 1_773_136_800_000;
    f.app.provider = "fake";
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ march8, march8 + 900_000 })).status);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ march9, march9 + 3_600_000 })).status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}").status);
    worker.Fake.post_code = 500;
    worker.Fake.post_known = 0;
    const posting = f.call(.POST, "/api/postings", "{\"task\":\"#1\",\"date\":\"2026-03-09\"}");
    worker.Fake.post_code = 0;
    worker.Fake.post_known = 1;
    try std.testing.expectEqual(std.http.Status.bad_gateway, posting.status);
    try std.testing.expect(contains(posting.body, "\"state\":\"unknown\""));
    const listed = try f.get(struct { days: []struct { date: []const u8, status: []const u8 } }, "/api/days?count=3");
    try std.testing.expectEqualStrings("2026-03-08", listed.days[0].date);
    try std.testing.expectEqualStrings("unposted", listed.days[0].status);
    try std.testing.expectEqualStrings("2026-03-09", listed.days[1].date);
    try std.testing.expectEqualStrings("unknown", listed.days[1].status);
}

test "settings validate preferences and paid breaks credit only the pause" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"ui_day_order\":\"newest\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"ui_day_order\":\"x\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"ui_chart_hidden\":\"[\\\"system\\\"]\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"ui_chart_hidden\":\"system\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"paid_breaks\":\"08:00-12:00=15,13:00-18:00=15\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"paid_breaks\":\"bad\"}").status);
    const start: i64 = 1_773_129_600_000; // 2026-03-10T08:00Z
    test_now = start + 7_200_000;
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"A\"}");
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 3_600_000 })).status);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"role\":\"focus\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start + 4_200_000, start + 7_200_000 })).status);
    const credited = try f.get(struct { numbers: Numbers }, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(i64, 6_600_000), credited.numbers.total_ms);
    try std.testing.expectEqual(@as(i64, 600_000), credited.numbers.paid_break_ms);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"paid_breaks\":\"\"}").status);
    const none = try f.get(struct { numbers: Numbers }, "/api/day?date=2026-03-10");
    try std.testing.expectEqual(@as(i64, 0), none.numbers.paid_break_ms);
    const settings = f.call(.GET, "/api/settings", "");
    try std.testing.expect(contains(settings.body, "\"key\":\"ui_day_order\",\"value\":\"newest\""));
    try std.testing.expect(contains(settings.body, "\"key\":\"paid_breaks\",\"value\":\"\""));
}
