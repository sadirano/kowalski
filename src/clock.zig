const windows = @import("std").os.windows;

extern "kernel32" fn GetSystemTimePreciseAsFileTime(*windows.FILETIME) callconv(.winapi) void;

pub fn nowMs() i64 {
    var ft: windows.FILETIME = undefined;
    GetSystemTimePreciseAsFileTime(&ft);
    const ticks = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return fileTimeToMs(ticks);
}

fn fileTimeToMs(ticks: u64) i64 {
    return @intCast(@divFloor(@as(i128, ticks) - 116_444_736_000_000_000, 10_000));
}

test "file time conversion handles pre-1970 and epoch ticks" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, -1), fileTimeToMs(116_444_735_999_990_000));
    try std.testing.expectEqual(@as(i64, 0), fileTimeToMs(116_444_736_000_000_000));
}
