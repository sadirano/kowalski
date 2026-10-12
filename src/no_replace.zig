const std = @import("std");
const windows = std.os.windows;
extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// Windows rename with write-through and no replace-existing flag.
pub fn move(a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const from_w = try std.unicode.utf8ToUtf16LeAllocZ(a, from);
    defer a.free(from_w);
    const to_w = try std.unicode.utf8ToUtf16LeAllocZ(a, to);
    defer a.free(to_w);
    if (MoveFileExW(from_w, to_w, 8) != 0) return;
    return switch (GetLastError()) {
        80, 183 => error.PathAlreadyExists,
        2, 3 => error.FileNotFound,
        else => error.MoveFailed,
    };
}
