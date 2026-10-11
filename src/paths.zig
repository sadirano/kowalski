const std = @import("std");
const windows = std.os.windows;

extern "shell32" fn SHGetKnownFolderPath(rfid: *const windows.GUID, flags: u32, token: ?windows.HANDLE, path: *?[*:0]u16) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

const folder_roaming_app_data = windows.GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}");

/// The user's tools keep their data under one root, one folder per tool.
pub const root_name = "sadirano";
pub const tool_name = "kowalski";
pub const db_name = "kowalski.db";

/// `<Roaming AppData>\sadirano\kowalski`, from the Windows known-folder API.
pub fn dataDir(allocator: std.mem.Allocator) ![]u8 {
    var wide: ?[*:0]u16 = null;
    const hr = SHGetKnownFolderPath(&folder_roaming_app_data, 0, null, &wide);
    defer CoTaskMemFree(wide);
    if (hr != 0 or wide == null) return error.KnownFolder;
    const base = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(wide.?));
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, root_name, tool_name });
}

/// Creates the data folder when missing and returns the default database path.
pub fn defaultDb(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const dir = try dataDir(allocator);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return std.fs.path.join(allocator, &.{ dir, db_name });
}

test "data folder sits under the shared tools root" {
    const dir = try dataDir(std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "\\sadirano\\kowalski"));
    try std.testing.expect(std.fs.path.isAbsolute(dir));
}
