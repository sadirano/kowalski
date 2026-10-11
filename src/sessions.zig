const std = @import("std");
const zone = @import("zone.zig");

pub const Span = struct { start_ms: i64, end_ms: i64 };
pub const Session = struct {
    start_ms: i64,
    end_ms: i64,
    start: []const u8,
    end: []const u8,
};

fn before(_: void, lhs: Span, rhs: Span) bool {
    return lhs.start_ms < rhs.start_ms;
}

fn rounded(ms: i64, day_start: i64) i64 {
    return @divFloor(ms - day_start + 30_000, 60_000);
}

fn clock(a: std.mem.Allocator, z: *const zone.Zone, day_start: i64, day_end: i64, minute: i64) ![]const u8 {
    if (day_start + minute * 60_000 >= day_end) return a.dupe(u8, "23:59");
    const local = try z.localOf(day_start + minute * 60_000);
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ local.hour, local.minute });
}

/// Subtract covered time and earlier output from closed focus intervals.
pub fn remaining(a: std.mem.Allocator, z: *const zone.Zone, day_start: i64, day_end: i64, focus: []const Span, coverage: []const Span) ![]Session {
    const ordered = try a.dupe(Span, focus);
    std.mem.sort(Span, ordered, {}, before);
    var used: std.ArrayList(Span) = .empty;
    try used.appendSlice(a, coverage);
    var out: std.ArrayList(Session) = .empty;
    for (ordered) |raw| {
        const span = Span{ .start_ms = @max(raw.start_ms, day_start), .end_ms = @min(raw.end_ms, day_end) };
        if (span.start_ms >= span.end_ms) continue;
        var pieces: std.ArrayList(Span) = .empty;
        try pieces.append(a, span);
        for (used.items) |cut| {
            var next: std.ArrayList(Span) = .empty;
            for (pieces.items) |piece| {
                if (cut.end_ms <= piece.start_ms or cut.start_ms >= piece.end_ms) {
                    try next.append(a, piece);
                } else {
                    if (cut.start_ms > piece.start_ms) try next.append(a, .{ .start_ms = piece.start_ms, .end_ms = cut.start_ms });
                    if (cut.end_ms < piece.end_ms) try next.append(a, .{ .start_ms = cut.end_ms, .end_ms = piece.end_ms });
                }
            }
            pieces = next;
        }
        for (pieces.items) |piece| {
            const first = rounded(piece.start_ms, day_start);
            const last = rounded(piece.end_ms, day_start);
            if (first == last or day_start + first * 60_000 >= day_end) continue;
            try used.append(a, piece);
            try out.append(a, .{
                .start_ms = piece.start_ms, .end_ms = piece.end_ms,
                .start = try clock(a, z, day_start, day_end, first),
                .end = try clock(a, z, day_start, day_end, last),
            });
        }
    }
    return out.items;
}

test "subtract coverage and overlapping focus; round endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try zone.Zone.load("UTC");
    const day = (try z.dayBounds(2026, 3, 10)).start_ms;
    const h = 3_600_000;
    const m = 60_000;
    const focus = [_]Span{ .{ .start_ms = day + 9*h, .end_ms = day + 10*h }, .{ .start_ms = day + 9*h + 30*m, .end_ms = day + 11*h } };
    const covered = [_]Span{.{ .start_ms = day + 9*h + 15*m, .end_ms = day + 9*h + 45*m }};
    const result = try remaining(a, &z, day, day + 24*h, &focus, &covered);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("09:00", result[0].start);
    try std.testing.expectEqualStrings("11:00", result[2].end);
}

test "minute rounding drops equal endpoints and the last half minute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try zone.Zone.load("UTC");
    const bounds = try z.dayBounds(2026, 3, 10);
    const day = bounds.start_ms;
    const m = 60_000;
    const h = 60*m;
    const focus = [_]Span{
        .{ .start_ms = day + 9*h + 10_000, .end_ms = day + 9*h + 25_000 },
        .{ .start_ms = day + 9*h + 29_000, .end_ms = day + 9*h + 31_000 },
        .{ .start_ms = day + 23*h + 58*m, .end_ms = bounds.end_ms },
        .{ .start_ms = day + 23*h + 59*m + 30_000, .end_ms = bounds.end_ms },
    };
    const result = try remaining(a, &z, day, bounds.end_ms, &focus, &.{});
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("09:00", result[0].start);
    try std.testing.expectEqualStrings("09:01", result[0].end);
    try std.testing.expectEqualStrings("23:59", result[1].end);
}
