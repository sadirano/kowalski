//! HTTP API as a pure function: request in, response out. The daemon owns the
//! sockets and serializes calls; tests drive `handle` directly.
//!
//! A request that needs the provider answers with a `followup` instead: the
//! caller runs that provider call without the database lock, then passes the
//! outcome to `proceed`, which may ask for another call.
const std = @import("std");
const settings_decl = @import("settings.zig");
const store_mod = @import("store.zig");
const days = @import("days.zig");
const zone = @import("zone.zig");
const query = @import("query.zig");
const worker = @import("worker.zig");
const sessions = @import("sessions.zig");
/// Tells the dashboard which daemon answers, so it can see a restart finish.
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
const Store = store_mod.Store;

pub const default_port: u16 = 47100;


pub const App = struct {
    store: *Store,
    port: u16,
    clock: *const fn () i64,
    /// The database this daemon has open; empty in tests.
    db_path: []const u8 = "",
    trial_nonce: ?[]const u8 = null,
    trial_ready: bool = false,
    /// Set by POST /api/shutdown; the daemon stops after answering.
    stop_requested: bool = false,
    /// Binding instance of the loaded provider; null without one.
    provider: ?[]const u8 = null,
    provider_status: ProviderStatus = .{},
    /// The provider's static traits; empty without one.
    traits: Traits = .{},
    running_post: ?*const fn () ?i64 = null,
    declared_fields: []const []const u8 = &.{},
    declared_fields_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),

    pub fn clearDeclaredFields(app: *App) void {
        app.declared_fields_arena.deinit();
        app.declared_fields_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        app.declared_fields = &.{};
    }

    pub fn loadDeclaredFields(app: *App, json: []const u8) !void {
        var replacement = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer replacement.deinit();
        const a = replacement.allocator();
        const parsed = try std.json.parseFromSliceLeaky([]const struct { name: []const u8 }, a, json, .{ .ignore_unknown_fields = true });
        var names: std.ArrayList([]const u8) = .empty;
        for (parsed) |field| if (field.name.len > 0) try names.append(a, field.name);
        app.clearDeclaredFields();
        app.declared_fields_arena = replacement;
        app.declared_fields = names.items;
    }
};

pub const ProviderStatus = struct {
    state: enum { none, loaded, unavailable, awaiting_approval } = .none,
    name: []const u8 = "",
    build: []const u8 = "",
    reason: []const u8 = "",
    candidate: ?@import("provider_loader.zig").Candidate = null,
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
    local_file: bool = false,
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
    if (err == error.TaskBound) return fail(a, .{ .status = .conflict, .code = "TaskBound", .message = "title comes from the provider" });
    const status: std.http.Status = switch (err) {
        error.UnknownTask, error.UnknownInterval, error.UnknownNote, error.UnknownProject => .not_found,
        error.Stale, error.Overlap, error.NoteOutside, error.OpenEnd, error.NotMergeable, error.TaskHasPostings, error.TaskOpen, error.DuplicateProject, error.AmbiguousTask => .conflict,
        error.InvalidRange => .bad_request,
        error.NoFocus, error.NoOpenInterval, error.AlreadyOpen, error.SomethingOpen, error.BindingConflict, error.PostingBlocked, error.PostingInFlight, error.InvalidState, error.NoProvider, error.NotBound, error.NothingToPost, error.SessionOpen => .conflict,
        error.UnknownPosting => .not_found,
        error.ProviderOutput => .bad_gateway,
        error.EmptyText, error.InvalidSetting, error.UnknownZone, error.InvalidTime, error.InvalidDate, error.InvalidSchedule, error.InvalidProjectLabel, error.InvalidProjectKey => .bad_request,
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

/// Update checks are explicit user actions, so even GET requires the marker.
pub fn updateRefused(port: u16, a: std.mem.Allocator, req: Request) ?Response {
    if (refused(port, a, req)) |r| return r;
    if (!req.marker) return fail(a, .{ .status = .forbidden, .code = "header", .message = "update requests need X-Kowalski: 1" });
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
    if (is(req, .GET, path, "/api/update/ready")) {
        const nonce = app.trial_nonce orelse return .{ .status = .not_found, .body = "{\"error\":\"not_found\"}" };
        if (!app.trial_ready) return .{ .status = .not_found, .body = "{\"error\":\"not_found\"}" };
        return send(a, .ok, .{ .nonce = nonce, .pid = GetCurrentProcessId(), .version = @import("build_options").version });
    }
    if (is(req, .POST, path, "/api/update/commit")) {
        const nonce = app.trial_nonce orelse return .{ .status = .not_found, .body = "{\"error\":\"not_found\"}" };
        const body = (parseBody(struct { nonce: []const u8 }, a, req.body) catch return badRequest(a, "body")) orelse return badRequest(a, "body");
        if (!std.mem.eql(u8, nonce, body.nonce)) return .{ .status = .conflict, .body = "{\"error\":\"nonce\"}" };
        app.trial_nonce = null;
        return .{ .status = .ok, .body = "{\"committed\":true}" };
    }
    if (app.trial_nonce != null and req.method != .GET) return .{ .status = .service_unavailable, .body = "{\"error\":\"updating\"}" };
    return route(app, a, req, path, params) catch |err| errorResponse(a, err);
}

test "trial gates mutations and commits only matching nonce" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const nonce = "0123456789abcdef0123456789abcdef";
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.GET, "/api/update/ready", "").status);
    f.app.trial_nonce = nonce;
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.GET, "/api/update/ready", "").status);
    f.app.trial_ready = true;
    const ready = f.call(.GET, "/api/update/ready", "");
    try std.testing.expectEqual(std.http.Status.ok, ready.status);
    try std.testing.expect(std.mem.indexOf(u8, ready.body, nonce) != null);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.GET, "/api/health", "").status);
    const gated = f.call(.POST, "/api/pause", "");
    try std.testing.expectEqual(std.http.Status.service_unavailable, gated.status);
    try std.testing.expectEqualStrings("{\"error\":\"updating\"}", gated.body);
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/update/commit", "{\"nonce\":\"wrong\"}").status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, f.arena.allocator(), .{ .method = .POST, .target = "/api/update/commit", .host = "127.0.0.1:47100", .body = "{\"nonce\":\"0123456789abcdef0123456789abcdef\"}" }).status);
    const committed = f.call(.POST, "/api/update/commit", "{\"nonce\":\"0123456789abcdef0123456789abcdef\"}");
    try std.testing.expectEqual(std.http.Status.ok, committed.status);
    try std.testing.expectEqualStrings("{\"committed\":true}", committed.body);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/pause", "").status);
}

fn is(req: Request, method: std.http.Method, path: []const u8, want: []const u8) bool {
    return req.method == method and std.mem.eql(u8, path, want);
}

