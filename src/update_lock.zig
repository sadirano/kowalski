const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn CreateMutexW(?*anyopaque, i32, [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn ReleaseMutex(windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) i32;

pub const Lock = struct {
    handle: windows.HANDLE,

    pub fn release(self: *Lock) void {
        _ = ReleaseMutex(self.handle);
        _ = CloseHandle(self.handle);
        self.* = undefined;
    }
};

pub fn tryAcquire() ?Lock {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\sadirano-kowalski-update");
    const handle = CreateMutexW(null, 0, name) orelse return null;
    return switch (WaitForSingleObject(handle, 0)) {
        0, 0x80 => .{ .handle = handle },
        0x102 => { _ = CloseHandle(handle); return null; },
        else => { _ = CloseHandle(handle); return null; },
    };
}

test "update lock can be released and acquired again" {
    var first = tryAcquire().?;
    first.release();
    var second = tryAcquire().?;
    second.release();
}
