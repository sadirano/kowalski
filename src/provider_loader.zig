//! The only path from an on-disk provider to executable code.
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const contract = @import("kowalski_provider");

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(windows.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(windows.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFullPathNameW([*:0]const u16, u32, [*]u16, ?*?[*]u16) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?windows.HANDLE, u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetProcAddress(windows.HANDLE, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "version" fn GetFileVersionInfoSizeW([*:0]const u16, ?*u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoW([*:0]const u16, u32, u32, *anyopaque) callconv(.winapi) i32;
extern "version" fn VerQueryValueW(*anyopaque, [*:0]const u16, *?*anyopaque, *u32) callconv(.winapi) i32;

pub const Version = struct { product_name: []const u8 = "", file_version: []const u8 = "", company_name: []const u8 = "" };
pub const Candidate = struct {
    sha256: []const u8,
    size: u64,
    modified_ms: i64,
    file: []const u8,
    version: Version = .{},
};
pub const Scan = union(enum) { none, multiple, candidate: Candidate };
pub const Verified = struct { handle: windows.HANDLE, path: []const u8 };
pub const Module = struct { handle: windows.HANDLE, entry: *const contract.Entry, info: *const contract.Info };

pub fn cacheDir(a: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(db_path) orelse ".", "providers", ".cache" });
    return absolute(a, path);
}

fn absolute(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    var output: [32768]u16 = undefined;
    const len = GetFullPathNameW(wide, output.len, &output, null);
    if (len == 0 or len >= output.len) return error.BadPath;
    return std.unicode.utf16LeToUtf8Alloc(a, output[0..len]);
}

pub fn cachePath(a: std.mem.Allocator, db_path: []const u8, sha: []const u8) ![]const u8 {
    if (!validHash(sha)) return error.BadHash;
    const name = try std.fmt.allocPrint(a, "{s}.dll", .{sha});
    return std.fs.path.join(a, &.{ try cacheDir(a, db_path), name });
}

pub fn validHash(sha: []const u8) bool {
    if (sha.len != 64) return false;
    for (sha) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub fn scan(io: Io, a: std.mem.Allocator, db_path: []const u8) !Scan {
    const dir_path = try absolute(a, try std.fs.path.resolve(a, &.{ std.fs.path.dirname(db_path) orelse ".", "providers" }));
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .none,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    var name: ?[]const u8 = null;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".dll")) continue;
        if (name != null) return .multiple;
        name = try a.dupe(u8, entry.name);
    }
    const filename = name orelse return .none;
    const source = try std.fs.path.join(a, &.{ dir_path, filename });
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    const cache_dir = try cacheDir(a, db_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);
    const incoming = try std.fs.path.join(a, &.{ cache_dir, "incoming.tmp" });
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), incoming, io, .{ .replace = true });
    const copied = try hashPath(a, incoming);
    const dest = try cachePath(a, db_path, copied);
    const exists = std.Io.Dir.cwd().statFile(io, dest, .{}) catch null;
    if (exists == null) {
        try std.Io.Dir.renameAbsolute(incoming, dest, io);
    } else {
        std.Io.Dir.cwd().deleteFile(io, incoming) catch {};
    }
    return .{ .candidate = .{
        .sha256 = copied,
        .size = stat.size,
        .modified_ms = stat.mtime.toMilliseconds(),
        .file = filename,
    } };
}

pub fn verified(a: std.mem.Allocator, db_path: []const u8, sha: []const u8) !Verified {
    const path = try cachePath(a, db_path, sha);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    const handle = CreateFileW(wide, 0x80000000, 1, null, 3, 0x80, null); // READ, SHARE_READ, OPEN_EXISTING
    if (handle == windows.INVALID_HANDLE_VALUE) return error.CacheOpen;
    errdefer _ = CloseHandle(handle);
    var actual: [32768]u16 = undefined;
    const len = GetFinalPathNameByHandleW(handle, &actual, actual.len, 0);
    if (len == 0 or len >= actual.len) return error.CachePath;
    const final = try std.unicode.utf16LeToUtf8Alloc(a, actual[0..len]);
    if (!sameFinalPath(path, final)) return error.CacheRedirected;
    const digest = try hashHandle(a, handle);
    if (!std.mem.eql(u8, digest, sha)) return error.CacheHash;
    return .{ .handle = handle, .path = path };
}