fn route(app: *App, a: std.mem.Allocator, req: Request, path: []const u8, params: []const u8) !Response {
    if (is(req, .GET, path, "/api/health")) return send(a, .ok, .{ .ok = true, .db = app.db_path });
    if (is(req, .GET, path, "/api/version")) return send(a, .ok, .{ .version = @import("build_options").version, .pid = GetCurrentProcessId(), .update_repo = @import("build_options").update_repo });
    if (try projectsRoute(app, a, req, path, params)) |response| return response;
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
        if (app.provider == null) return send(a, .ok, .{ .instance = null, .fields = [0]std.json.Value{}, .settings = [0]std.json.Value{}, .post_options = [0]std.json.Value{}, .sessions = false, .not_signed_in_code = null, .status = app.provider_status });
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
            const body = try parseBody(struct { title: ?[]const u8 = null, project_id: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
            const choice = try projectChoice(a, req.body);
            if (body.title == null and choice == .omitted) return badRequest(a, "body");
            try app.store.updateTask(id, if (body.title) |title| std.mem.trim(u8, title, " \t") else null, choice, app.clock());
            return send(a, .ok, .{ .task = (try query.task(app.store, a, id)).? });
        }
    }
    if (is(req, .POST, path, "/api/tasks")) {
        const body = try parseBody(struct { title: []const u8, project_id: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        const id = try app.store.createTaskWithProject(std.mem.trim(u8, body.title, " \t"), try projectChoice(a, req.body), app.clock());
        return send(a, .created, .{ .task = (try query.task(app.store, a, id)).? });
    }
    if (is(req, .POST, path, "/api/capture")) {
        const Body = struct {
            source: []const u8,
            run: []const u8,
            event: ?[]const u8 = null,
            kind: []const u8,
            subject: ?[]const u8 = null,
            default_subject: ?[]const u8 = null,
            project_key: ?[]const u8 = null,
            project_hint: ?[]const u8 = null,
            first_prompt: ?[]const u8 = null,
            attended: bool = true,
            note: ?[]const u8 = null,
        };
        // Fields a newer source sends are skipped, so an updated hook never breaks an older daemon.
        const body = std.json.parseFromSliceLeaky(Body, a, req.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return badRequest(a, "body"),
        };
        const kind = std.meta.stringToEnum(store_mod.CaptureKind, body.kind) orelse return badRequest(a, "kind");
        for ([_]?[]const u8{ body.source, body.run, body.event, body.subject, body.default_subject }) |field| {
            if (field) |f| if (f.len == 0 or f.len > 200) return badRequest(a, "length");
        }
        if (kind == .subject and body.subject == null) return badRequest(a, "subject");
        if (body.note) |n| if (n.len > 2000) return badRequest(a, "note");
        if (body.event) |event| if (try app.store.captureEventSeen(body.source, event)) return send(a, .ok, .{ .applied = false });
        if (body.project_key) |key| if (key.len == 0 or key.len > 2048) return badRequest(a, "project_key");
        if (body.project_hint) |hint| if (hint.len > 200) return badRequest(a, "project_hint");
        if (body.first_prompt) |seed| if (seed.len > 2000) return badRequest(a, "first_prompt");
        const c: store_mod.Capture = .{ .source = body.source, .run = body.run, .event = body.event, .kind = kind, .attended = body.attended, .note = if (body.note) |n| try noteText(a, n) else null,
            .subject = body.subject, .default_subject = body.default_subject, .project_key = body.project_key, .project_hint = body.project_hint, .first_prompt = body.first_prompt };
        const result = try app.store.captureDetailed(c, app.clock());
        return send(a, .ok, result);
    }
    if (is(req, .POST, path, "/api/capture/history")) {
        const Interval = store_mod.HistoryInterval;
        const Body = struct { source: []const u8, run: []const u8, attended: bool = true, intervals: []const Interval };
        const body = try parseBody(Body, a, req.body) orelse return badRequest(a, "body");
        if (!historyLength(body.source, 200) or !historyLength(body.run, 200) or body.intervals.len > 500) return badRequest(a, "length");
        const now_ms = app.clock();
        var note_count: usize = 0;
        for (body.intervals) |interval| {
            if (!historyLength(interval.event, 200) or !historyLength(interval.subject, 200)) return badRequest(a, "length");
            if (interval.start_ms < 0 or interval.start_ms >= interval.end_ms or interval.end_ms > now_ms) return badRequest(a, "range");
            note_count += interval.notes.len;
            if (note_count > 5000) return badRequest(a, "notes");
            for (interval.notes) |note| {
                if (!historyLength(note.event, 200) or !historyLength(note.text, 2000)) return badRequest(a, "length");
                if (note.at_ms < interval.start_ms or note.at_ms > interval.end_ms) return badRequest(a, "note time");
            }
        }
        const result = try app.store.captureHistory(a, body.source, body.run, body.attended, body.intervals, now_ms, resolveHistorySubject);
        return switch (result) {
            .applied => |counts| send(a, .ok, counts),
            .conflict => |c| send(a, .conflict, .{ .@"error" = "HistoryConflict", .interval = c.index, .reason = c.reason }),
            .invalid_subject => badRequest(a, "subject"),
        };
    }
    if (is(req, .POST, path, "/api/switch") or is(req, .POST, path, "/api/parallel")) {
        const body = try parseBody(struct { task: []const u8, text: ?[]const u8 = null, project_id: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        const choice = try projectChoice(a, req.body);
        const scope = try choiceScope(app, choice);
        var created = false;
        const id = switch (try query.resolve(app.store, a, body.task, scope)) {
            .found => |id| id,
            .ambiguous => |list| return ambiguous(a, list),
            .none => blk: {
                const title = std.mem.trim(u8, body.task, " \t");
                if (title.len > 0 and title[0] == '#') return error.UnknownTask;
                created = true;
                break :blk try app.store.createTaskWithProject(title, if (choice == .omitted and scope == null) .omitted else .{ .selected = scope }, app.clock());
            },
        };
        const text = if (body.text) |t| blk: {
            if (t.len > 2000) return badRequest(a, "text");
            break :blk if (std.mem.trim(u8, t, " \t\r\n").len == 0) null else try noteText(a, t);
        } else null;
        const interval = if (std.mem.eql(u8, path, "/api/switch"))
            try app.store.switchToProject(id, text, choice, app.clock())
        else
            try app.store.openParallelProject(id, text, choice, app.clock());
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
        if (body.text.len > 2000) return badRequest(a, "text");
        const text = if (std.mem.trim(u8, body.text, " \t\r\n").len == 0) "" else try noteText(a, body.text);
        if (body.interval) |interval| {
            const at = body.at_ms orelse return badRequest(a, "at_ms");
            const note = try app.store.addNoteAt(interval, at, text, app.clock());
            return send(a, .created, .{ .note = note });
        }
        var target: ?i64 = null;
        if (body.task) |t| switch (try resolveExisting(app, a, t)) {
            .id => |id| target = id,
            .response => |r| return r,
        };
        const note = try app.store.addNote(target, text, app.clock());
        return send(a, .created, .{ .note = note });
    }
    if (is(req, .POST, path, "/api/notes/captured")) {
        const body = try parseBody(struct { from: []const u8, to: []const u8, apply: bool }, a, req.body) orelse return badRequest(a, "body");
        const from = parseDate(a, body.from) catch return badRequest(a, "from");
        const to = parseDate(a, body.to) catch return badRequest(a, "to");
        if (dayIndex(from) > dayIndex(to)) return badRequest(a, "range");
        const z = try loadZone(app, a);
        const first = try z.dayBounds(from.year, from.month, from.day);
        const last = try z.dayBounds(to.year, to.month, to.day);
        const count = try app.store.removeCapturedText(first.start_ms, last.end_ms, body.apply, app.clock());
        return if (body.apply) send(a, .ok, .{ .deleted = count }) else send(a, .ok, .{ .count = count });
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
    if (is(req, .GET, path, "/api/zones")) return send(a, .ok, .{ .zones = try zone.names(a) });
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

fn projectsRoute(app: *App, a: std.mem.Allocator, req: Request, path: []const u8, params: []const u8) !?Response {
    if (is(req, .GET, path, "/api/projects")) {
        const archived = try param(a, params, "archived") orelse "0";
        if (!std.mem.eql(u8, archived, "0") and !std.mem.eql(u8, archived, "1")) return badRequest(a, "archived");
        return send(a, .ok, .{ .projects = try query.projects(app.store, a, std.mem.eql(u8, archived, "1")) });
    }
    if (is(req, .POST, path, "/api/projects")) {
        const body = try parseBody(struct { label: []const u8 }, a, req.body) orelse return badRequest(a, "body");
        const id = try app.store.createProject(body.label, app.clock());
        return send(a, .created, .{ .project = (try query.project(app.store, a, id)).? });
    }
    if (is(req, .GET, path, "/api/project-keys")) return send(a, .ok, .{ .keys = try query.captureProjectKeys(app.store, a) });
    if (is(req, .PATCH, path, "/api/project-keys")) {
        const body = try parseBody(struct { source: []const u8, project_key: []const u8, project_id: i64 }, a, req.body) orelse return badRequest(a, "body");
        if (body.project_id <= 0) return badRequest(a, "project_id");
        var hint: ?[]const u8 = null;
        for (try query.captureProjectKeys(app.store, a)) |key| if (std.mem.eql(u8, key.source, body.source) and std.mem.eql(u8, key.project_key, body.project_key)) { hint = key.project_hint; break; };
        if (hint == null) return error.UnknownProject;
        try app.store.setCaptureProjectKey(body.source, body.project_key, hint.?, body.project_id, app.clock());
        return send(a, .ok, .{ .mapping = query.CaptureProjectKey{ .source = body.source, .project_key = body.project_key, .project_hint = hint.?, .project_id = body.project_id } });
    }
    if (is(req, .POST, path, "/api/projects/assign/preview")) {
        const Scope = struct { task_id: ?i64 = null, interval_ids: ?[]const i64 = null, unassigned_suggestions: bool = false };
        const body = try parseBody(struct { scope: Scope, project_id: ?i64 }, a, req.body) orelse return badRequest(a, "body");
        const count: u8 = @intFromBool(body.scope.task_id != null) + @as(u8, @intFromBool(body.scope.interval_ids != null)) + @as(u8, @intFromBool(body.scope.unassigned_suggestions));
        if (count != 1) return badRequest(a, "scope");
        if (body.project_id) |id| if (id <= 0) return badRequest(a, "project_id");
        var scope: store_mod.AssignmentScope = .unassigned_suggestions;
        if (body.scope.task_id) |id| {
            if (id <= 0 or try query.task(app.store, a, id) == null) return error.UnknownTask;
            scope = .{ .task_id = id };
        }
        if (body.scope.interval_ids) |ids| {
            if (ids.len == 0) return badRequest(a, "interval_ids");
            for (ids) |id| if (id <= 0) return badRequest(a, "interval_ids");
            scope = .{ .interval_ids = ids };
        }
        return send(a, .ok, try query.projectAssignmentPreview(app.store, a, scope, body.project_id));
    }
    if (is(req, .POST, path, "/api/projects/assign/apply")) {
        const body = try parseBody(struct { snapshot: store_mod.AssignmentSnapshot }, a, req.body) orelse return badRequest(a, "body");
        return send(a, .ok, try app.store.applyProjectAssign(body.snapshot, body.snapshot.project_id, app.clock()));
    }
    if (req.method == .PATCH) if (idBetween(path, "/api/projects/", "")) |id| {
        if (id <= 0) return badRequest(a, "id");
        const body = try parseBody(struct { label: ?[]const u8 = null, archived: ?bool = null }, a, req.body) orelse return badRequest(a, "body");
        if ((body.label == null) == (body.archived == null)) return badRequest(a, "body");
        if (body.label) |label| try app.store.renameProject(id, label, app.clock()) else try app.store.archiveProject(id, body.archived.?, app.clock());
        return send(a, .ok, .{ .project = (try query.project(app.store, a, id)).? });
    };
    return null;
}

/// Declared in settings.zig, or a setting the loaded provider declares.
fn knownSetting(app: *const App, key: []const u8) bool {
    if (settings_decl.find(key) != null) return true;
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
/// A captured subject names a task as `switch` does, and is created when
/// nothing matches. Null when it is ambiguous or names a missing `#id`.
fn captureTask(app: *App, a: std.mem.Allocator, text: []const u8, scope: ?i64) !?i64 {
    return switch (try query.resolve(app.store, a, text, scope)) {
        .found => |id| id,
        .ambiguous => null,
        .none => null,
    };
}

fn historyLength(text: []const u8, max: usize) bool {
    return text.len > 0 and text.len <= max;
}

fn resolveHistorySubject(s: *Store, a: std.mem.Allocator, text: []const u8, now_ms: i64) anyerror!?i64 {
    return switch (try query.resolve(s, a, text, null)) {
        .found => |id| id,
        .ambiguous => null,
        .none => blk: {
            const title = std.mem.trim(u8, text, " \t");
            if (title.len == 0 or title[0] == '#') break :blk null;
            break :blk try s.createHistoryTask(title, now_ms);
        },
    };
}

fn resolveExisting(app: *App, a: std.mem.Allocator, text: []const u8) !Existing {
    return switch (try query.resolve(app.store, a, text, try focusProject(app))) {
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

fn projectChoice(a: std.mem.Allocator, body: []const u8) !store_mod.ProjectChoice {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.InvalidProjectLabel;
    if (value != .object) return error.InvalidProjectLabel;
    const raw = value.object.get("project_id") orelse return .omitted;
    return switch (raw) {
        .null => .{ .selected = null },
        .integer => |id| if (id > 0) .{ .selected = id } else error.InvalidProjectLabel,
        else => error.InvalidProjectLabel,
    };
}

fn focusProject(app: *App) !?i64 {
    var stmt = try app.store.db.prepare("SELECT project_id FROM intervals WHERE end_ms IS NULL AND role='focus'");
    defer stmt.finalize();
    if (try stmt.step() != .row) return null;
    return if (stmt.columnIsNull(0)) null else stmt.columnI64(0);
}

fn choiceScope(app: *App, choice: store_mod.ProjectChoice) !?i64 {
    return switch (choice) { .omitted => try focusProject(app), .selected => |id| id };
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
    _ = a;
    return app.store.loadZone();
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
        .day_start_min = z.day_start_min,
        .date = today.text,
        .provider = app.provider,
        .link = app.traits.link,
        // The provider's paid break windows, shown when no override is set.
        .provider_paid_breaks = app.traits.paid_breaks,
        .lunch_open = try query.lunchOpen(app.store),
        .focus = focus,
        .focus_fields = if (focus) |f| try query.fields(app.store, a, f.task.id) else &.{},
        .parallel = parallel.items,
        .capture = .{ .runs = try query.captureRuns(app.store, a, now) },
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
    const project_totals = try query.projectTotalsBetween(app.store, a, bounds.start_ms, bounds.end_ms, app.clock());
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
        .day_start_min = z.day_start_min,
        .start_ms = bounds.start_ms,
        .end_ms = bounds.end_ms,
        .numbers = numbersOf(n),
        .tasks = totals.items,
        .intervals = intervals,
        .project_totals = project_totals,
        .summary = try summaryOf(app, a, date.text),
        .lunch_out_ms = if (lunches.len > 0) lunches[0].start_ms else null,
        .lunch_back_ms = if (lunches.len > 0 and !(lunch_open and lunches[lunches.len - 1].end_ms >= app.clock())) lunches[lunches.len - 1].end_ms else null,
        .last_end_ms = last_end,
        .changed_after_posting = try query.changedAfterPosting(app.store, date.text),
    });
}

// ---------------------------------------------------------------- traits

pub const PaidBreak = struct { from_min: u16, to_min: u16, minutes: u16 };

/// What the loaded provider allows (see `traits` in the contract).
pub const Traits = struct {
    sessions: bool = false,
    /// Opens a ref: `{ref}` is replaced by the percent-encoded ref.
    link: ?[]const u8 = null,
    paid_breaks: []const PaidBreak = &.{},
    /// Kept as `provider.<name>` settings and sent with every post.
    settings: []const ProviderSetting = &.{},
    /// Chosen per post in the Post dialog (or `post -o`) and sent with it.
    post_options: []const PostOption = &.{},
    /// The `Status.code` meaning "sign in again": the dashboard opens sign-in on it.
    not_signed_in_code: ?u32 = null,
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
    if (std.json.parseFromSliceLeaky(struct { not_signed_in_code: ?std.json.Value = null }, a, json, .{ .ignore_unknown_fields = true })) |d| {
        // Code 0 is success, so it never means "not signed in".
        if (d.not_signed_in_code) |v| if (v == .integer and v.integer > 0 and v.integer <= std.math.maxInt(u32)) {
            traits.not_signed_in_code = @intCast(v.integer);
        };
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
    if (q.len == 0) return send(a, .ok, .{ .results = [0]std.json.Value{} });
    const limit = try intParam(a, params, "limit", 25, 100) orelse return badRequest(a, "limit");
    const z = try loadZone(app, a);
    const now = app.clock();
    const DayTotal = struct { date: []const u8, total_ms: i64 };
    const Result = struct {
        task: query.Task,
        fields: []query.Field,
        snippet: ?[]const u8,
        historical_projects: []query.ProjectRef,
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
            .historical_projects = found.historical_projects,
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

/// Focus per day over the last `days` days, one series per task, per
/// project (`@project`, a name no provider field can take) or per value of a
/// provider field.
fn chart(app: *App, a: std.mem.Allocator, params: []const u8) !Response {
    const day_count = try intParam(a, params, "days", 14, 90) orelse return badRequest(a, "days");
    const group = try param(a, params, "group") orelse "task";
    if (std.mem.eql(u8, group, "@project")) return projectChart(app, a, day_count);
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

fn projectChart(app: *App, a: std.mem.Allocator, day_count: u32) !Response {
    const z = try loadZone(app, a);
    const today = dayIndex(try dateParam(app, a, null));
    const Series = struct { project_id: ?i64, label: []const u8, total_ms: i64 = 0, ms: []i64 };
    var dates: std.ArrayList([]const u8) = .empty;
    var series: std.StringArrayHashMapUnmanaged(Series) = .empty;
    for (0..day_count) |col| {
        const date = try fromCivilDays(a, today - @as(i64, @intCast(day_count - 1 - col)));
        try dates.append(a, date.text);
        const bounds = try z.dayBounds(date.year, date.month, date.day);
        for (try query.projectTotalsBetween(app.store, a, bounds.start_ms, bounds.end_ms, app.clock())) |t| {
            const key = if (t.project_id) |id| try std.fmt.allocPrint(a, "#{d}", .{id}) else "unassigned";
            const slot = try series.getOrPut(a, key);
            if (!slot.found_existing) {
                const ms = try a.alloc(i64, day_count);
                @memset(ms, 0);
                slot.value_ptr.* = .{ .project_id = t.project_id, .label = t.label, .ms = ms };
            }
            slot.value_ptr.ms[col] += t.focus_ms;
            slot.value_ptr.total_ms += t.focus_ms;
        }
    }
    const list = try a.dupe(Series, series.values());
    std.mem.sort(Series, list, {}, struct {
        fn lessThan(_: void, l: Series, r: Series) bool { return l.total_ms > r.total_ms; }
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

fn noteText(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, input, "\r\n") == null) return input;
    const output = try a.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') continue;
        output[j] = input[i];
        j += 1;
    }
    return output[0..j];
}

fn history(app: *App, a: std.mem.Allocator, req: Request, path: []const u8) !?Response {
    if (is(req, .POST, path, "/api/intervals")) {
        const body = try parseBody(struct { task: []const u8, role: []const u8 = "focus", start_ms: i64, end_ms: i64, project_id: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        const role = std.meta.stringToEnum(store_mod.Role, body.role) orelse return badRequest(a, "role");
        const choice = try projectChoice(a, req.body);
        const id = switch (try query.resolve(app.store, a, body.task, try choiceScope(app, choice))) {
            .found => |found| found,
            .none => return error.UnknownTask,
            .ambiguous => |list| return ambiguous(a, list),
        };
        const interval = try app.store.addIntervalProject(id, role, body.start_ms, body.end_ms, choice, app.clock());
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
        if (try projectChoice(a, req.body) == .selected) return fail(a, .{ .status = .conflict, .code = "AssignmentPreviewRequired" });
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
    if (req.method == .POST) if (idBetween(path, "/api/intervals/", "/end-at-activity")) |id| {
        const body = try parseBody(struct { seen: SeenBody }, a, req.body) orelse return badRequest(a, "body");
        try app.store.endAtLastActivity(id, seenOf(body.seen), app.clock());
        return send(a, .ok, .{ .interval = id });
    };
    if (req.method == .POST) if (idBetween(path, "/api/intervals/", "/take-focus")) |id| {
        const body = try parseBody(struct { seen: SeenBody }, a, req.body) orelse return badRequest(a, "body");
        try app.store.takeFocus(id, seenOf(body.seen), app.clock());
        return send(a, .ok, .{ .interval = id });
    };
    if (req.method == .PATCH) if (idBetween(path, "/api/intervals/", "")) |id| {
        const body = try parseBody(struct { seen: SeenBody, start_ms: i64, end_ms: ?i64 = null, snapshot: ?store_mod.AssignmentSnapshot = null, project_id: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        const choice = try projectChoice(a, req.body);
        if (choice == .selected) {
            const snapshot = body.snapshot orelse return fail(a, .{ .status = .conflict, .code = "AssignmentPreviewRequired" });
            if (snapshot.intervals.len != 1 or snapshot.intervals[0].id != id or snapshot.project_id != choice.selected) return error.Stale;
            if (body.start_ms != body.seen.start_ms or body.end_ms != body.seen.end_ms) return badRequest(a, "separate edits from assignment");
            _ = try app.store.applyProjectAssign(snapshot, snapshot.project_id, app.clock());
            return send(a, .ok, .{ .interval = id });
        }
        try app.store.editInterval(id, seenOf(body.seen), body.start_ms, body.end_ms, app.clock());
        return send(a, .ok, .{ .interval = id });
    };
    if (req.method == .POST) if (idBetween(path, "/api/notes/", "/delete")) |id| {
        try app.store.deleteNote(id, app.clock());
        return send(a, .ok, .{ .deleted = id });
    };
    if (req.method == .PATCH) if (idBetween(path, "/api/notes/", "")) |id| {
        const body = try parseBody(struct { text: []const u8, at_ms: ?i64 = null }, a, req.body) orelse return badRequest(a, "body");
        if (body.text.len > 2000) return badRequest(a, "text");
        const text = if (std.mem.trim(u8, body.text, " \t\r\n").len == 0) "" else try noteText(a, body.text);
        try app.store.editNote(id, text, body.at_ms, app.clock());
        return send(a, .ok, .{ .note = id });
    };
    return null;
}

/// A value's own rule from settings.zig, then the checks that need the
/// provider or a parser; the store checks the rest.
fn validUi(app: *const App, key: []const u8, value: ?[]const u8) bool {
    const v = value orelse return true;
    if (std.mem.eql(u8, key, "project_provider_field")) {
        if (v.len == 0) return true;
        if (v.len > 200) return false;
        for (app.declared_fields) |name| if (std.mem.eql(u8, v, name)) return true;
        return false;
    }
    if (providerSetting(app, key)) |s| return validProviderValue(s, v);
    if (settings_decl.find(key)) |d| if (!settings_decl.valid(d, v)) return false;
    if (std.mem.eql(u8, key, "paid_breaks")) {
        var buffer: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        return (parsePaidBreaks(fba.allocator(), v) catch return false) != null;
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
    var focus_spans: std.ArrayList(sessions.Span) = .empty;
    var prior_span: ?i64 = null;
    for (focus.spans) |span| {
        if (span.posting_span_id != null and span.posting_span_id == prior_span and focus_spans.items.len > 0 and focus_spans.items[focus_spans.items.len - 1].end_ms == span.start_ms) {
            focus_spans.items[focus_spans.items.len - 1].end_ms = span.end_ms;
        } else {
            try focus_spans.append(a, .{ .start_ms = span.start_ms, .end_ms = span.end_ms });
        }
        prior_span = span.posting_span_id;
    }
    const covered_spans = try a.alloc(sessions.Span, coverage.len);
    for (coverage, 0..) |span, i| covered_spans[i] = .{ .start_ms = span.start_ms, .end_ms = span.end_ms };
    const pieces = try sessions.remaining(a, &z, bounds.start_ms, bounds.end_ms, focus_spans.items, covered_spans);
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
            try app.loadDeclaredFields(outcome.done.out);
            return send(a, .ok, .{ .instance = app.provider, .fields = parsed, .settings = app.traits.settings, .post_options = app.traits.post_options, .sessions = app.traits.sessions, .not_signed_in_code = app.traits.not_signed_in_code, .status = app.provider_status });
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
        f.app.clearDeclaredFields();
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
    try std.testing.expectEqual(std.http.Status.forbidden, updateRefused(f.app.port, a, .{ .method = .GET, .target = "/api/update", .host = "127.0.0.1:47100" }).?.status);
    try std.testing.expectEqual(std.http.Status.forbidden, updateRefused(f.app.port, a, .{ .method = .POST, .target = "/api/update", .host = "127.0.0.1:47100" }).?.status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .POST, .target = "/api/restart", .host = "127.0.0.1:47100" }).status);
    try std.testing.expectEqual(std.http.Status.forbidden, handle(&f.app, a, .{ .method = .POST, .target = "/api/pause", .host = "127.0.0.1:47100", .marker = true, .origin = "http://evil.test" }).status);
    try std.testing.expectEqual(std.http.Status.ok, handle(&f.app, a, .{ .method = .POST, .target = "/api/pause", .host = "127.0.0.1:47100", .marker = true, .origin = "http://127.0.0.1:47100" }).status);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, handle(&f.app, a, .{ .method = .PUT, .target = "/api/pause", .host = "127.0.0.1:47100", .marker = true }).status);
    // GET never changes anything: a mutation route under GET is not found.
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.GET, "/api/pause", "").status);
}

test "health reports the open database" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.app.db_path = try std.fs.path.resolve(f.arena.allocator(), &.{"scratch/work.db"});
    const reply = f.call(.GET, "/api/health", "");
    try std.testing.expectEqual(std.http.Status.ok, reply.status);
    const health = try std.json.parseFromSliceLeaky(struct { ok: bool, db: []const u8 }, f.arena.allocator(), reply.body, .{});
    try std.testing.expect(health.ok);
    try std.testing.expectEqualStrings(f.app.db_path, health.db);
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

test "state reports active capture runs by activity" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = try f.store.createTask("Captured", test_now);
    try f.db.exec("INSERT INTO capture_runs(source,run,task_id,attended,working,lease_until_ms,started_ms) VALUES ('test','working',1,1,1,1773100600000,1773100000000),('test','quiet',1,1,1,1773100600000,1773100000000),('test','idle',1,1,0,1773100600000,1773100000000),('test','ended',1,1,0,1773100600000,1773100000000),('test','expired',1,1,1,1773099999999,1773100000000)");
    try f.db.exec("UPDATE capture_runs SET idle_since_ms=1773100000000 WHERE run='idle'; UPDATE capture_runs SET ended_ms=1773100000000 WHERE run='ended'; INSERT INTO capture_events(source,event,run,kind,at_ms) VALUES ('test','w','working','prompt',1773099999000),('test','q','quiet','prompt',1773099400000),('test','i','idle','stop',1773099900000)");
    const State = struct { capture: struct { runs: []query.CaptureRun } };
    const state_data = try f.get(State, "/api/state");
    try std.testing.expectEqual(@as(usize, 3), state_data.capture.runs.len);
    var working = false;
    var quiet = false;
    var idle = false;
    for (state_data.capture.runs) |run| {
        try std.testing.expectEqualStrings("Captured", run.task.?.title);
        if (std.mem.eql(u8, run.run, "working")) working = std.mem.eql(u8, run.state, "working");
        if (std.mem.eql(u8, run.run, "quiet")) quiet = std.mem.eql(u8, run.state, "quiet");
        if (std.mem.eql(u8, run.run, "idle")) idle = std.mem.eql(u8, run.state, "idle");
    }
    try std.testing.expect(working and quiet and idle);
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

test "task title can change only without a binding" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Original\"}");
    const renamed = f.call(.PATCH, "/api/tasks/1", "{\"title\":\"  Corrected  \"}");
    try std.testing.expectEqual(std.http.Status.ok, renamed.status);
    try std.testing.expect(contains(renamed.body, "\"title\":\"Corrected\""));
    try f.store.bind(1, "test", "R-1", test_now);
    const bound = f.call(.PATCH, "/api/tasks/1", "{\"title\":\"Changed\"}");
    try std.testing.expectEqual(std.http.Status.conflict, bound.status);
    try std.testing.expect(contains(bound.body, "TaskBound"));
    try std.testing.expect(contains(bound.body, "title comes from the provider"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM tasks WHERE id=1 AND title='Corrected'"));
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/tasks/1", "{\"project_id\":null}").status);
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Other\"}");
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/tasks/2", "{\"title\":\"  \"}").status);
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
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"update_channel\":\"stable\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"update_channel\":\"preview\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"update_channel\":\"nightly\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"capture_text\":\"keep\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"capture_text\":\"time\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"capture_text\":\"none\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"nope\":\"1\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"daily_work_minutes\":\"0\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"http_port\":\"80\"}").status);
    try std.testing.expectEqual(@as(u16, 480), try f.store.dailyWorkMinutes());
}

test "captured text removal validates dates and keeps time" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const prompt = "{\"source\":\"agent\",\"run\":\"r\",\"kind\":\"prompt\",\"first_prompt\":\"work\",\"note\":\"asked\"}";
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", prompt).status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/notes/captured", "{\"from\":\"2026-02-30\",\"to\":\"2026-03-09\",\"apply\":false}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/notes/captured", "{\"from\":\"2026-03-10\",\"to\":\"2026-03-09\",\"apply\":false}").status);
    const dry = f.call(.POST, "/api/notes/captured", "{\"from\":\"2026-03-09\",\"to\":\"2026-03-09\",\"apply\":false}");
    try std.testing.expectEqual(std.http.Status.ok, dry.status);
    try std.testing.expect(contains(dry.body, "\"count\":1"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM notes"));
    const applied = f.call(.POST, "/api/notes/captured", "{\"from\":\"2026-03-09\",\"to\":\"2026-03-09\",\"apply\":true}");
    try std.testing.expectEqual(std.http.Status.ok, applied.status);
    try std.testing.expect(contains(applied.body, "\"deleted\":1"));
    try std.testing.expectEqual(@as(i64, 0), try apiScalar(&f.db, "SELECT count(*) FROM notes"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE captured=1"));
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

fn apiScalar(db: *sqlite.Db, sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try std.testing.expectEqual(.row, try stmt.step());
    return stmt.columnI64(0);
}

test "manual focus keeps its project when capture maps the same task elsewhere" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/projects", "{\"label\":\"A\"}").status);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/projects", "{\"label\":\"B\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"s\",\"kind\":\"start\",\"project_key\":\"k\",\"project_hint\":\"capture\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/project-keys", "{\"source\":\"agent\",\"project_key\":\"k\",\"project_id\":2}").status);
    const manual = f.call(.POST, "/api/switch", "{\"task\":\"T\",\"project_id\":1}");
    try std.testing.expectEqual(std.http.Status.ok, manual.status);
    const t = (try std.json.parseFromSliceLeaky(struct { task: query.Task }, f.arena.allocator(), manual.body, .{ .ignore_unknown_fields = true })).task.id;
    test_now += 30_000;
    const prompt = try std.fmt.allocPrint(f.arena.allocator(), "{{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p\",\"kind\":\"prompt\",\"subject\":\"#{d}\",\"note\":\"do work\"}}", .{t});
    const result = f.call(.POST, "/api/capture", prompt);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(contains(result.body, "\"project_id\":2"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND role='focus' AND project_id=1 AND captured=0"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM notes WHERE text='do work' AND source='prompt'"));
}

test "title lookup is scoped to project and reports ambiguity within it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/projects", "{\"label\":\"A\"}");
    _ = f.call(.POST, "/api/projects", "{\"label\":\"B\"}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Same\",\"project_id\":1}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"same\",\"project_id\":2}");
    const a = f.call(.POST, "/api/switch", "{\"task\":\"SAME\",\"project_id\":1}");
    try std.testing.expectEqual(std.http.Status.ok, a.status);
    try std.testing.expect(contains(a.body, "\"id\":1"));
    const b = f.call(.POST, "/api/switch", "{\"task\":\"SAME\",\"project_id\":2}");
    try std.testing.expectEqual(std.http.Status.ok, b.status);
    try std.testing.expect(contains(b.body, "\"id\":2"));
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"SAME\",\"project_id\":2}");
    const ambiguous_result = f.call(.POST, "/api/switch", "{\"task\":\"same\",\"project_id\":2}");
    try std.testing.expectEqual(std.http.Status.conflict, ambiguous_result.status);
    try std.testing.expect(contains(ambiguous_result.body, "AmbiguousTask"));
    const by_id = f.call(.POST, "/api/switch", "{\"task\":\"#1\",\"project_id\":2}");
    try std.testing.expectEqual(std.http.Status.ok, by_id.status);
    try std.testing.expect(contains(by_id.body, "\"id\":1"));
}

test "shared captured task alternates projects between runs" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    test_now = 1_773_136_800_000;
    const task = f.call(.POST, "/api/tasks", "{\"title\":\"Shared\"}");
    try std.testing.expectEqual(std.http.Status.created, task.status);
    // Each run names its project on start; the first sight creates it.
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a0\",\"kind\":\"start\",\"project_key\":\"a\",\"project_hint\":\"A\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"b\",\"event\":\"b0\",\"kind\":\"start\",\"project_key\":\"b\",\"project_hint\":\"B\"}").status);
    const first = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a1\",\"kind\":\"prompt\",\"subject\":\"#1\",\"note\":\"first\"}");
    try std.testing.expectEqual(std.http.Status.ok, first.status);
    test_now += 20_000;
    const second = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"b\",\"event\":\"b1\",\"kind\":\"prompt\",\"subject\":\"#1\",\"note\":\"second\"}");
    try std.testing.expectEqual(std.http.Status.ok, second.status);
    test_now += 20_000;
    const third = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a2\",\"kind\":\"prompt\",\"note\":\"third\"}");
    try std.testing.expectEqual(std.http.Status.ok, third.status);
    try std.testing.expectEqual(@as(i64, 3), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND captured=1"));
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND project_id=1"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND project_id=2"));
    try std.testing.expectEqual(@as(i64, 3), try apiScalar(&f.db, "SELECT count(*) FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=1"));
}

