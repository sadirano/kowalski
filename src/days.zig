const std = @import("std");
const store_mod = @import("store.zig");
const max_time_ms = store_mod.max_time_ms;

pub const Schedule = struct {
    daily_work_minutes: i64 = 510,
    lunch_minutes: i64 = 60,
    /// Paid breaks of this day, as the provider allows them: a pause inside
    /// a window is credited as worked time, up to `allow_ms` per window.
    paid: []const PaidWindow = &.{},
    /// Recorded lunch breaks overlapping the day; never credited.
    lunches: []const Span = &.{},
};

pub const PaidWindow = struct { start_ms: i64, end_ms: i64, allow_ms: i64 };
pub const Span = struct { start_ms: i64, end_ms: i64 };

fn overlap(a_start: i64, a_end: i64, b_start: i64, b_end: i64) i64 {
    return @max(0, @min(a_end, b_end) - @max(a_start, b_start));
}

pub const TaskNumbers = struct {
    task_id: i64,
    focus_ms: i64,
    hops: u32,
};

pub const DayNumbers = struct {
    /// Focus time only.
    total_ms: i64,
    /// Paid break time credited toward the day's target (not to any task).
    paid_break_ms: i64 = 0,
    hops: u32,
    tasks: []TaskNumbers,
    first_start_ms: ?i64,
    working: bool,
    remaining_ms: i64,
    clock_out_ms: ?i64,
    expected_return_ms: ?i64,
    earliest_clock_out_ms: ?i64,

    pub fn deinit(d: *DayNumbers, allocator: std.mem.Allocator) void {
        allocator.free(d.tasks);
    }
};

pub fn dayNumbers(store: *store_mod.Store, allocator: std.mem.Allocator, day_start_ms: i64, day_end_ms: i64, now_ms: i64, schedule: Schedule) !DayNumbers {
    if (day_start_ms < 0 or day_start_ms >= max_time_ms or day_end_ms < 0 or day_end_ms >= max_time_ms or now_ms < 0 or now_ms >= max_time_ms) return error.InvalidTime;
    if (day_end_ms <= day_start_ms or schedule.daily_work_minutes < 1 or schedule.daily_work_minutes > 1440 or schedule.lunch_minutes < 0 or schedule.lunch_minutes > 600) return error.InvalidSchedule;
    var tasks: std.ArrayList(TaskNumbers) = .empty;
    errdefer tasks.deinit(allocator);
    var result: DayNumbers = .{
        .total_ms = 0,
        .hops = 0,
        .tasks = undefined,
        .first_start_ms = null,
        .working = false,
        .remaining_ms = 0,
        .clock_out_ms = null,
        .expected_return_ms = null,
        .earliest_clock_out_ms = null,
    };
    var last_end: ?i64 = null;
    var previous_task: ?i64 = null;
    // Pause time per paid window, lunch excluded.
    var paused: [8]i64 = @splat(0);
    const windows = schedule.paid[0..@min(schedule.paid.len, paused.len)];
    var stmt = try store.db.prepare("SELECT task_id,start_ms,end_ms,opened_by FROM intervals WHERE role='focus' AND start_ms<?1 AND (end_ms IS NULL OR end_ms>?2 OR start_ms>=?2) ORDER BY start_ms,id");
    defer stmt.finalize();
    try stmt.bindI64(1, day_end_ms);
    try stmt.bindI64(2, day_start_ms);
    while (try stmt.step() == .row) {
        const task_id = stmt.columnI64(0);
        const start = stmt.columnI64(1);
        const open = stmt.columnIsNull(2);
        const raw_end = if (open) @min(now_ms, day_end_ms) else @min(stmt.columnI64(2), day_end_ms);
        const clamped_start = @max(start, day_start_ms);
        if (raw_end < clamped_start) continue;
        var index: ?usize = null;
        for (tasks.items, 0..) |item, i| {
            if (item.task_id == task_id) {
                index = i;
                break;
            }
        }
        const had_earlier = index != null;
        if (index == null) {
            try tasks.append(allocator, .{ .task_id = task_id, .focus_ms = 0, .hops = 0 });
            index = tasks.items.len - 1;
        }
        if (result.first_start_ms == null) result.first_start_ms = clamped_start;
        if (last_end) |end| if (clamped_start > end) countPause(windows, &paused, schedule.lunches, end, clamped_start);
        last_end = if (last_end) |end| @max(end, raw_end) else raw_end;
        const reason = std.meta.stringToEnum(store_mod.OpenedBy, stmt.columnText(3).?) orelse return error.InvalidState;
        if (start >= day_start_ms and (reason == .@"switch" or reason == .import) and had_earlier and previous_task != null and previous_task.? != task_id) {
            tasks.items[index.?].hops += 1;
            result.hops += 1;
        }
        previous_task = task_id;
        if (open and start <= now_ms and now_ms >= day_start_ms and now_ms < day_end_ms) result.working = true;
        if (raw_end == clamped_start) continue;
        const duration = raw_end - clamped_start;
        tasks.items[index.?].focus_ms = try std.math.add(i64, tasks.items[index.?].focus_ms, duration);
        result.total_ms = try std.math.add(i64, result.total_ms, duration);
    }
    // Paid time inside the gaps before the last end; a running pause adds to
    // the credit below but is no part of the break already taken.
    var paid_before_ms: i64 = 0;
    for (windows, 0..) |w, i| paid_before_ms += @min(w.allow_ms, paused[i]);
    // A pause still running today counts as it goes.
    if (last_end) |end| if (!result.working and now_ms > end and now_ms >= day_start_ms and now_ms < day_end_ms)
        countPause(windows, &paused, schedule.lunches, end, now_ms);
    for (windows, 0..) |w, i| result.paid_break_ms += @min(w.allow_ms, paused[i]);
    const target_ms = schedule.daily_work_minutes * 60_000;
    const lunch_ms = schedule.lunch_minutes * 60_000;
    result.remaining_ms = @max(0, target_ms - result.total_ms - result.paid_break_ms);
    if (result.first_start_ms) |first| {
        const min_out = first + target_ms + lunch_ms;
        if (result.working) {
            result.clock_out_ms = @max(now_ms + result.remaining_ms, min_out);
        } else {
            const end = last_end.?;
            const break_taken = end - first - result.total_ms - paid_before_ms;
            const expected_return = if (break_taken < lunch_ms) end + lunch_ms - break_taken else end;
            result.expected_return_ms = expected_return;
            result.earliest_clock_out_ms = @max(@max(now_ms, expected_return) + result.remaining_ms, min_out);
        }
    }
    result.tasks = try tasks.toOwnedSlice(allocator);
    return result;
}

