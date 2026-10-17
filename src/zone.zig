const std = @import("std");

const SystemTime = extern struct {
    year: u16 = 0,
    month: u16 = 0,
    day_of_week: u16 = 0,
    day: u16 = 0,
    hour: u16 = 0,
    minute: u16 = 0,
    second: u16 = 0,
    milliseconds: u16 = 0,
};

const FileTime = extern struct { low: u32, high: u32 };

const DynamicTimeZoneInformation = extern struct {
    bias: i32,
    standard_name: [32]u16,
    standard_date: SystemTime,
    standard_bias: i32,
    daylight_name: [32]u16,
    daylight_date: SystemTime,
    daylight_bias: i32,
    key_name: [128]u16,
    dynamic_daylight_time_disabled: u8,
    padding: [3]u8,
};

extern "kernel32" fn EnumDynamicTimeZoneInformation(u32, *DynamicTimeZoneInformation) callconv(.winapi) u32;
extern "kernel32" fn TzSpecificLocalTimeToSystemTimeEx(*const DynamicTimeZoneInformation, *const SystemTime, *SystemTime) callconv(.winapi) i32;
extern "kernel32" fn SystemTimeToTzSpecificLocalTimeEx(*const DynamicTimeZoneInformation, *const SystemTime, *SystemTime) callconv(.winapi) i32;
extern "kernel32" fn SystemTimeToFileTime(*const SystemTime, *FileTime) callconv(.winapi) i32;
extern "kernel32" fn FileTimeToSystemTime(*const FileTime, *SystemTime) callconv(.winapi) i32;
extern "kernel32" fn GetDynamicTimeZoneInformation(*DynamicTimeZoneInformation) callconv(.winapi) u32;

/// The Windows zone id the OS uses today, e.g. "E. South America Standard Time".
pub fn currentId(allocator: std.mem.Allocator) ![]u8 {
    var info: DynamicTimeZoneInformation = undefined;
    if (GetDynamicTimeZoneInformation(&info) == 0xFFFF_FFFF) return error.ZoneApi;
    const len = std.mem.indexOfScalar(u16, &info.key_name, 0) orelse info.key_name.len;
    if (len == 0) return error.ZoneApi;
    return std.unicode.utf16LeToUtf8Alloc(allocator, info.key_name[0..len]);
}

const epoch_ticks: i128 = 116_444_736_000_000_000;

fn ticks(ft: FileTime) i128 {
    return (@as(i128, ft.high) << 32) | ft.low;
}

fn fromTicks(value: i128) !FileTime {
    if (value < 0 or value > std.math.maxInt(u64)) return error.InvalidDate;
    const n: u64 = @intCast(value);
    return .{ .low = @truncate(n), .high = @truncate(n >> 32) };
}

fn utcMs(st: SystemTime) !i64 {
    var ft: FileTime = undefined;
    if (SystemTimeToFileTime(&st, &ft) == 0) return error.InvalidDate;
    return @intCast(@divFloor(ticks(ft) - epoch_ticks, 10_000));
}

fn fromUtcMs(ms: i64) !SystemTime {
    const ft = try fromTicks(epoch_ticks + @as(i128, ms) * 10_000);
    var result: SystemTime = undefined;
    if (FileTimeToSystemTime(&ft, &result) == 0) return error.InvalidDate;
    return result;
}

/// Every Windows time zone id, in the system's order; the ones a reporting
/// zone may name.
pub fn names(a: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var index: u32 = 0;
    while (true) : (index += 1) {
        var info: DynamicTimeZoneInformation = undefined;
        const result = EnumDynamicTimeZoneInformation(index, &info);
        if (result == 259) break;
        if (result != 0) return error.ZoneApi;
        const len = std.mem.indexOfScalar(u16, &info.key_name, 0) orelse info.key_name.len;
        const name = try a.alloc(u8, len);
        for (info.key_name[0..len], name) |wide, *narrow| narrow.* = if (wide < 128) @intCast(wide) else '?';
        try list.append(a, name);
    }
    return list.toOwnedSlice(a);
}