test "grace continuation carries old project through gap before split" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    test_now = 1_773_136_800_000;
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a0\",\"kind\":\"start\",\"project_key\":\"a\",\"project_hint\":\"A\"}");
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a1\",\"kind\":\"prompt\",\"first_prompt\":\"Task\",\"note\":\"keep\"}").status);
    test_now += 20_000;
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a2\",\"kind\":\"stop\"}");
    test_now += 10_000;
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a3\",\"kind\":\"end\"}");
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"b\",\"event\":\"b0\",\"kind\":\"start\",\"project_key\":\"b\",\"project_hint\":\"B\"}");
    test_now += 10_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"b\",\"event\":\"b1\",\"kind\":\"prompt\",\"subject\":\"#1\",\"note\":\"new\"}").status);
    try std.testing.expectEqual(@as(i64, 40_000), try apiScalar(&f.db, "SELECT end_ms-start_ms FROM intervals WHERE project_id=1"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE project_id=2 AND posting_span_id=(SELECT id FROM intervals WHERE project_id=1)"));
}

test "history add resolves a title in chosen project" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/projects", "{\"label\":\"A\"}");
    _ = f.call(.POST, "/api/projects", "{\"label\":\"B\"}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Same\",\"project_id\":1}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Same\",\"project_id\":2}");
    const body = try std.fmt.allocPrint(f.arena.allocator(), "{{\"task\":\"same\",\"project_id\":2,\"start_ms\":{d},\"end_ms\":{d}}}", .{ test_now - 120_000, test_now - 60_000 });
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/intervals", body).status);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=2 AND project_id=2"));
}

