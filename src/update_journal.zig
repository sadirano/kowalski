const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;

extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;

pub const Phase = enum { swapped, trial, committed, rolling_back, rolled_back };
pub const Journal = struct {
    id: []const u8,
    from: []const u8,
    to: []const u8,
    phase: Phase,
    nonce: []const u8,
    snapshot: []const u8,
    exe_dir: []const u8,
    candidate_pid: u32 = 0,
    reason: []const u8 = "",
    started_ms: i64,
    ack: bool = false,
};

pub fn needsRecovery(journal: Journal) bool {
    return switch (journal.phase) { .swapped, .trial, .rolling_back => true, else => false };
}

fn validHex(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn path(a: std.mem.Allocator, db_path: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ std.fs.path.dirname(db_path) orelse ".", name });
}

pub fn read(a: std.mem.Allocator, io: Io, db_path: []const u8) !?Journal {
    const file_path = try path(a, db_path, "update.json");
    defer a.free(file_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const parsed = std.json.parseFromSliceLeaky(Journal, a, bytes, .{ .ignore_unknown_fields = false }) catch {
        a.free(bytes);
        return error.MalformedJournal;
    };
    if (!validHex(parsed.id) or !validHex(parsed.nonce) or parsed.reason.len > 200) {
        a.free(bytes);
        return error.MalformedJournal;
    }
    for (parsed.reason) |c| if (!std.ascii.isAscii(c)) {
        a.free(bytes);
        return error.MalformedJournal;
    };
    return parsed;
}

pub fn write(a: std.mem.Allocator, io: Io, db_path: []const u8, journal: Journal) !void {
    if (!validHex(journal.id) or !validHex(journal.nonce) or journal.reason.len > 200) return error.InvalidJournal;
    for (journal.reason) |c| if (!std.ascii.isAscii(c)) return error.InvalidJournal;
    const dest = try path(a, db_path, "update.json");
    defer a.free(dest);
    const tmp = try path(a, db_path, "update.json.tmp");
    defer a.free(tmp);
    const data = try std.json.Stringify.valueAlloc(a, journal, .{});
    defer a.free(data);
    const cwd = Io.Dir.cwd();
    var file = try cwd.createFile(io, tmp, .{ .truncate = true });
    errdefer cwd.deleteFile(io, tmp) catch {};
    {
        defer file.close(io);
        try file.writeStreamingAll(io, data);
        try file.sync(io);
    }
    const from = try std.unicode.utf8ToUtf16LeAllocZ(a, tmp);
    defer a.free(from);
    const to = try std.unicode.utf8ToUtf16LeAllocZ(a, dest);
    defer a.free(to);
    if (MoveFileExW(from, to, 1 | 8) == 0) return error.JournalRename;
}

test "journal round trip and atomic replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const db = try std.fs.path.join(a, &.{ root, "work.db" });
    defer a.free(db);
    const value: Journal = .{ .id = "0123456789abcdef0123456789abcdef", .from = "1.0", .to = "1.1", .phase = .swapped, .nonce = "abcdef0123456789abcdef0123456789", .snapshot = "snapshot.db", .exe_dir = "bin", .started_ms = 42 };
    try std.testing.expect((try read(a, io, db)) == null);
    try write(a, io, db, value);
    try std.testing.expectEqualStrings(value.id, (try read(a, io, db)).?.id);
    var next = value;
    next.phase = .trial;
    try write(a, io, db, next);
    try std.testing.expectEqual(Phase.trial, (try read(a, io, db)).?.phase);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "update.json.tmp", .{}));
}

test "malformed journal and recovery phases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "update.json", .data = "{" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const db = try std.fs.path.join(a, &.{ root, "work.db" });
    defer a.free(db);
    try std.testing.expectError(error.MalformedJournal, read(a, io, db));
    var j: Journal = .{ .id = "", .from = "", .to = "", .phase = .swapped, .nonce = "", .snapshot = "", .exe_dir = "", .started_ms = 0 };
    for ([_]Phase{ .swapped, .trial, .rolling_back }) |phase| { j.phase = phase; try std.testing.expect(needsRecovery(j)); }
    for ([_]Phase{ .committed, .rolled_back }) |phase| { j.phase = phase; try std.testing.expect(!needsRecovery(j)); }
}
