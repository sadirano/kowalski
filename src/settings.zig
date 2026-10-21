//! Every key kowalski keeps in its settings table, declared once with its
//! kind and the values it takes. docs/settings.md holds the rules.
const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    /// Behaviour: how time is counted, captured, posted or updated.
    setting,
    /// How a view looks; changed beside the view, not in the dialog.
    preference,
    /// What the dashboard remembers; never shown.
    state,
    /// Only for tests and development; absent from release builds.
    dev,
};

pub const Rule = union(enum) {
    /// The store checks it (zones, times, minutes, ports, windows).
    store,
    /// "0" or "1".
    flag,
    choice: []const []const u8,
    /// A count of days, 1 to 90.
    days,
    /// A width in pixels, 120 to 4000.
    width,
    /// A JSON list of names, up to 1024 bytes.
    names,
    /// Checked by the API against the provider or a parser.
    custom,
};

pub const Decl = struct { key: []const u8, kind: Kind, rule: Rule };

const all = [_]Decl{
    // Workday.
    .{ .key = "daily_work_minutes", .kind = .setting, .rule = .store },
    .{ .key = "lunch_minutes", .kind = .setting, .rule = .store },
    // "08:00-12:00=15,13:00-18:00=15", overriding the provider's; empty is none.
    .{ .key = "paid_breaks", .kind = .setting, .rule = .custom },
    // Windows where a screen lock pauses: "17:00-23:59"; empty is none.
    .{ .key = "lock_pause", .kind = .setting, .rule = .store },
    // Day and time zone.
    .{ .key = "reporting_zone", .kind = .setting, .rule = .store },
    .{ .key = "day_start", .kind = .setting, .rule = .store },
    // Capture.
    .{ .key = "capture_text", .kind = .setting, .rule = .{ .choice = &.{ "keep", "time" } } },
    // Sources whose working run keeps the focus against other runs' prompts,
    // such as a game the user plays: "src1,src2"; empty is none.
    .{ .key = "capture_hold_sources", .kind = .setting, .rule = .store },
    // Origins allowed to post captures, such as a browser extension:
    // "chrome-extension://<id>,..."; empty is none.
    .{ .key = "capture_origins", .kind = .setting, .rule = .store },
    // Posting.
    .{ .key = "post_sessions", .kind = .setting, .rule = .flag },
    .{ .key = "post_daily_notes", .kind = .setting, .rule = .flag },
    // Updates and service.
    .{ .key = "update_channel", .kind = .setting, .rule = .{ .choice = &.{ "stable", "preview" } } },
    .{ .key = "open_on_launch", .kind = .setting, .rule = .flag },
    .{ .key = "http_port", .kind = .setting, .rule = .store },
    // Projects.
    .{ .key = "project_provider_field", .kind = .setting, .rule = .custom },
    // Display, across every view.
    .{ .key = "ui_lang", .kind = .preference, .rule = .{ .choice = &.{ "en", "pt", "ja" } } },
    .{ .key = "ui_time_format", .kind = .preference, .rule = .{ .choice = &.{ "system", "24", "12" } } },
    .{ .key = "ui_links", .kind = .preference, .rule = .flag },
    .{ .key = "ui_single_keys", .kind = .preference, .rule = .flag },
    .{ .key = "ui_show_keys", .kind = .preference, .rule = .flag },
    .{ .key = "ui_show_add_entry", .kind = .preference, .rule = .flag },
    // Sidebar.
    .{ .key = "ui_day_order", .kind = .preference, .rule = .{ .choice = &.{ "oldest", "newest" } } },
    .{ .key = "ui_sidebar_days", .kind = .preference, .rule = .days },
    .{ .key = "ui_show_weekends", .kind = .preference, .rule = .flag },
    // Report.
    .{ .key = "ui_report_layout", .kind = .preference, .rule = .{ .choice = &.{ "classic", "grid" } } },
    .{ .key = "ui_task_order", .kind = .preference, .rule = .{ .choice = &.{ "time", "ref", "added" } } },
    // Chart.
    .{ .key = "ui_chart_view", .kind = .preference, .rule = .{ .choice = &.{ "bars", "lanes" } } },
    .{ .key = "ui_chart_days", .kind = .preference, .rule = .days },
    // Provider fields kept off the chart tabs.
    .{ .key = "ui_chart_hidden", .kind = .preference, .rule = .names },
    // Summary.
    .{ .key = "ui_summary_format", .kind = .preference, .rule = .{ .choice = &.{ "grouped", "chronological" } } },
    // Remembered by the dashboard.
    .{ .key = "ui_left_collapsed", .kind = .state, .rule = .flag },
    .{ .key = "ui_chart_visible", .kind = .state, .rule = .flag },
    .{ .key = "ui_tour_offered", .kind = .state, .rule = .flag },
    .{ .key = "ui_left_width", .kind = .state, .rule = .width },
    .{ .key = "ui_reader_width", .kind = .state, .rule = .width },
};