test "capture promotes manual parallel without changing its project" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/projects", "{\"label\":\"A\"}");
    _ = f.call(.POST, "/api/projects", "{\"label\":\"B\"}");
    _ = f.call(.POST, "/api/parallel", "{\"task\":\"T\",\"project_id\":1}");
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"s\",\"kind\":\"start\",\"project_key\":\"b\",\"project_hint\":\"B\"}");
    test_now += 20_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p\",\"kind\":\"prompt\",\"subject\":\"#1\"}").status);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='focus' AND end_ms IS NULL AND project_id=1"));
    try std.testing.expectEqual(@as(i64, 0), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND project_id=2"));
}

test "subject uses target default when key is absent" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/projects", "{\"label\":\"A\"}");
    _ = f.call(.POST, "/api/projects", "{\"label\":\"B\"}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Old\",\"project_id\":1}");
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"New\",\"project_id\":2}");
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p\",\"kind\":\"prompt\",\"subject\":\"#1\",\"note\":\"old\"}");
    test_now += 20_000;
    const subject = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"s\",\"kind\":\"subject\",\"subject\":\"#2\"}");
    try std.testing.expectEqual(std.http.Status.ok, subject.status);
    try std.testing.expect(contains(subject.body, "\"project_id\":2"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=2 AND project_id=2 AND end_ms IS NULL"));
}

test "same-task subject with changed key splits captured project" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"s\",\"kind\":\"start\",\"project_key\":\"a\",\"project_hint\":\"A\"}");
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p\",\"kind\":\"prompt\",\"first_prompt\":\"T\",\"note\":\"old\"}");
    test_now += 20_000;
    const changed = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"x\",\"kind\":\"subject\",\"subject\":\"#1\",\"project_key\":\"b\",\"project_hint\":\"B\"}");
    try std.testing.expectEqual(std.http.Status.ok, changed.status);
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND captured=1"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND project_id=2 AND end_ms IS NULL"));
}