/// Adds the part of the pause [start, end) inside each window, minus lunch.
fn countPause(windows: []const PaidWindow, paused: []i64, lunches: []const Span, start: i64, end: i64) void {
    for (windows, 0..) |w, i| {
        var part = overlap(start, end, w.start_ms, w.end_ms);
        if (part == 0) continue;
        for (lunches) |l| part -= overlap(@max(start, w.start_ms), @min(end, w.end_ms), l.start_ms, l.end_ms);
        paused[i] += @max(0, part);
    }
}

fn fixtureInterval(db: *store_mod.Store, task: i64, role: store_mod.Role, start: i64, end: ?i64, opened: store_mod.OpenedBy) !void {
    var stmt = try db.db.prepare("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by) VALUES(?1,?2,?3,?4,?5,?6)");
    defer stmt.finalize();
    try stmt.bindI64(1, task);
    try stmt.bindText(2, @tagName(role));
    try stmt.bindI64(3, start);
    if (end) |value| try stmt.bindI64(4, value) else try stmt.bindNull(4);
    try stmt.bindText(5, @tagName(opened));
    if (end != null) try stmt.bindText(6, "import") else try stmt.bindNull(6);
    _ = try stmt.step();
}

test "day bounds split focus and exclude parallel" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const a = try store.createTask("A", 1);
    const b = try store.createTask("B", 2);
    const c = try store.createTask("C", 3);
    const hour: i64 = 3_600_000;
    const day: i64 = 24 * hour;
    try fixtureInterval(&store, a, .focus, 23 * hour, day + hour, .import);
    try fixtureInterval(&store, b, .parallel, 12 * hour, day + 4 * hour, .parallel);
    try fixtureInterval(&store, c, .focus, day + 2 * hour, null, .@"switch");
    var first = try dayNumbers(&store, std.testing.allocator, 0, day, day + 3 * hour, .{});
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(hour, first.total_ms);
    try std.testing.expectEqual(@as(usize, 1), first.tasks.len);
    try std.testing.expectEqual(a, first.tasks[0].task_id);
    try std.testing.expect(!first.working);
    var second = try dayNumbers(&store, std.testing.allocator, day, 2 * day, day + 3 * hour, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(2 * hour, second.total_ms);
    try std.testing.expectEqual(@as(usize, 2), second.tasks.len);
    try std.testing.expectEqual(a, second.tasks[0].task_id);
    try std.testing.expectEqual(c, second.tasks[1].task_id);
    try std.testing.expectEqual(hour, second.tasks[0].focus_ms);
    try std.testing.expectEqual(hour, second.tasks[1].focus_ms);
    try std.testing.expectEqual(@as(u32, 0), second.hops);
    try std.testing.expect(second.working);
}