pub const Zone = struct {
    info: DynamicTimeZoneInformation,
    day_start_min: u16 = 0,

    pub fn load(id: []const u8) !Zone {
        var index: u32 = 0;
        while (true) : (index += 1) {
            var info: DynamicTimeZoneInformation = undefined;
            const result = EnumDynamicTimeZoneInformation(index, &info);
            if (result == 259) return error.UnknownZone;
            if (result != 0) return error.ZoneApi;
            var match = true;
            if (id.len >= info.key_name.len) match = false;
            if (match) {
                for (id, 0..) |ch, i| {
                    if (info.key_name[i] != ch) {
                        match = false;
                        break;
                    }
                }
                if (info.key_name[id.len] != 0) match = false;
            }
            if (match) return .{ .info = info };
        }
    }

    fn localStartMs(z: *const Zone, date: SystemTime) !i64 {
        var shifted = date;
        shifted.hour = @divTrunc(z.day_start_min, 60);
        shifted.minute = @mod(z.day_start_min, 60);
        const nominal = try utcMs(shifted);
        for (0..1440) |minutes| {
            const wanted = try fromUtcMs(nominal + @as(i64, @intCast(minutes)) * 60_000);
            var utc: SystemTime = undefined;
            if (TzSpecificLocalTimeToSystemTimeEx(&z.info, &wanted, &utc) == 0) return error.InvalidDate;
            const result = try utcMs(utc);
            // Windows may normalize a missing clock time into the gap. Use the
            // first actual local minute after it, while retaining its choice
            // of occurrence for a repeated clock time.
            if (z.day_start_min == 0) return result;
            const actual = try z.localOf(result);
            if (actual.year == wanted.year and actual.month == wanted.month and actual.day == wanted.day and actual.hour == wanted.hour and actual.minute == wanted.minute) return result;
        }
        return error.InvalidDate;
    }

    pub const Bounds = struct { start_ms: i64, end_ms: i64 };

    pub fn dayBounds(z: *const Zone, year: u16, month: u16, day: u16) !Bounds {
        // A missing local start maps to the first valid local time after it.
        // Windows dateOf can flip 1 ms early at a DST transition; that is a data artifact.
        const local: SystemTime = .{ .year = year, .month = month, .day = day };
        const nominal = try utcMs(local);
        const next = try fromUtcMs(nominal + 86_400_000);
        return .{
            .start_ms = try z.localStartMs(local),
            .end_ms = try z.localStartMs(.{ .year = next.year, .month = next.month, .day = next.day }),
        };
    }

    pub const Date = struct { year: u16, month: u16, day: u16 };

    pub fn dateOf(z: *const Zone, ms: i64) !Date {
        const utc = try fromUtcMs(ms);
        var local: SystemTime = undefined;
        if (SystemTimeToTzSpecificLocalTimeEx(&z.info, &utc, &local) == 0) return error.InvalidDate;
        // Compared as instants against the same start dayBounds uses, so a clock
        // time that repeats when DST ends lands on one day only.
        if (z.day_start_min != 0) {
            const calendar: SystemTime = .{ .year = local.year, .month = local.month, .day = local.day };
            if (ms < try z.localStartMs(calendar)) {
                const prior = try fromUtcMs((try utcMs(calendar)) - 86_400_000);
                return .{ .year = prior.year, .month = prior.month, .day = prior.day };
            }
        }
        return .{ .year = local.year, .month = local.month, .day = local.day };
    }

    pub const Local = struct { year: u16, month: u16, day: u16, hour: u16, minute: u16, second: u16 };

    pub fn localOf(z: *const Zone, ms: i64) !Local {
        const utc = try fromUtcMs(ms);
        var local: SystemTime = undefined;
        if (SystemTimeToTzSpecificLocalTimeEx(&z.info, &utc, &local) == 0) return error.InvalidDate;
        return .{ .year = local.year, .month = local.month, .day = local.day, .hour = local.hour, .minute = local.minute, .second = local.second };
    }
};

test "current zone loads and local time follows the zone" {
    const id = try currentId(std.testing.allocator);
    defer std.testing.allocator.free(id);
    _ = try Zone.load(id);
    const south = try Zone.load("E. South America Standard Time");
    const t = try south.localOf(1_773_111_600_000 + 9 * 3_600_000 + 5 * 60_000);
    try std.testing.expectEqual(@as(u16, 9), t.hour);
    try std.testing.expectEqual(@as(u16, 5), t.minute);
}

test "Windows reporting zones and daylight bounds" {
    const utc = try Zone.load("UTC");
    const utc_bounds = try utc.dayBounds(2026, 3, 10);
    try std.testing.expectEqual(@as(i64, 86_400_000), utc_bounds.end_ms - utc_bounds.start_ms);
    const south = try Zone.load("E. South America Standard Time");
    const south_bounds = try south.dayBounds(2026, 3, 10);
    try std.testing.expectEqual(@as(i64, 1_773_111_600_000), south_bounds.start_ms);
    const pacific = try Zone.load("Pacific Standard Time");
    const spring = try pacific.dayBounds(2026, 3, 8);
    const fall = try pacific.dayBounds(2026, 11, 1);
    try std.testing.expectEqual(@as(i64, 23 * 3_600_000), spring.end_ms - spring.start_ms);
    try std.testing.expectEqual(@as(i64, 25 * 3_600_000), fall.end_ms - fall.start_ms);
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 3, .day = 8 }, try pacific.dateOf(spring.start_ms));
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 11, .day = 1 }, try pacific.dateOf(fall.end_ms - 1));
    try std.testing.expectError(error.UnknownZone, Zone.load("No Such Zone"));
}