test "a project change during a run's grace waits until work resumes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"s\",\"kind\":\"start\",\"project_key\":\"a\",\"project_hint\":\"A\"}");
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p\",\"kind\":\"prompt\",\"first_prompt\":\"T\"}");
    test_now += 20_000;
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"t\",\"kind\":\"stop\"}");
    test_now += 10_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"x\",\"kind\":\"subject\",\"subject\":\"#1\",\"project_key\":\"b\",\"project_hint\":\"B\"}").status);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1"));
    test_now += 10_000;
    _ = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"q\",\"kind\":\"prompt\"}");
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE task_id=1 AND project_id=2 AND end_ms IS NULL"));
}

test "task patch rolls back title when project is invalid" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks", "{\"title\":\"Original\"}");
    try std.testing.expectEqual(std.http.Status.not_found, f.call(.PATCH, "/api/tasks/1", "{\"title\":\"Changed\",\"project_id\":999}").status);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM tasks WHERE id=1 AND title='Original'"));
}

test "provider field validation uses all loaded declarations without provider GET" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.app.provider = "fake";
    var fields: std.ArrayList(u8) = .empty;
    const a = f.arena.allocator();
    try fields.appendSlice(a, "[");
    for (0..70) |i| {
        if (i != 0) try fields.appendSlice(a, ",");
        try fields.appendSlice(a, try std.fmt.allocPrint(a, "{{\"name\":\"field{d}\"}}", .{i}));
    }
    try fields.appendSlice(a, "]");
    try f.app.loadDeclaredFields(fields.items);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"project_provider_field\":\"field69\"}").status);
    f.app.clearDeclaredFields();
    try f.app.loadDeclaredFields("[{\"name\":\"replacement\"}]");
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"project_provider_field\":\"field69\"}").status);
}

