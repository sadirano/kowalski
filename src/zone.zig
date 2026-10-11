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

pub const Zone = struct {
    info: DynamicTimeZoneInformation,

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

    fn localMidnightMs(z: *const Zone, date: SystemTime) !i64 {
        var utc: SystemTime = undefined;
        if (TzSpecificLocalTimeToSystemTimeEx(&z.info, &date, &utc) == 0) return error.InvalidDate;
        return utcMs(utc);
    }

    pub const Bounds = struct { start_ms: i64, end_ms: i64 };

    pub fn dayBounds(z: *const Zone, year: u16, month: u16, day: u16) !Bounds {
        // Bounds use UTC of local midnight; a missing midnight maps to the first valid local time after it.
        // Windows dateOf can flip 1 ms early at a midnight DST transition; that is a data artifact.
        const local: SystemTime = .{ .year = year, .month = month, .day = day };
        const nominal = try utcMs(local);
        const next = try fromUtcMs(nominal + 86_400_000);
        return .{
            .start_ms = try z.localMidnightMs(local),
            .end_ms = try z.localMidnightMs(.{ .year = next.year, .month = next.month, .day = next.day }),
        };
    }

    pub const Date = struct { year: u16, month: u16, day: u16 };

    pub fn dateOf(z: *const Zone, ms: i64) !Date {
        const utc = try fromUtcMs(ms);
        var local: SystemTime = undefined;
        if (SystemTimeToTzSpecificLocalTimeEx(&z.info, &utc, &local) == 0) return error.InvalidDate;
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