pub fn close(v: Verified) void { _ = CloseHandle(v.handle); }

pub fn load(a: std.mem.Allocator, v: Verified) !Module {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, v.path);
    const module = LoadLibraryExW(wide, null, 0x800) orelse return error.LoadLibrary;
    const entry = GetProcAddress(module, "kowalskiProvider") orelse return error.MissingEntry;
    const info = GetProcAddress(module, "kowalskiProviderInfo") orelse return error.MissingInfo;
    return .{ .handle = module, .entry = @ptrCast(entry), .info = @ptrCast(info) };
}

fn hashPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    const handle = CreateFileW(wide, 0x80000000, 7, null, 3, 0x80, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.HashOpen;
    defer _ = CloseHandle(handle);
    return hashHandle(a, handle);
}

fn hashHandle(a: std.mem.Allocator, handle: windows.HANDLE) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    while (true) {
        var count: u32 = 0;
        if (ReadFile(handle, &buffer, buffer.len, &count, null) == 0) return error.HashRead;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}

pub fn sameFinalPath(expected: []const u8, final: []const u8) bool {
    const normalized = if (std.mem.startsWith(u8, final, "\\\\?\\")) final[4..] else final;
    return std.ascii.eqlIgnoreCase(expected, normalized);
}

fn ascii(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    const result = try a.alloc(u8, @min(source.len, 128));
    for (result, source[0..result.len]) |*dest, c| dest.* = if (std.ascii.isPrint(c)) c else '?';
    return result;
}

pub fn versionInfo(a: std.mem.Allocator, path: []const u8) !Version {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    const size = GetFileVersionInfoSizeW(wide, null);
    if (size == 0) return .{};
    const bytes = try a.alignedAlloc(u8, .of(u32), size);
    if (GetFileVersionInfoW(wide, 0, size, bytes.ptr) == 0) return .{};
    var translation: ?*anyopaque = null;
    var length: u32 = 0;
    const trans_path = std.unicode.utf8ToUtf16LeStringLiteral("\\VarFileInfo\\Translation");
    const has_translation = VerQueryValueW(bytes.ptr, trans_path, &translation, &length) != 0 and length >= 4;
    const pair: [*]const u16 = if (has_translation) @ptrCast(@alignCast(translation.?)) else &.{ 0x0409, 0x04b0 };
    return .{
        .product_name = try versionField(a, bytes.ptr, pair[0], pair[1], "ProductName"),
        .file_version = try versionField(a, bytes.ptr, pair[0], pair[1], "FileVersion"),
        .company_name = try versionField(a, bytes.ptr, pair[0], pair[1], "CompanyName"),
    };
}

fn versionField(a: std.mem.Allocator, data: *anyopaque, lang: u16, codepage: u16, field: []const u8) ![]const u8 {
    const key = try std.fmt.allocPrint(a, "\\StringFileInfo\\{x:0>4}{x:0>4}\\{s}", .{ lang, codepage, field });
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, key);
    var pointer: ?*anyopaque = null;
    var length: u32 = 0;
    if (VerQueryValueW(data, wide, &pointer, &length) == 0 or pointer == null or length == 0) return "";
    const chars: [*]const u16 = @ptrCast(@alignCast(pointer.?));
    const value = try std.unicode.utf16LeToUtf8Alloc(a, chars[0..length - 1]);
    return ascii(a, value);
}

test "final path comparison strips extended prefix and ignores case" {
    try std.testing.expect(sameFinalPath("C:\\Data\\provider.dll", "\\\\?\\c:\\data\\PROVIDER.dll"));
    try std.testing.expect(!sameFinalPath("C:\\Data\\provider.dll", "\\\\?\\c:\\other\\provider.dll"));
}
