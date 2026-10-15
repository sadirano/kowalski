//! The guided tour's sandbox: the real engine on a throwaway database filled
//! with made-up history, and an example provider that answers in-process.
//! The dashboard reaches it under /tour/api/; the user's own database, and
//! any session running in it, are never touched.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const store_mod = @import("store.zig");
const api = @import("api.zig");
const demo = @import("demo.zig");
const zone_mod = @import("zone.zig");
const k = @import("kowalski_provider");

pub const file_name = "tour.db";

/// The binding namespace of the tour's provider.
pub const instance = "example";

pub const Tour = struct {
    gpa: std.mem.Allocator,
    path: []u8,
    db: sqlite.Db = .{},
    store: store_mod.Store = undefined,
    app: api.App = undefined,
    table: k.Table = undefined,
    lang: demo.Lang,
    traits_arena: std.heap.ArenaAllocator,

    /// A fresh sandbox at `path` (any old one there is replaced), set up
    /// like the user's own: the settings in `copied_settings` come from `user`.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, path: []const u8, lang: demo.Lang, user: *store_mod.Store, port: u16, clock: *const fn () i64) !*Tour {
        removeFiles(io, path);
        const t = try gpa.create(Tour);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .path = try gpa.dupe(u8, path), .lang = lang, .traits_arena = .init(gpa) };
        errdefer gpa.free(t.path);
        errdefer t.traits_arena.deinit();
        try t.db.open(path);
        errdefer t.db.close();
        t.store = try store_mod.Store.init(&t.db, gpa);
        const now = clock();
        try copySettings(user, &t.store, now);
        // Pausing on screen lock belongs to the real tracker only.
        try t.store.setSetting("lock_pause", "", now);
        const zone_id = (try t.store.reportingZone()) orelse zone: {
            const id = try zone_mod.currentId(gpa);
            errdefer gpa.free(id);
            try t.store.setSetting("reporting_zone", id, now);
            break :zone id;
        };
        defer gpa.free(zone_id);
        const zone = try zone_mod.Zone.load(zone_id);
        try demo.seed(&t.db, gpa, .{ .lang = lang, .instance = instance, .now_ms = now, .zone = &zone });
        try t.store.onStart(now);
        t.table = .{
            .version = k.version,
            .instance = .of(instance),
            .traits = .of(traits),
            .context = t,
            .fields = fields,
            .lookup = lookup,
            .quote = quote,
            .post = post,
            .login_prompts = loginPrompts,
            .login = login,
            .free = free,
            .init = init,
            .deinit = deinit,
        };
        t.app = .{ .store = &t.store, .port = port, .clock = clock, .provider = instance };
        t.app.traits = api.parseTraits(t.traits_arena.allocator(), traits);
        return t;
    }

    pub fn destroy(t: *Tour, io: std.Io) void {
        t.db.close();
        removeFiles(io, t.path);
        t.traits_arena.deinit();
        t.gpa.free(t.path);
        t.gpa.destroy(t);
    }
};

/// What the tour takes from the user's settings, so it looks like their
/// dashboard. Left out: the port, the language (the tour picks it), the
/// provider-specific chart groups, lock pausing, and the collapsed sidebar
/// and hidden chart, which would hide what the flows point at.
pub const copied_settings = [_][]const u8{
    "reporting_zone",    "daily_work_minutes", "lunch_minutes",     "paid_breaks",
    "ui_day_order",      "ui_sidebar_days",    "ui_hide_weekends",  "ui_show_keys",
    "ui_show_add_entry", "ui_chart_days",      "ui_summary_format", "ui_autofill_obs",
    "ui_links",          "ui_time_format",     "ui_chart_view",      "ui_single_keys",
    "ui_task_order",     "ui_report_layout",
};