/// The keys a build of this mode knows: dev keys only outside release builds.
pub fn declared(comptime mode: std.builtin.OptimizeMode, comptime list: []const Decl) []const Decl {
    comptime {
        var keep: []const Decl = &.{};
        for (list) |d| {
            if (d.kind == .dev and mode != .debug) continue;
            keep = keep ++ [_]Decl{d};
        }
        return keep;
    }
}

pub const decls = declared(builtin.mode, &all);

pub fn find(key: []const u8) ?Decl {
    for (decls) |d| if (std.mem.eql(u8, d.key, key)) return d;
    return null;
}

/// Whether a value passes the key's own rule; store and custom rules pass
/// here and are checked by their owners.
pub fn valid(d: Decl, value: []const u8) bool {
    return switch (d.rule) {
        .store, .custom => true,
        .flag => std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "1"),
        .choice => |values| for (values) |v| {
            if (std.mem.eql(u8, value, v)) break true;
        } else false,
        .days => blk: {
            const n = std.fmt.parseInt(u16, value, 10) catch break :blk false;
            break :blk n >= 1 and n <= 90;
        },
        .width => blk: {
            const n = std.fmt.parseInt(u16, value, 10) catch break :blk false;
            break :blk n >= 120 and n <= 4000;
        },
        .names => blk: {
            if (value.len > 1024) break :blk false;
            var buffer: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buffer);
            _ = std.json.parseFromSliceLeaky([]const []const u8, fba.allocator(), value, .{}) catch break :blk false;
            break :blk true;
        },
    };
}

test "a release build declares no dev key" {
    const sample = [_]Decl{
        .{ .key = "kept", .kind = .setting, .rule = .flag },
        .{ .key = "dev_only", .kind = .dev, .rule = .flag },
    };
    inline for (.{ .safe, .fast, .small }) |mode| {
        const list = comptime declared(mode, &sample);
        try std.testing.expectEqual(@as(usize, 1), list.len);
        for (comptime declared(mode, &all)) |d| try std.testing.expect(d.kind != .dev);
    }
    try std.testing.expectEqual(@as(usize, 2), (comptime declared(.debug, &sample)).len);
}

test "every key is declared once and ui_ marks only preferences and state" {
    for (all, 0..) |d, i| {
        for (all[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, d.key, other.key));
        const ui = std.mem.startsWith(u8, d.key, "ui_");
        try std.testing.expectEqual(ui, d.kind == .preference or d.kind == .state);
    }
}

test "values follow their rule" {
    try std.testing.expect(valid(find("ui_show_weekends").?, "1"));
    try std.testing.expect(!valid(find("ui_show_weekends").?, "yes"));
    try std.testing.expect(valid(find("capture_text").?, "time"));
    try std.testing.expect(!valid(find("capture_text").?, "none"));
    try std.testing.expect(!valid(find("ui_sidebar_days").?, "91"));
    try std.testing.expect(valid(find("ui_left_width").?, "260"));
    try std.testing.expect(!valid(find("ui_chart_hidden").?, "nope"));
    try std.testing.expect(find("ui_hide_weekends") == null);
}