test "hops follow explicit return switches only" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const a = try store.createTask("A", 1);
    const b = try store.createTask("B", 2);
    const hour: i64 = 3_600_000;
    const day: i64 = 24 * hour;
    try fixtureInterval(&store, a, .focus, 9 * hour, 10 * hour, .@"switch");
    try fixtureInterval(&store, b, .focus, 10 * hour, 11 * hour, .@"switch");
    try fixtureInterval(&store, a, .focus, 11 * hour, 12 * hour, .@"switch");
    try fixtureInterval(&store, a, .focus, day + 9 * hour, day + 10 * hour, .@"switch");
    try fixtureInterval(&store, a, .focus, day + 11 * hour, day + 12 * hour, .@"resume");
    try fixtureInterval(&store, a, .focus, 2 * day + 9 * hour, 2 * day + 10 * hour, .@"switch");
    try fixtureInterval(&store, a, .focus, 2 * day + 11 * hour, 2 * day + 12 * hour, .@"switch");
    try fixtureInterval(&store, a, .focus, 3 * day + 9 * hour, 3 * day + 10 * hour, .@"switch");
    try fixtureInterval(&store, b, .focus, 3 * day + 10 * hour, 3 * day + 11 * hour, .@"switch");
    try fixtureInterval(&store, b, .focus, 3 * day + 12 * hour, 3 * day + 13 * hour, .@"resume");
    try fixtureInterval(&store, a, .focus, 3 * day + 13 * hour, 3 * day + 14 * hour, .@"switch");
    const expected = [_]u32{ 1, 0, 0, 1 };
    for (expected, 0..) |hops, i| {
        const start: i64 = @as(i64, @intCast(i)) * day;
        var numbers = try dayNumbers(&store, std.testing.allocator, start, start + day, start + 20 * hour, .{});
        defer numbers.deinit(std.testing.allocator);
        try std.testing.expectEqual(hops, numbers.hops);
        try std.testing.expectEqual(hops, numbers.tasks[0].hops);
    }
}

test "schedule while working and on a lunch break" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const a = try store.createTask("A", 1);
    const hour: i64 = 3_600_000;
    const day: i64 = 24 * hour;
    const minute: i64 = 60_000;
    var empty = try dayNumbers(&store, std.testing.allocator, 0, day, 8 * hour, .{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?i64, null), empty.first_start_ms);
    try std.testing.expectEqual(@as(?i64, null), empty.clock_out_ms);
    try std.testing.expectEqual(@as(?i64, null), empty.earliest_clock_out_ms);
    try fixtureInterval(&store, a, .focus, 9 * hour, null, .@"switch");
    var working = try dayNumbers(&store, std.testing.allocator, 0, day, 12 * hour, .{});
    defer working.deinit(std.testing.allocator);
    try std.testing.expectEqual(3 * hour, working.total_ms);
    try std.testing.expectEqual(330 * minute, working.remaining_ms);
    try std.testing.expectEqual(@as(?i64, 18 * hour + 30 * minute), working.clock_out_ms);
    try db.exec("UPDATE intervals SET end_ms=43200000,closed_by='pause' WHERE end_ms IS NULL");
    var paused = try dayNumbers(&store, std.testing.allocator, 0, day, 12 * hour + 20 * minute, .{});
    defer paused.deinit(std.testing.allocator);
    try std.testing.expect(!paused.working);
    try std.testing.expectEqual(@as(?i64, 13 * hour), paused.expected_return_ms);
    try std.testing.expectEqual(@as(?i64, 18 * hour + 30 * minute), paused.earliest_clock_out_ms);
}

test "open focus starting now counts as working" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const a = try store.createTask("A", 0);
    try fixtureInterval(&store, a, .focus, 1_000, null, .@"switch");
    var numbers = try dayNumbers(&store, std.testing.allocator, 0, 86_400_000, 1_000, .{});
    defer numbers.deinit(std.testing.allocator);
    try std.testing.expect(numbers.working);
    try std.testing.expectEqual(@as(?i64, 1_000), numbers.first_start_ms);
    try std.testing.expectEqual(@as(i64, 0), numbers.total_ms);
}

test "zero-length focus switch contributes to return hop" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const a = try store.createTask("A", 0);
    const b = try store.createTask("B", 0);
    try fixtureInterval(&store, a, .focus, 100, 200, .@"switch");
    try fixtureInterval(&store, b, .focus, 200, 200, .@"switch");
    try fixtureInterval(&store, a, .focus, 200, 300, .@"switch");
    var numbers = try dayNumbers(&store, std.testing.allocator, 0, 86_400_000, 300, .{});
    defer numbers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), numbers.hops);
    try std.testing.expectEqual(@as(u32, 1), numbers.tasks[0].hops);
    try std.testing.expectEqual(@as(usize, 2), numbers.tasks.len);
    try std.testing.expectEqual(@as(i64, 0), numbers.tasks[1].focus_ms);
    try std.testing.expectEqual(@as(i64, 200), numbers.total_ms);
}