test "capture key changes split captured time, terminal context waits, and duplicate is inert" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    test_now = 1_773_136_800_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"s\",\"kind\":\"start\",\"project_key\":\"A\",\"project_hint\":\"Alpha\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"b\",\"kind\":\"busy\"}").status);
    try std.testing.expectEqual(@as(i64, 0), try apiScalar(&f.db, "SELECT count(*) FROM tasks"));
    try std.testing.expectEqual(@as(i64, 0), try apiScalar(&f.db, "SELECT count(*) FROM intervals"));
    const first = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p1\",\"kind\":\"prompt\",\"first_prompt\":\"Investigate startup failure\",\"note\":\"first note\"}");
    try std.testing.expectEqual(std.http.Status.ok, first.status);
    try std.testing.expect(contains(first.body, "\"project_id\":1"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM tasks WHERE title='Investigate startup failure' AND project_id=1"));
    test_now += 20_000;
    const second = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p2\",\"kind\":\"prompt\",\"project_key\":\"B\",\"project_hint\":\"Beta\",\"note\":\"second note\"}");
    try std.testing.expectEqual(std.http.Status.ok, second.status);
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE captured=1 AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM notes WHERE text='first note' AND interval_id=(SELECT id FROM intervals WHERE project_id=1)"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM notes WHERE text='second note' AND interval_id=(SELECT id FROM intervals WHERE project_id=2)"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE project_id=1 AND posting_span_id=id"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE project_id=2 AND posting_span_id=(SELECT id FROM intervals WHERE project_id=1)"));
    const duplicate = f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p2\",\"kind\":\"prompt\",\"project_key\":\"C\",\"project_hint\":\"Gamma\"}");
    try std.testing.expect(contains(duplicate.body, "\"applied\":false"));
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM projects"));
    test_now += 10_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"stop\",\"kind\":\"stop\",\"project_key\":\"A\"}").status);
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/projects/1", "{\"archived\":true}").status);
    test_now += 10_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"r\",\"event\":\"p3\",\"kind\":\"prompt\"}").status);
    try std.testing.expectEqual(@as(i64, 3), try apiScalar(&f.db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND project_id=1"));
}

test "capture keys keep distinct long hints and reject blank first hints" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var hint: [200]u8 = undefined;
    @memset(&hint, 'x');
    const a = f.arena.allocator();
    const first = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"one\",\"event\":\"a\",\"kind\":\"start\",\"project_key\":\"one\",\"project_hint\":\"{s}\"}}", .{hint[0..]});
    const second = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"two\",\"event\":\"b\",\"kind\":\"start\",\"project_key\":\"two\",\"project_hint\":\"{s}\"}}", .{hint[0..]});
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", first).status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", second).status);
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM projects"));
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(DISTINCT label) FROM projects WHERE length(CAST(label AS BLOB))<=200"));
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"bad\",\"event\":\"x\",\"kind\":\"start\",\"project_key\":\"bad\",\"project_hint\":\"  \"}").status);
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM projects"));
}

test "a new capture key joins the user's project of the same name" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/projects", "{\"label\":\"kowalski\"}").status);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/projects", "{\"label\":\"old\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/projects/2", "{\"archived\":true}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"a\",\"event\":\"a0\",\"kind\":\"start\",\"project_key\":\"git:h/kowalski\",\"project_hint\":\"Kowalski\"}").status);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT project_id FROM capture_project_keys WHERE project_key='git:h/kowalski'"));
    // An archived project is not joined: the key gets a project of its own.
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"b\",\"event\":\"b0\",\"kind\":\"start\",\"project_key\":\"git:h/old\",\"project_hint\":\"old\"}").status);
    try std.testing.expectEqual(@as(i64, 3), try apiScalar(&f.db, "SELECT project_id FROM capture_project_keys WHERE project_key='git:h/old'"));
    // Neither is a project another key already claims.
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"agent\",\"run\":\"c\",\"event\":\"c0\",\"kind\":\"start\",\"project_key\":\"git:fork/kowalski\",\"project_hint\":\"kowalski\"}").status);
    try std.testing.expectEqual(@as(i64, 4), try apiScalar(&f.db, "SELECT project_id FROM capture_project_keys WHERE project_key='git:fork/kowalski'"));
    try std.testing.expectEqual(@as(i64, 4), try apiScalar(&f.db, "SELECT count(*) FROM projects"));
}

test "explicit Unassigned blocks first provider fallback and invalid labels are ignored" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.app.provider = "fake";
    try std.testing.expectEqual(std.http.Status.ok, f.call(.GET, "/api/provider", "").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"project_provider_field\":\"unknown\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"project_provider_field\":\"client\"}").status);
    const explicit = f.call(.POST, "/api/tasks", "{\"title\":\"explicit\",\"project_id\":null}");
    try std.testing.expectEqual(std.http.Status.created, explicit.status);
    const id = (try std.json.parseFromSliceLeaky(struct { task: query.Task }, f.arena.allocator(), explicit.body, .{ .ignore_unknown_fields = true })).task.id;
    try f.store.bindWithFields(id, "fake", "E-1", &.{.{ .name = "client", .value = "Valid" }}, test_now);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM tasks WHERE title='explicit' AND project_id IS NULL AND project_choice_explicit=1 AND project_fallback_eligible=0"));
    const pending = try f.store.createTask("pending", test_now);
    try f.store.bindWithFields(pending, "fake", "P-1", &.{.{ .name = "client", .value = " bad " }}, test_now);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM tasks WHERE title='pending' AND project_id IS NULL AND project_fallback_eligible=0"));
    try f.store.bindWithFields(pending, "fake", "P-1", &.{.{ .name = "client", .value = "Valid" }}, test_now);
    try std.testing.expectEqual(@as(i64, 0), try apiScalar(&f.db, "SELECT count(*) FROM projects"));
    const eligible = try f.store.createTask("eligible", test_now);
    try f.store.bindWithFields(eligible, "fake", "E-2", &.{.{ .name = "client", .value = "Valid" }}, test_now);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM projects WHERE label='Valid'"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM tasks WHERE title='eligible' AND project_id=(SELECT id FROM projects WHERE label='Valid') AND project_fallback_eligible=0"));
}

test "project assignment preview is read-only and apply checks task role totals and scope" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    _ = f.call(.POST, "/api/projects", "{\"label\":\"A\"}");
    _ = f.call(.POST, "/api/projects", "{\"label\":\"B\"}");
    const task_id = try f.store.createTaskWithProject("T", .{ .selected = 1 }, test_now);
    const other = try f.store.createTask("other", test_now);
    const start = test_now - 120_000;
    const end = test_now - 60_000;
    const interval = try f.store.addInterval(task_id, .focus, start, end, test_now);
    const edit_path = try std.fmt.allocPrint(a, "/api/intervals/{d}", .{interval});
    const edit = try std.fmt.allocPrint(a, "{{\"seen\":{{\"start_ms\":{d},\"end_ms\":{d}}},\"start_ms\":{d},\"end_ms\":{d},\"project_id\":2}}", .{ start, end, start, end });
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.PATCH, edit_path, edit).status);
    const move_path = try std.fmt.allocPrint(a, "/api/intervals/{d}/move", .{interval});
    const move = try std.fmt.allocPrint(a, "{{\"seen\":{{\"start_ms\":{d},\"end_ms\":{d}}},\"task\":{d},\"project_id\":2}}", .{ start, end, other });
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, move_path, move).status);
    const preview_body = try std.fmt.allocPrint(a, "{{\"scope\":{{\"task_id\":{d}}},\"project_id\":2}}", .{task_id});
    const preview = f.call(.POST, "/api/projects/assign/preview", preview_body);
    try std.testing.expectEqual(std.http.Status.ok, preview.status);
    const parsed = try std.json.parseFromSliceLeaky(store_mod.AssignmentPreview, a, preview.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.snapshot.intervals.len);
    try std.testing.expectEqual(@as(i64, 60_000), parsed.snapshot.intervals[0].focus_ms);
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE project_id=1"));
    const apply_body = try std.json.Stringify.valueAlloc(a, .{ .snapshot = parsed.snapshot }, .{});
    try f.db.exec("UPDATE intervals SET role='parallel' WHERE id=1");
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/projects/assign/apply", apply_body).status);
    try f.db.exec("UPDATE intervals SET role='focus' WHERE id=1");
    try f.db.exec("UPDATE intervals SET task_id=2 WHERE id=1");
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/projects/assign/apply", apply_body).status);
    try f.db.exec("UPDATE intervals SET task_id=1 WHERE id=1");
    const applied = f.call(.POST, "/api/projects/assign/apply", apply_body);
    try std.testing.expectEqual(std.http.Status.ok, applied.status);
    try std.testing.expect(contains(applied.body, "\"changed\":1"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM intervals WHERE project_id=2"));
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/projects/assign/apply", apply_body).status);
}

test "forty seconds split by project posts as one unchanged session" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.app.provider = "fake";
    f.app.traits = parseTraits(f.arena.allocator(), "{\"sessions\":true}");
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"post_sessions\":\"1\"}").status);
    const day_start = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 10)).start_ms;
    test_now = day_start + 10 * 3_600_000 + 10_000;
    const baseline = try f.store.createTask("baseline", test_now);
    const split = try f.store.createTask("split", test_now);
    try f.store.bind(baseline, "fake", "BASE", test_now);
    try f.store.bind(split, "fake", "SPLIT", test_now);
    const a = try f.store.createProject("A", test_now);
    const b = try f.store.createProject("B", test_now);
    const baseline_start = day_start + 9 * 3_600_000 + 10_000;
    _ = try f.store.addIntervalProject(baseline, .focus, baseline_start, baseline_start + 40_000, .{ .selected = a }, test_now);
    _ = try f.store.switchToProject(split, null, .{ .selected = a }, test_now);
    test_now += 20_000;
    _ = try f.store.switchToProject(split, null, .{ .selected = b }, test_now);
    test_now += 20_000;
    try f.store.stop(split, test_now);
    try std.testing.expectEqual(@as(i64, 40_000), try apiScalar(&f.db, "SELECT sum(end_ms-start_ms) FROM intervals WHERE task_id=2 AND role='focus'"));
    const offer = f.call(.GET, "/api/postings?date=2026-03-10", "");
    try std.testing.expectEqual(std.http.Status.ok, offer.status);
    try std.testing.expect(contains(offer.body, "\"total_focus_ms\":40000"));
    worker.Fake.post_code = 0;
    worker.Fake.quote_code = 0;
    worker.Fake.fake_policy_past_only = false;
    const baseline_post = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.created, baseline_post.status);
    const split_post = f.call(.POST, "/api/postings", "{\"date\":\"2026-03-10\",\"task\":\"#2\"}");
    try std.testing.expectEqual(std.http.Status.created, split_post.status);
    try std.testing.expectEqual(@as(i64, 2), try apiScalar(&f.db, "SELECT count(*) FROM postings WHERE covered_end_ms-covered_start_ms=40000"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(DISTINCT amount_micro) FROM postings WHERE state='confirmed'"));
    try std.testing.expectEqual(@as(i64, 1), try apiScalar(&f.db, "SELECT count(*) FROM postings WHERE task_id=2 AND covered_start_ms=(SELECT min(start_ms) FROM intervals WHERE task_id=2) AND covered_end_ms=(SELECT max(end_ms) FROM intervals WHERE task_id=2)"));
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

test "a quote failing with the not-signed-in code carries it, and the trait reaches the provider fields" {
    var f: Fixture = .{};
    try postingFixture(&f);
    defer f.deinit();
    _ = f.call(.POST, "/api/tasks/1/bind", "{\"ref\":\"T-1\"}");
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"not_signed_in_code\":null"));
    f.app.traits = parseTraits(f.arena.allocator(), "{\"not_signed_in_code\":7}");
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"not_signed_in_code\":7"));
    worker.Fake.quote_code = 7;
    defer worker.Fake.quote_code = 0;
    const before = worker.Fake.posted.load(.acquire);
    const r = f.call(.POST, "/api/postings", "{\"task\":\"T-1\",\"date\":\"2026-03-10\",\"dry_run\":true}");
    try std.testing.expectEqual(std.http.Status.bad_gateway, r.status);
    try std.testing.expect(contains(r.body, "\"error\":\"ProviderFailed\",\"code\":7"));
    try std.testing.expectEqual(before, worker.Fake.posted.load(.acquire));
}

