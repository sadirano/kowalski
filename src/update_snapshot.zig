const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const sqlite = @import("sqlite.zig");

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;

pub fn snapshot(db_path: []const u8, dest: []const u8) !void {
    var db: sqlite.Db = .{};
    try db.open(db_path);
    defer db.close();
    var vacuum = try db.prepare("VACUUM INTO ?1");
    defer vacuum.finalize();
    try vacuum.bindText(1, dest);
    if (try vacuum.step() != .done) return error.Sqlite;
}

pub fn restore(a: std.mem.Allocator, io: Io, db_path: []const u8, source: []const u8) !void {
    const db_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, db_path);
    defer a.free(db_wide);
    // SQLite's Windows handles share read/write; share 0 refuses an open connection.
    const handle = CreateFileW(db_wide, 0x80000000 | 0x40000000, 0, null, 3, 0x80, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.DatabaseBusy;
    _ = CloseHandle(handle);
    const cwd = Io.Dir.cwd();
    const wal = try std.fmt.allocPrint(a, "{s}-wal", .{db_path});
    defer a.free(wal);
    const shm = try std.fmt.allocPrint(a, "{s}-shm", .{db_path});
    defer a.free(shm);
    for ([_][]const u8{ wal, shm }) |sidecar| cwd.deleteFile(io, sidecar) catch |err| if (err != error.FileNotFound) return err;
    const tmp = try std.fmt.allocPrint(a, "{s}.restore.tmp", .{db_path});
    defer a.free(tmp);
    errdefer cwd.deleteFile(io, tmp) catch {};
    try Io.Dir.copyFile(cwd, source, cwd, tmp, io, .{ .replace = true });
    const tmp_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, tmp);
    defer a.free(tmp_wide);
    if (MoveFileExW(tmp_wide, db_wide, 1 | 8) == 0) return error.RestoreRename;
}

test "snapshot contains WAL writes and restore replaces database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
    defer a.free(db_path);
    const copy = try std.fs.path.join(a, &.{ root, "snapshot.db" });
    defer a.free(copy);
    var db: sqlite.Db = .{};
    try db.open(db_path);
    try db.exec("CREATE TABLE t (n INTEGER)");
    try db.exec("INSERT INTO t VALUES (1)");
    try snapshot(db_path, copy);
    try db.exec("INSERT INTO t VALUES (2)");
    try std.testing.expectError(error.DatabaseBusy, restore(a, io, db_path, copy));
    db.close();
    try restore(a, io, db_path, copy);
    const wal = try std.fmt.allocPrint(a, "{s}-wal", .{db_path});
    defer a.free(wal);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, wal, .{}));
    const shm = try std.fmt.allocPrint(a, "{s}-shm", .{db_path});
    defer a.free(shm);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, shm, .{}));
    try db.open(db_path);
    defer db.close();
    var query = try db.prepare("SELECT count(*) FROM t");
    defer query.finalize();
    try std.testing.expectEqual(sqlite.Statement.Step.row, try query.step());
    try std.testing.expectEqual(@as(i64, 1), query.columnI64(0));
}