test "day numbers reject schedule and time outside supported ranges" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const limit: i64 = 253_402_300_800_000;
    try std.testing.expectError(error.InvalidSchedule, dayNumbers(&store, std.testing.allocator, 0, 1_000, 500, .{ .daily_work_minutes = 0 }));
    try std.testing.expectError(error.InvalidSchedule, dayNumbers(&store, std.testing.allocator, 0, 1_000, 500, .{ .daily_work_minutes = 1441 }));
    try std.testing.expectError(error.InvalidSchedule, dayNumbers(&store, std.testing.allocator, 0, 1_000, 500, .{ .lunch_minutes = -1 }));
    try std.testing.expectError(error.InvalidSchedule, dayNumbers(&store, std.testing.allocator, 0, 1_000, 500, .{ .lunch_minutes = 601 }));
    try std.testing.expectError(error.InvalidSchedule, dayNumbers(&store, std.testing.allocator, 1_000, 1_000, 500, .{}));
    try std.testing.expectError(error.InvalidSchedule, dayNumbers(&store, std.testing.allocator, 1_001, 1_000, 500, .{}));
    try std.testing.expectError(error.InvalidTime, dayNumbers(&store, std.testing.allocator, -1, 1_000, 500, .{}));
    try std.testing.expectError(error.InvalidTime, dayNumbers(&store, std.testing.allocator, 0, -1, 500, .{}));
    try std.testing.expectError(error.InvalidTime, dayNumbers(&store, std.testing.allocator, 0, 1_000, -1, .{}));
    try std.testing.expectError(error.InvalidTime, dayNumbers(&store, std.testing.allocator, limit, limit + 1, limit, .{}));
    try std.testing.expectError(error.InvalidTime, dayNumbers(&store, std.testing.allocator, 0, limit, 500, .{}));
    try std.testing.expectError(error.InvalidTime, dayNumbers(&store, std.testing.allocator, 0, 1_000, limit, .{}));
}

test "paid breaks are credited up to their allowance and lunch never is" {
    var db: @import("sqlite.zig").Db = .{};
    try db.open(":memory:");
    defer db.close();
    var store = try store_mod.Store.init(&db, std.testing.allocator);
    const a = try store.createTask("A", 1);
    const hour: i64 = 3_600_000;
    const minute: i64 = 60_000;
    const day: i64 = 24 * hour;
    const paid = [_]PaidWindow{
        .{ .start_ms = 0, .end_ms = 12 * hour, .allow_ms = 15 * minute },
        .{ .start_ms = 12 * hour, .end_ms = day, .allow_ms = 15 * minute },
    };
    // 09:00-10:00, coffee 10:00-10:10, 10:10-12:00, lunch 12:00-13:00, 13:00-15:00, pause 15:00-15:40.
    try fixtureInterval(&store, a, .focus, 9 * hour, 10 * hour, .@"switch");
    try fixtureInterval(&store, a, .focus, 10 * hour + 10 * minute, 12 * hour, .@"resume");
    try fixtureInterval(&store, a, .focus, 13 * hour, 15 * hour, .@"resume");
    try fixtureInterval(&store, a, .focus, 15 * hour + 40 * minute, 16 * hour, .@"resume");
    const lunches = [_]Span{.{ .start_ms = 12 * hour, .end_ms = 13 * hour }};
    var n = try dayNumbers(&store, std.testing.allocator, 0, day, 20 * hour, .{ .paid = &paid, .lunches = &lunches });
    defer n.deinit(std.testing.allocator);
    try std.testing.expectEqual(25 * minute, n.paid_break_ms);
    try std.testing.expectEqual(510 * minute - n.total_ms - 25 * minute, n.remaining_ms);

    // A pause running now is credited as it goes, so clock-out does not move.
    try fixtureInterval(&store, a, .focus, day + 9 * hour, day + 10 * hour, .@"switch");
    const next_paid = [_]PaidWindow{.{ .start_ms = day, .end_ms = day + 12 * hour, .allow_ms = 15 * minute }};
    var on_break = try dayNumbers(&store, std.testing.allocator, day, 2 * day, day + 10 * hour + 10 * minute, .{ .paid = &next_paid });
    defer on_break.deinit(std.testing.allocator);
    try std.testing.expectEqual(10 * minute, on_break.paid_break_ms);
    try std.testing.expectEqual(510 * minute - hour - 10 * minute, on_break.remaining_ms);
    // The running pause is not a break already taken: lunch would end an hour after it began.
    try std.testing.expectEqual(@as(?i64, day + 11 * hour), on_break.expected_return_ms);
    var none = try dayNumbers(&store, std.testing.allocator, day, 2 * day, day + 10 * hour + 10 * minute, .{});
    defer none.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), none.paid_break_ms);
}