test "a malformed not-signed-in code is dropped" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const b = arena.allocator();
    try std.testing.expectEqual(@as(?u32, 1), parseTraits(b, "{\"not_signed_in_code\":1}").not_signed_in_code);
    try std.testing.expectEqual(@as(?u32, null), parseTraits(b, "{}").not_signed_in_code);
    for ([_][]const u8{ "\"1\"", "1.5", "0", "-1", "4294967296", "null", "true" }) |bad| {
        const json = try std.mem.concat(b, u8, &.{ "{\"sessions\":true,\"not_signed_in_code\":", bad, "}" });
        const traits = parseTraits(b, json);
        try std.testing.expectEqual(@as(?u32, null), traits.not_signed_in_code);
        try std.testing.expect(traits.sessions);
    }
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
    try std.testing.expect(contains(f.call(.GET, "/api/provider", "").body, "\"fields\":[],\"settings\":[],\"post_options\":[]"));
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

test "manual notes preserve lines and enforce the byte limit on every path" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/tasks", "{\"title\":\"A\"}").status);
    const opened = f.call(.POST, "/api/switch", "{\"task\":\"#1\"}");
    try std.testing.expectEqual(std.http.Status.ok, opened.status);
    const interval = (try std.json.parseFromSliceLeaky(struct { interval: i64 }, a, opened.body, .{ .ignore_unknown_fields = true })).interval;
    const long = try a.alloc(u8, 2000);
    @memset(long, 'x');
    long[1000] = '\n';
    const too_long = try a.alloc(u8, 2001);
    @memset(too_long, 'x');
    const focus_body = try std.json.Stringify.valueAlloc(a, .{ .text = long }, .{});
    const focus_over = try std.json.Stringify.valueAlloc(a, .{ .text = too_long }, .{});
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/notes", focus_body).status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/notes", focus_over).status);
    const timed_body = try std.json.Stringify.valueAlloc(a, .{ .interval = interval, .at_ms = test_now, .text = long }, .{});
    const timed_over = try std.json.Stringify.valueAlloc(a, .{ .interval = interval, .at_ms = test_now, .text = too_long }, .{});
    const added = f.call(.POST, "/api/notes", timed_body);
    try std.testing.expectEqual(std.http.Status.created, added.status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/notes", timed_over).status);
    const note = (try std.json.parseFromSliceLeaky(struct { note: i64 }, a, added.body, .{})).note;
    const target = try std.fmt.allocPrint(a, "/api/notes/{d}", .{note});
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, target, focus_body).status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, target, focus_over).status);
    const crlf = "\nfirst\r\nsecond\r\nthird\n";
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, target, try std.json.Stringify.valueAlloc(a, .{ .text = crlf }, .{})).status);
    const Day = struct { intervals: []struct { notes: []query.Note } };
    const viewed = try f.get(Day, "/api/day?date=2026-03-09");
    try std.testing.expectEqual(@as(usize, 2), viewed.intervals[0].notes.len);
    try std.testing.expectEqualStrings(long, viewed.intervals[0].notes[0].text);
    try std.testing.expectEqualStrings("\nfirst\nsecond\nthird\n", viewed.intervals[0].notes[1].text);
}

test "session note text accepts 2000 bytes and normalizes CRLF" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/tasks", "{\"title\":\"A\"}").status);
    const long = try a.alloc(u8, 2000);
    @memset(long, 'x');
    long[1000] = '\n';
    const too_long = try a.alloc(u8, 2001);
    @memset(too_long, 'x');
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/switch", try std.json.Stringify.valueAlloc(a, .{ .task = "#1", .text = too_long }, .{})).status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/switch", try std.json.Stringify.valueAlloc(a, .{ .task = "#1", .text = long }, .{})).status);
    const Day = struct { intervals: []struct { text: ?[]const u8 } };
    const viewed = try f.get(Day, "/api/day?date=2026-03-09");
    try std.testing.expectEqualStrings(long, viewed.intervals[0].text.?);
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/tasks", "{\"title\":\"B\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/switch", "{\"task\":\"#2\",\"text\":\"first\\r\\nsecond\"}").status);
    const normalized = try f.get(Day, "/api/day?date=2026-03-09");
    try std.testing.expectEqualStrings("first\nsecond", normalized.intervals[normalized.intervals.len - 1].text.?);
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
    // A provider field named like the core grouping still charts by its values.
    const by_field = try f.get(Chart, "/api/chart?days=7&group=project");
    try std.testing.expectEqual(@as(usize, 1), by_field.series.len);
    try std.testing.expectEqualStrings("-", by_field.series[0].label);
    const by_project = try f.get(Chart, "/api/chart?days=7&group=%40project");
    try std.testing.expectEqual(@as(usize, 1), by_project.series.len);
    try std.testing.expectEqual(@as(i64, 5_400_000), by_project.series[0].total_ms);
    const posted = f.call(.POST, "/api/postings", "{\"task\":\"#2\",\"date\":\"2026-03-10\"}");
    try std.testing.expectEqual(std.http.Status.created, posted.status);
    try std.testing.expect(contains(posted.body, "\"amount_micro\":500000"));
}

test "day start moves early work to prior day and posting covers it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const midnight = (try (try zone.Zone.load("UTC")).dayBounds(2026, 3, 15)).start_ms;
    test_now = midnight + 12 * 3_600_000;
    const task = try f.store.createTask("Night work", test_now);
    f.app.provider = "fake";
    f.app.traits = parseTraits(f.arena.allocator(), "{\"sessions\":true}");
    try f.store.bind(task, "fake", "R-1", test_now);
    _ = try f.store.addInterval(task, .focus, midnight + 3_600_000, midnight + 5_400_000, test_now);
    const DayTotal = struct { numbers: Numbers };
    const before = try f.get(DayTotal, "/api/day?date=2026-03-15");
    try std.testing.expectEqual(@as(i64, 1_800_000), before.numbers.total_ms);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"day_start\":\"04:00\"}").status);
    const prior = try f.get(DayTotal, "/api/day?date=2026-03-14");
    const current = try f.get(DayTotal, "/api/day?date=2026-03-15");
    try std.testing.expectEqual(@as(i64, 1_800_000), prior.numbers.total_ms);
    try std.testing.expectEqual(@as(i64, 0), current.numbers.total_ms);
    const totals = f.call(.GET, "/api/daytotals?from=2026-03-14&to=2026-03-15", "");
    try std.testing.expectEqual(std.http.Status.ok, totals.status);
    try std.testing.expect(contains(totals.body, "\"2026-03-14\":1800000"));
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"post_sessions\":\"1\"}").status);
    const posted = f.call(.POST, "/api/postings", "{\"task\":\"#1\",\"date\":\"2026-03-14\"}");
    try std.testing.expectEqual(std.http.Status.created, posted.status);
    const rows = try query.postingsOn(&f.store, f.arena.allocator(), "2026-03-14", task);
    try std.testing.expect(rows.len > 0);
    try std.testing.expectEqual(midnight + 3_600_000, rows[0].covered_start_ms.?);
    try std.testing.expectEqual(midnight + 5_400_000, rows[rows.len - 1].covered_end_ms.?);
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
    for ([_][]const u8{ "4:00", "04:0", "12:01", "13:00", "04:60", "xx:yy" }) |bad| {
        const body = try std.fmt.allocPrint(a, "{{\"day_start\":\"{s}\"}}", .{bad});
        try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", body).status);
    }
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"day_start\":\"12:00\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"day_start\":\"00:00\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"ui_day_order\":\"newest\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"ui_day_order\":\"x\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"ui_task_order\":\"ref\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"ui_task_order\":\"id\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"ui_report_layout\":\"grid\"}").status);
    try std.testing.expectEqual(std.http.Status.ok, f.call(.PATCH, "/api/settings", "{\"ui_report_layout\":\"reader\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.PATCH, "/api/settings", "{\"ui_report_layout\":\"cards\"}").status);
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

test "capture applies an event once and names tasks like switch" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    test_now = 1_773_129_600_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"event\":\"e1\",\"kind\":\"prompt\",\"default_subject\":\"kowalski\"}").status);
    const again = f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"event\":\"e1\",\"kind\":\"prompt\",\"default_subject\":\"kowalski\"}");
    try std.testing.expect(contains(again.body, "\"applied\":false"));
    const opened = f.call(.GET, "/api/state", "");
    try std.testing.expect(contains(opened.body, "\"title\":\"kowalski\""));
    test_now += 60_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"event\":\"e2\",\"kind\":\"subject\",\"subject\":\"Issue 12\"}").status);
    try std.testing.expect(contains(f.call(.GET, "/api/state", "").body, "\"title\":\"Issue 12\""));
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"kind\":\"subject\"}").status);
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"kind\":\"nap\"}").status);
    // A field this daemon does not know yet is skipped, not refused.
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"event\":\"e3\",\"kind\":\"busy\",\"from_a_newer_hook\":\"x\"}").status);
    // A retried subject event changes nothing, not even by recreating a renamed task.
    try f.db.exec("UPDATE tasks SET title='Renamed' WHERE title='Issue 12'");
    const retried = f.call(.POST, "/api/capture", "{\"source\":\"claude\",\"run\":\"s1\",\"event\":\"e2\",\"kind\":\"subject\",\"subject\":\"Issue 12\"}");
    try std.testing.expect(contains(retried.body, "\"applied\":false"));
    var count = try f.db.prepare("SELECT count(*) FROM tasks WHERE title='Issue 12'");
    defer count.finalize();
    _ = try count.step();
    try std.testing.expectEqual(@as(i64, 0), count.columnI64(0));
}