fn copySettings(from: *store_mod.Store, to: *store_mod.Store, now_ms: i64) !void {
    var values: [copied_settings.len]?[]u8 = @splat(null);
    defer for (values) |v| if (v) |x| from.allocator.free(x);
    var batch: [copied_settings.len]store_mod.Store.SettingChange = undefined;
    var n: usize = 0;
    for (copied_settings, 0..) |key, i| {
        values[i] = try from.getSetting(key);
        if (values[i]) |v| {
            batch[n] = .{ .key = key, .value = v };
            n += 1;
        }
    }
    try to.setSettings(batch[0..n], now_ms);
}

/// Removes a sandbox database and its journal files, if present.
pub fn removeFiles(io: std.Io, path: []const u8) void {
    if (std.mem.eql(u8, path, ":memory:")) return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm", "-journal" }) |suffix| {
        const name = std.fmt.bufPrint(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        std.Io.Dir.cwd().deleteFile(io, name) catch {};
    }
}

const traits = "{\"link\":\"https://tickets.example/{ref}\",\"paid_breaks\":[{\"from\":\"08:00\",\"to\":\"12:00\",\"minutes\":15},{\"from\":\"13:00\",\"to\":\"18:00\",\"minutes\":15}]}";

const allocator = std.heap.page_allocator;

/// The tour is built in: the daemon sets its context and calls neither.
fn init(context: ?*anyopaque, _: k.Bytes, out_context: *?*anyopaque) callconv(.c) k.Status {
    out_context.* = context;
    return .{};
}

fn deinit(_: ?*anyopaque) callconv(.c) void {}

fn give(text: []const u8, out: *k.Bytes) bool {
    const copy = allocator.dupe(u8, text) catch return false;
    out.* = .of(copy);
    return true;
}

fn outOfMemory() k.Status {
    return .{ .code = 1, .retry_safe = 1 };
}

fn tourOf(context: ?*anyopaque) *Tour {
    return @ptrCast(@alignCast(context.?));
}

fn fields(_: ?*anyopaque, out: *k.Bytes) callconv(.c) k.Status {
    const json =
        \\[{"name":"Client","label":"Client","labels":{"pt":"Cliente","ja":"顧客"},"type":"text","order":1},
        \\{"name":"System","label":"System","labels":{"pt":"Sistema","ja":"システム"},"type":"text","order":2},
        \\{"name":"Situation","label":"Situation","labels":{"pt":"Situação","ja":"状況"},"type":"text","order":3}]
    ;
    if (!give(json, out)) return outOfMemory();
    return .{};
}

/// Any ref is a ticket: a sample task's ref gets its title, any other a
/// made-up one, so the tour can start a task with whatever the user types.
fn lookup(context: ?*anyopaque, ref: k.Bytes, out: *k.Bytes) callconv(.c) k.Status {
    const t = tourOf(context);
    const text = demo.texts.getPtrConst(t.lang);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const title = std.fmt.allocPrint(a, "{s} {s}", .{ text.ticket, ref.slice() }) catch return outOfMemory();
    const json = std.json.Stringify.valueAlloc(a, .{ .title = title, .fields = .{ .Client = "Northwind", .System = text.systems[0], .Situation = text.situations[0] } }, .{}) catch return outOfMemory();
    if (!give(json, out)) return outOfMemory();
    return .{};
}

/// Hours to two decimals, rounded up; only the unposted difference is quoted.
fn quote(_: ?*anyopaque, request: k.Bytes, out: *k.Bytes) callconv(.c) k.Status {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct { total_focus_ms: i64, posted: []struct { amount_micro: i64 } };
    const input = std.json.parseFromSliceLeaky(Input, a, request.slice(), .{ .ignore_unknown_fields = true }) catch return .{ .code = 1 };
    const hundredths: i64 = @divFloor(input.total_focus_ms + 36_000 - 1, 36_000);
    var posted_micro: i64 = 0;
    for (input.posted) |p| posted_micro += p.amount_micro;
    const micro = @max(0, hundredths * 10_000 - posted_micro);
    var buffer: [32]u8 = undefined;
    const printed = std.fmt.bufPrint(&buffer, "{d}.{d:0>2}", .{ @divFloor(micro, 1_000_000), @divFloor(@mod(micro, 1_000_000), 10_000) }) catch unreachable;
    const json = std.json.Stringify.valueAlloc(a, .{ .post = micro > 0, .reason = if (micro > 0) "" else "already posted", .amount_text = printed, .amount_micro = micro }, .{}) catch return outOfMemory();
    if (!give(json, out)) return outOfMemory();
    return .{};
}