test "historical midnight daylight transitions preserve local day bounds" {
    const south = try Zone.load("E. South America Standard Time");
    const before_spring = try south.dayBounds(2018, 11, 3);
    const spring = try south.dayBounds(2018, 11, 4);
    try std.testing.expectEqual(@as(i64, 1_541_214_000_000), before_spring.start_ms);
    try std.testing.expectEqual(@as(i64, 1_541_300_400_000), before_spring.end_ms);
    try std.testing.expectEqual(before_spring.end_ms, spring.start_ms);
    try std.testing.expectEqual(@as(i64, 1_541_383_200_000), spring.end_ms);
    try std.testing.expectEqual(@as(i64, 23 * 3_600_000), spring.end_ms - spring.start_ms);

    const fall = try south.dayBounds(2019, 2, 16);
    const after_fall = try south.dayBounds(2019, 2, 17);
    try std.testing.expectEqual(@as(i64, 1_550_282_400_000), fall.start_ms);
    try std.testing.expectEqual(@as(i64, 1_550_372_400_000), fall.end_ms);
    try std.testing.expectEqual(fall.end_ms, after_fall.start_ms);
    try std.testing.expectEqual(@as(i64, 25 * 3_600_000), fall.end_ms - fall.start_ms);
}

test "a missing midnight starts the day at the gap and a repeated midnight at its first occurrence" {
    const cuba = try Zone.load("Cuba Standard Time");
    const before_gap = try cuba.dayBounds(2026, 3, 7);
    const gap = try cuba.dayBounds(2026, 3, 8);
    try std.testing.expectEqual(@as(i64, 1_772_946_000_000), gap.start_ms);
    try std.testing.expectEqual(before_gap.end_ms, gap.start_ms);
    try std.testing.expectEqual(@as(i64, 23 * 3_600_000), gap.end_ms - gap.start_ms);
    const before_repeat = try cuba.dayBounds(2026, 10, 31);
    const repeat = try cuba.dayBounds(2026, 11, 1);
    try std.testing.expectEqual(@as(i64, 1_793_505_600_000), repeat.start_ms);
    try std.testing.expectEqual(before_repeat.end_ms, repeat.start_ms);
    try std.testing.expectEqual(@as(i64, 25 * 3_600_000), repeat.end_ms - repeat.start_ms);
}

test "shifted day bounds and date follow local wall time" {
    var utc = try Zone.load("UTC");
    utc.day_start_min = 240;
    const prior = try utc.dayBounds(2026, 3, 14);
    const day = try utc.dayBounds(2026, 3, 15);
    try std.testing.expectEqual(@as(i64, 86_400_000), day.end_ms - day.start_ms);
    try std.testing.expectEqual(prior.end_ms, day.start_ms);
    try std.testing.expectEqual(@as(u16, 4), (try utc.localOf(day.start_ms)).hour);
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 3, .day = 14 }, try utc.dateOf(day.start_ms - 1));
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 3, .day = 15 }, try utc.dateOf(day.start_ms));
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 3, .day = 14 }, try utc.dateOf(prior.start_ms + 21 * 3_600_000));
}

test "shifted bounds cross daylight transitions" {
    var pacific = try Zone.load("Pacific Standard Time");
    pacific.day_start_min = 240;
    const spring = try pacific.dayBounds(2026, 3, 7);
    const spring_day = try pacific.dayBounds(2026, 3, 8);
    try std.testing.expectEqual(@as(i64, 23 * 3_600_000), spring.end_ms - spring.start_ms);
    try std.testing.expectEqual(spring.end_ms, spring_day.start_ms);
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 3, .day = 7 }, try pacific.dateOf(spring.end_ms - 1));
    const fall = try pacific.dayBounds(2026, 10, 31);
    try std.testing.expectEqual(@as(i64, 25 * 3_600_000), fall.end_ms - fall.start_ms);
    try std.testing.expectEqualDeep(Zone.Date{ .year = 2026, .month = 10, .day = 31 }, try pacific.dateOf(fall.end_ms - 1));
    var cuba = try Zone.load("Cuba Standard Time");
    cuba.day_start_min = 30;
    const gap = try cuba.dayBounds(2026, 3, 8);
    const first = try cuba.localOf(gap.start_ms);
    try std.testing.expectEqual(@as(u16, 1), first.hour);
    try std.testing.expectEqual(@as(u16, 0), first.minute);
}

test "with a late day start, every moment of a DST night lies inside its own day" {
    var z = try Zone.load("Pacific Standard Time");
    z.day_start_min = 90;
    // 2026-11-01: clocks fall back from 02:00 to 01:00, so 01:00-02:00 happens twice.
    const night = (try Zone.load("UTC")).dayBounds(2026, 11, 1);
    var ms = (try night).start_ms + 6 * 3_600_000;
    while (ms < (try night).start_ms + 12 * 3_600_000) : (ms += 15 * 60_000) {
        const d = try z.dateOf(ms);
        const b = try z.dayBounds(d.year, d.month, d.day);
        try std.testing.expect(b.start_ms <= ms and ms < b.end_ms);
    }
}

test "zone names include the zones Zone.load accepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try names(arena.allocator());
    try std.testing.expect(list.len > 50);
    for (list[0..3]) |name| _ = try Zone.load(name);
}