fn historyScalar(db: *sqlite.Db, sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (try stmt.step() != .row) return error.Sqlite;
    return stmt.columnI64(0);
}

test "capture history keeps original times, focus and runs; retries and partial retries" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    test_now = 1_773_129_600_000;
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/switch", "{\"task\":\"Current\"}").status);
    const start = test_now - 3_600_000;
    const body = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r1\",\"attended\":true,\"intervals\":[{{\"event\":\"i1\",\"subject\":\"Past\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[{{\"event\":\"n1\",\"at_ms\":{d},\"text\":\"first\"}}]}},{{\"event\":\"i2\",\"subject\":\"Past\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[{{\"event\":\"n2\",\"at_ms\":{d},\"text\":\"second\"}}]}}]}}", .{ start, start + 1000, start, start + 2000, start + 3000, start + 3000 });
    const first = f.call(.POST, "/api/capture/history", body);
    try std.testing.expectEqual(std.http.Status.ok, first.status);
    try std.testing.expect(contains(first.body, "\"applied\":2"));
    try std.testing.expect(contains(first.body, "\"notes\":2"));
    try std.testing.expectEqual(@as(i64, 2), try historyScalar(&f.db, "SELECT count(*) FROM intervals WHERE end_ms IS NOT NULL AND captured=0"));
    try std.testing.expectEqual(start, try historyScalar(&f.db, "SELECT min(start_ms) FROM intervals WHERE end_ms IS NOT NULL"));
    try std.testing.expectEqual(start + 3000, try historyScalar(&f.db, "SELECT max(at_ms) FROM notes"));
    try std.testing.expectEqual(@as(i64, 2), try historyScalar(&f.db, "SELECT count(*) FROM intervals WHERE opened_by='switch' AND closed_by='stop' AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 2), try historyScalar(&f.db, "SELECT count(*) FROM notes WHERE source IS NULL"));
    try std.testing.expectEqual(@as(i64, 4), try historyScalar(&f.db, "SELECT count(*) FROM capture_events WHERE kind='history'"));
    try std.testing.expectEqual(start, try historyScalar(&f.db, "SELECT at_ms FROM capture_events WHERE event='i1'"));
    try std.testing.expectEqual(start + 3000, try historyScalar(&f.db, "SELECT at_ms FROM capture_events WHERE event='n2'"));
    try std.testing.expectEqual(@as(i64, 1), try historyScalar(&f.db, "SELECT count(*) FROM day_edits WHERE day='2026-03-10'"));
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM capture_runs"));
    try std.testing.expectEqual(@as(i64, 1), try historyScalar(&f.db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND role='focus' AND task_id=(SELECT id FROM tasks WHERE title='Current')"));
    const again = f.call(.POST, "/api/capture/history", body);
    try std.testing.expectEqual(std.http.Status.ok, again.status);
    try std.testing.expect(contains(again.body, "\"applied\":0"));
    try std.testing.expect(contains(again.body, "\"skipped\":2"));
    try std.testing.expectEqual(@as(i64, 3), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
    const partial = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r1\",\"intervals\":[{{\"event\":\"i1\",\"subject\":\"Renamed\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}},{{\"event\":\"i3\",\"subject\":\"Past\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ start, start + 1000, start + 4000, start + 5000 });
    const mixed = f.call(.POST, "/api/capture/history", partial);
    try std.testing.expectEqual(std.http.Status.ok, mixed.status);
    try std.testing.expect(contains(mixed.body, "\"applied\":1"));
    try std.testing.expect(contains(mixed.body, "\"skipped\":1"));
    try std.testing.expectEqual(@as(i64, 4), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM tasks WHERE title='Renamed'"));
}

test "capture history rejects overlap atomically and validates times" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    test_now = 1_773_129_600_000;
    _ = try f.store.createTask("Manual", test_now);
    const start = test_now - 3_600_000;
    try std.testing.expectEqual(std.http.Status.created, f.call(.POST, "/api/intervals", try std.fmt.allocPrint(a, "{{\"task\":\"#1\",\"start_ms\":{d},\"end_ms\":{d}}}", .{ start, start + 1000 })).status);
    const existing = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"ok\",\"subject\":\"New\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}},{{\"event\":\"bad\",\"subject\":\"#1\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ start + 2000, start + 3000, start + 500, start + 1500 });
    const conflict = f.call(.POST, "/api/capture/history", existing);
    try std.testing.expectEqual(std.http.Status.conflict, conflict.status);
    try std.testing.expect(contains(conflict.body, "\"interval\":1"));
    try std.testing.expect(contains(conflict.body, "overlap"));
    try std.testing.expectEqual(@as(i64, 1), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM capture_events"));
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM tasks WHERE title='New'"));
    const within = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"a\",\"subject\":\"Other\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}},{{\"event\":\"b\",\"subject\":\"Other\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ start + 2000, start + 4000, start + 3000, start + 5000 });
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/capture/history", within).status);
    try std.testing.expectEqual(@as(i64, 1), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM capture_events"));
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/switch", "{\"task\":\"Open\"}").status);
    const open = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"c\",\"subject\":\"Open\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ test_now, test_now + 1 });
    test_now += 1000;
    try std.testing.expectEqual(std.http.Status.conflict, f.call(.POST, "/api/capture/history", open).status);
    try std.testing.expectEqual(@as(i64, 2), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
    const future = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"d\",\"subject\":\"Other\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ test_now - 1, test_now + 1 });
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/capture/history", future).status);
    const outside = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"e\",\"subject\":\"Other\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[{{\"event\":\"ne\",\"at_ms\":{d},\"text\":\"outside\"}}]}}]}}", .{ start + 2000, start + 3000, start + 3001 });
    try std.testing.expectEqual(std.http.Status.bad_request, f.call(.POST, "/api/capture/history", outside).status);
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM capture_events"));
    const empty = f.call(.POST, "/api/capture/history", "{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[]}");
    try std.testing.expectEqual(std.http.Status.ok, empty.status);
    try std.testing.expect(contains(empty.body, "\"applied\":0"));
    try std.testing.expectEqual(@as(i64, 2), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
}

test "capture history blocks posted reporting days only for that task" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    test_now = 1_773_129_600_000;
    _ = try f.store.createTask("Posted", test_now);
    const start = test_now - 3_600_000;
    try f.db.exec("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms) VALUES('2026-03-10',1,'test','one','confirmed','1',1000000,1)");
    const posted = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"p\",\"subject\":\"#1\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ start, start + 1000 });
    const rejected = f.call(.POST, "/api/capture/history", posted);
    try std.testing.expectEqual(std.http.Status.conflict, rejected.status);
    try std.testing.expect(contains(rejected.body, "posted"));
    try std.testing.expectEqual(@as(i64, 0), try historyScalar(&f.db, "SELECT count(*) FROM capture_events"));
    const other = try std.fmt.allocPrint(a, "{{\"source\":\"agent\",\"run\":\"r\",\"intervals\":[{{\"event\":\"q\",\"subject\":\"Other\",\"start_ms\":{d},\"end_ms\":{d},\"notes\":[]}}]}}", .{ start, start + 1000 });
    try std.testing.expectEqual(std.http.Status.ok, f.call(.POST, "/api/capture/history", other).status);
    try std.testing.expectEqual(@as(i64, 1), try historyScalar(&f.db, "SELECT count(*) FROM intervals"));
}