fn post(_: ?*anyopaque, _: k.Bytes, out: *k.Bytes) callconv(.c) k.Status {
    if (!give("{\"data\":{\"tour\":true}}", out)) return .{ .code = 1, .outcome_known = 0 };
    return .{};
}

fn loginPrompts(_: ?*anyopaque, out: *k.Bytes) callconv(.c) k.Status {
    const json =
        \\[{"name":"user","label":"User","labels":{"pt":"Usuário","ja":"ユーザー"},"secret":false},
        \\{"name":"password","label":"Password","labels":{"pt":"Senha","ja":"パスワード"},"secret":true}]
    ;
    if (!give(json, out)) return outOfMemory();
    return .{};
}

/// Accepts any answers and keeps none of them.
fn login(_: ?*anyopaque, answers: k.Bytes) callconv(.c) k.Status {
    return if (answers.slice().len > 0) .{} else .{ .code = 1 };
}

fn free(_: ?*anyopaque, buffer: k.Bytes) callconv(.c) void {
    allocator.free(@constCast(buffer.slice()));
}

var test_now: i64 = 0;
fn testClock() i64 {
    return test_now;
}

test "a tour serves made-up days through the real API and its own provider" {
    const worker = @import("worker.zig");
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const zone_id = try zone_mod.currentId(gpa);
    defer gpa.free(zone_id);
    const zone = try zone_mod.Zone.load(zone_id);
    test_now = (try zone.dayBounds(2026, 10, 9)).start_ms + 15 * 3_600_000;
    var user_db: sqlite.Db = .{};
    try user_db.open(":memory:");
    defer user_db.close();
    var user = try store_mod.Store.init(&user_db, gpa);
    try user.setSetting("reporting_zone", zone_id, 0);
    try user.setSetting("daily_work_minutes", "420", 0);
    try user.setSetting("http_port", "47200", 0);
    try user.setSetting("ui_time_format", "12", 0);
    try user.setSetting("ui_left_collapsed", "1", 0);
    try user.setSetting("lock_pause", "17:00-23:59", 0);
    const t = try Tour.create(gpa, io, ":memory:", .pt, &user, 47100, testClock);
    defer t.destroy(io);

    // The user's settings come along; their port does not.
    const daily = (try t.store.getSetting("daily_work_minutes")).?;
    defer gpa.free(daily);
    try std.testing.expectEqualStrings("420", daily);
    try std.testing.expectEqual(null, try t.store.getSetting("http_port"));
    try std.testing.expectEqual(null, try t.store.getSetting("ui_left_collapsed"));
    const format = (try t.store.getSetting("ui_time_format")).?;
    defer gpa.free(format);
    try std.testing.expectEqualStrings("12", format);
    const lock = (try t.store.getSetting("lock_pause")).?;
    defer gpa.free(lock);
    try std.testing.expectEqualStrings("", lock);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var days = api.handle(&t.app, a, .{ .method = .GET, .target = "/api/days?n=7", .host = "127.0.0.1:47100" });
    while (days.followup) |next| days = api.proceed(&t.app, a, next, try worker.runInline(&t.table, a, next.call()));
    try std.testing.expectEqual(std.http.Status.ok, days.status);
    try std.testing.expect(std.mem.indexOf(u8, days.body, "\"total_ms\"") != null);

    // A lookup goes to the tour's own provider, in the tour's language.
    var r = api.handle(&t.app, a, .{ .method = .GET, .target = "/api/lookup?ref=777", .host = "127.0.0.1:47100" });
    while (r.followup) |next| r = api.proceed(&t.app, a, next, try worker.runInline(&t.table, a, next.call()));
    try std.testing.expectEqual(std.http.Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "Chamado de exemplo 777") != null);
}
