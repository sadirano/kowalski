//! User-initiated release checks and installation. No request runs at startup.
const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const clock = @import("clock.zig");
const launch = @import("launch.zig");

pub const current_version = @import("build_options").version;
pub const releases_url = "https://api.github.com/repos/sadirano/kowalski/releases/latest";

pub const Version = struct { major: u32, minor: u32, patch: u32 };
pub fn parseVersion(text: []const u8) ?Version {
    const bare = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    var parts = std.mem.splitScalar(u8, bare, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const patch = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn newerThan(tag: []const u8, running: []const u8) bool {
    const found = parseVersion(tag) orelse return false;
    const current = parseVersion(running) orelse return false;
    if (found.major != current.major) return found.major > current.major;
    if (found.minor != current.minor) return found.minor > current.minor;
    return found.patch > current.patch;
}

fn newer(tag: []const u8) bool { return newerThan(tag, current_version); }

pub const Release = struct {
    version: []const u8,
    notes_url: []const u8,
    download_url: []const u8,
    size: u64,
    digest: ?[]const u8,
};
pub const Check = union(enum) { up_to_date, available: Release };

pub fn parseRelease(a: std.mem.Allocator, bytes: []const u8) !Check {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (root != .object) return error.BadRelease;
    const tag_value = root.object.get("tag_name") orelse return error.BadRelease;
    if (tag_value != .string or !newer(tag_value.string)) return .up_to_date;
    const tag = tag_value.string;
    const name = try std.fmt.allocPrint(a, "kowalski-{s}-windows-x86_64.zip", .{tag});
    const assets = root.object.get("assets") orelse return error.BadRelease;
    if (assets != .array) return error.BadRelease;
    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const asset_name = asset.object.get("name") orelse continue;
        if (asset_name != .string or !std.mem.eql(u8, asset_name.string, name)) continue;
        const url = asset.object.get("browser_download_url") orelse return error.BadRelease;
        const size = asset.object.get("size") orelse return error.BadRelease;
        const notes = root.object.get("html_url") orelse return error.BadRelease;
        if (url != .string or size != .integer or size.integer < 0 or notes != .string) return error.BadRelease;
        const digest_value = asset.object.get("digest") orelse .null;
        const digest = if (digest_value == .string) digest_value.string else null;
        return .{ .available = .{
            .version = try a.dupe(u8, if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag),
            .notes_url = notes.string,
            .download_url = url.string,
            .size = @intCast(size.integer),
            .digest = digest,
        } };
    }
    return .up_to_date;
}

pub const Fetcher = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, std.mem.Allocator, Io, []const u8, bool, usize) anyerror![]const u8,
};

pub fn httpGet(_: *anyopaque, a: std.mem.Allocator, io: Io, url: []const u8, redirects: bool, max_size: usize) ![]const u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const storage = try a.alloc(u8, max_size);
    var body: Io.Writer = .fixed(storage);
    const agent = try std.fmt.allocPrint(a, "kowalski/{s}", .{current_version});
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body,
        .redirect_behavior = if (redirects) .init(5) else .not_allowed,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = agent },
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
    }) catch |err| switch (err) {
        error.WriteFailed => return error.UpdateTooLarge,
        else => return err,
    };
    if (result.status != .ok) return error.UpdateHttp;
    return body.buffered();
}

pub fn check(a: std.mem.Allocator, io: Io, fetcher: Fetcher) !Check {
    const bytes = try fetcher.get(fetcher.context, a, io, releases_url, false, 1024 * 1024);
    return parseRelease(a, bytes);
}

pub fn validDownload(bytes: []const u8, release: Release) !void {
    if (bytes.len != release.size) return error.UpdateSizeMismatch;
    if (release.digest) |digest| {
        if (!std.mem.startsWith(u8, digest, "sha256:") or digest.len != 71) return error.BadDigest;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        var expected: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&expected, digest[7..]) catch return error.BadDigest;
        if (!std.mem.eql(u8, &hash, &expected)) return error.UpdateDigestMismatch;
    }
}

fn join(a: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(a, parts);
}

/// Accept only the two executable entries beneath the expected release folder.
pub fn extractExecutables(a: std.mem.Allocator, io: Io, zip_path: []const u8, stage: []const u8, version: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var archive = try cwd.openFile(io, zip_path, .{});
    defer archive.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = archive.reader(io, &read_buffer);
    var iter = try std.zip.Iterator.init(&reader);
    const folder = try std.fmt.allocPrint(a, "kowalski-v{s}-windows-x86_64/", .{version});
    const console_name = try std.fmt.allocPrint(a, "{s}kowalski.exe", .{folder});
    const window_name = try std.fmt.allocPrint(a, "{s}kowalskiw.exe", .{folder});
    var found_console = false;
    var found_window = false;
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        const filename = try entry.getFilename(&reader, &filename_buffer, .{});
        const console = std.mem.eql(u8, filename, console_name);
        const window = std.mem.eql(u8, filename, window_name);
        if (!console and !window) {
            if (std.mem.endsWith(u8, filename, "/kowalski.exe") or std.mem.endsWith(u8, filename, "/kowalskiw.exe")) return error.UnexpectedExePath;
            continue;
        }
        if (entry.uncompressed_size > 128 * 1024 * 1024) return error.UpdateTooLarge;
        if ((console and found_console) or (window and found_window)) return error.DuplicateExe;
        const dest = try join(a, &.{ stage, if (console) "kowalski.exe" else "kowalskiw.exe" });
        var out = try cwd.createFile(io, dest, .{ .exclusive = true });
        defer out.close(io);
        var write_buffer: [8192]u8 = undefined;
        var writer = out.writer(io, &write_buffer);
        try entry.extractTo(&reader, &writer.interface);
        try writer.flush();
        if (console) found_console = true else found_window = true;
    }
    if (!found_console or !found_window) return error.MissingExe;
}

fn backupDatabase(a: std.mem.Allocator, io: Io, db: *sqlite.Db, db_path: []const u8, version: []const u8) !void {
    var checkpoint = try db.prepare("PRAGMA wal_checkpoint(TRUNCATE)");
    defer checkpoint.finalize();
    if (try checkpoint.step() != .row or checkpoint.columnI64(0) != 0) return error.CheckpointBusy;
    const root = std.fs.path.dirname(db_path) orelse ".";
    const name = std.fs.path.basename(db_path);
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(clock.nowMs(), 1000)) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    const folder = try std.fmt.allocPrint(a, "backup-before-{s}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}", .{
        version, day.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(),
    });
    const dest = try join(a, &.{ root, folder });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dest);
    var source_dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer source_dir.close(io);
    var entries = source_dir.iterate();
    var copied_db = false;
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, name)) continue;
        const target = try join(a, &.{ dest, entry.name });
        try Io.Dir.copyFile(source_dir, entry.name, cwd, target, io, .{});
        if (std.mem.eql(u8, entry.name, name)) copied_db = true;
    }
    if (!copied_db) return error.BackupMissingDatabase;
}

pub const Swap = struct {
    exe_dir: []const u8,
    stage: []const u8,

    pub fn rollback(self: Swap, a: std.mem.Allocator, io: Io) void {
        const cwd = Io.Dir.cwd();
        for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
            const current = join(a, &.{ self.exe_dir, name }) catch continue;
            const old = std.fmt.allocPrint(a, "{s}.old", .{current}) catch continue;
            cwd.deleteFile(io, current) catch {};
            Io.Dir.rename(cwd, old, cwd, current, io) catch {};
        }
    }
};

/// New files are copied alongside the running executables before either old
/// executable is renamed. Any failure restores both original names.
pub fn swapExecutables(a: std.mem.Allocator, io: Io, exe_dir: []const u8, stage: []const u8) !Swap {
    const cwd = Io.Dir.cwd();
    const names = [_][]const u8{ "kowalski.exe", "kowalskiw.exe" };
    var current: [2][]const u8 = undefined;
    var old: [2][]const u8 = undefined;
    var incoming: [2][]const u8 = undefined;
    var copied: usize = 0;
    errdefer for (incoming[0..copied]) |path| cwd.deleteFile(io, path) catch {};
    for (names, 0..) |name, i| {
        current[i] = try join(a, &.{ exe_dir, name });
        old[i] = try std.fmt.allocPrint(a, "{s}.old", .{current[i]});
        incoming[i] = try std.fmt.allocPrint(a, "{s}.new", .{current[i]});
        if (cwd.statFile(io, old[i], .{})) |_| return error.OldExePresent else |err| if (err != error.FileNotFound) return err;
        const source = try join(a, &.{ stage, name });
        try Io.Dir.copyFile(cwd, source, cwd, incoming[i], io, .{ .replace = true });
        copied += 1;
    }
    var moved_old: [2]bool = .{ false, false };
    var moved_new: [2]bool = .{ false, false };
    errdefer {
        for (0..2) |i| if (moved_new[i]) cwd.deleteFile(io, current[i]) catch {};
        for (0..2) |i| if (moved_old[i]) Io.Dir.rename(cwd, old[i], cwd, current[i], io) catch {};
    }
    for (0..2) |i| {
        try Io.Dir.rename(cwd, current[i], cwd, old[i], io);
        moved_old[i] = true;
    }
    for (0..2) |i| {
        try Io.Dir.rename(cwd, incoming[i], cwd, current[i], io);
        moved_new[i] = true;
    }
    return .{ .exe_dir = exe_dir, .stage = stage };
}

/// Freshly verifies the chosen release, stages it, backs up the live database,
/// and swaps the executable names. The caller spawns the successor or rolls back.
pub fn install(a: std.mem.Allocator, io: Io, fetcher: Fetcher, db: *sqlite.Db, db_path: []const u8, version: []const u8) !Swap {
    const latest = try check(a, io, fetcher);
    const release = switch (latest) {
        .up_to_date => return error.NoUpdate,
        .available => |r| r,
    };
    if (!std.mem.eql(u8, version, release.version)) return error.UpdateChanged;
    if (!std.mem.startsWith(u8, release.download_url, "https://")) return error.BadRelease;
    if (release.size > 256 * 1024 * 1024) return error.UpdateTooLarge;
    const bytes = try fetcher.get(fetcher.context, a, io, release.download_url, true, @intCast(release.size));
    try validDownload(bytes, release);
    const root = std.fs.path.dirname(db_path) orelse ".";
    const update_dir = try join(a, &.{ root, "update" });
    const stage = try join(a, &.{ update_dir, version });
    const zip_path = try join(a, &.{ update_dir, try std.fmt.allocPrint(a, "{s}.zip", .{version}) });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, stage);
    try cwd.writeFile(io, .{ .sub_path = zip_path, .data = bytes });
    try extractExecutables(a, io, zip_path, stage, version);
    try backupDatabase(a, io, db, db_path, version);
    return swapExecutables(a, io, try launch.exeDir(a), stage);
}

/// Called only after a successful daemon start; stale backups stay untouched.
pub fn cleanup(a: std.mem.Allocator, io: Io, db_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const exe_dir = try launch.exeDir(a);
    inline for (.{ "kowalski.exe.old", "kowalskiw.exe.old" }) |name| {
        const path = try join(a, &.{ exe_dir, name });
        cwd.deleteFile(io, path) catch |err| if (err != error.FileNotFound) return err;
    }
    const stage = try join(a, &.{ std.fs.path.dirname(db_path) orelse ".", "update" });
    cwd.deleteTree(io, stage) catch |err| if (err != error.FileNotFound) return err;
}

test "version comparison ignores malformed and prerelease tags" {
    try std.testing.expect(parseVersion("v0.1.0") != null);
    try std.testing.expect(parseVersion("v0.1.0-rc1") == null);
    try std.testing.expect(parseVersion("garbage") == null);
    try std.testing.expect(newerThan("v0.1.1", "0.1.0"));
    try std.testing.expect(newerThan("v0.2.0", "0.1.1"));
    try std.testing.expect(newerThan("v1.0.0", "0.2.0"));
    try std.testing.expect(!newerThan("v0.1.0", "0.1.0"));
}

test "release selects exact asset and rejects missing asset" {
    const a = std.testing.allocator;
    const json = "{\"tag_name\":\"v0.2.0\",\"html_url\":\"https://example.test/notes\",\"assets\":[{\"name\":\"kowalski-v0.2.0-windows-x86_64.zip.extra\",\"size\":1,\"browser_download_url\":\"https://example.test/wrong\"},{\"name\":\"kowalski-v0.2.0-windows-x86_64.zip\",\"size\":2,\"browser_download_url\":\"https://example.test/right\"}]}";
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const result = try parseRelease(arena.allocator(), json);
    try std.testing.expectEqualStrings("https://example.test/right", result.available.download_url);
    const missing = try parseRelease(arena.allocator(), "{\"tag_name\":\"v0.2.0\",\"assets\":[]}");
    try std.testing.expect(missing == .up_to_date);
}

test "digest mismatch rejects download" {
    const release: Release = .{ .version = "0.2.0", .notes_url = "", .download_url = "", .size = 3, .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    try std.testing.expectError(error.UpdateDigestMismatch, validDownload("abc", release));
}

fn zip16(bytes: *std.ArrayList(u8), a: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try bytes.appendSlice(a, &buf);
}
fn zip32(bytes: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try bytes.appendSlice(a, &buf);
}

const ZipTestFile = struct { name: []const u8, data: []const u8 };
fn testZip(a: std.mem.Allocator, files: []const ZipTestFile) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    for (files) |file| {
        try offsets.append(a, @intCast(bytes.items.len));
        try bytes.appendSlice(a, "PK\x03\x04");
        try zip16(&bytes, a, 20);
        for (0..4) |_| try zip16(&bytes, a, 0); // flags, method, time, date
        try zip32(&bytes, a, 0); // CRC (not used by extractTo)
        try zip32(&bytes, a, @intCast(file.data.len));
        try zip32(&bytes, a, @intCast(file.data.len));
        try zip16(&bytes, a, @intCast(file.name.len));
        try zip16(&bytes, a, 0);
        try bytes.appendSlice(a, file.name);
        try bytes.appendSlice(a, file.data);
    }
    const cd_start: u32 = @intCast(bytes.items.len);
    for (files, offsets.items) |file, offset| {
        try bytes.appendSlice(a, "PK\x01\x02");
        try zip16(&bytes, a, 20); // made by
        try zip16(&bytes, a, 20); // needed
        for (0..4) |_| try zip16(&bytes, a, 0);
        try zip32(&bytes, a, 0);
        try zip32(&bytes, a, @intCast(file.data.len));
        try zip32(&bytes, a, @intCast(file.data.len));
        try zip16(&bytes, a, @intCast(file.name.len));
        for (0..3) |_| try zip16(&bytes, a, 0); // extra, comment, disk
        try zip16(&bytes, a, 0); // internal attrs
        try zip32(&bytes, a, 0); // external attrs
        try zip32(&bytes, a, offset);
        try bytes.appendSlice(a, file.name);
    }
    const cd_size: u32 = @intCast(bytes.items.len - cd_start);
    try bytes.appendSlice(a, "PK\x05\x06");
    try zip16(&bytes, a, 0);
    try zip16(&bytes, a, 0);
    try zip16(&bytes, a, @intCast(files.len));
    try zip16(&bytes, a, @intCast(files.len));
    try zip32(&bytes, a, cd_size);
    try zip32(&bytes, a, cd_start);
    try zip16(&bytes, a, 0);
    return bytes.items;
}

test "zip extracts only exact executables and rejects traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const stage = try join(a, &.{ root, "stage" });
    defer a.free(stage);
    try Io.Dir.cwd().createDirPath(io, stage);
    const zip_path = try join(a, &.{ root, "release.zip" });
    defer a.free(zip_path);
    const files = [_]ZipTestFile{
        .{ .name = "kowalski-v0.2.0-windows-x86_64/kowalski.exe", .data = "console" },
        .{ .name = "kowalski-v0.2.0-windows-x86_64/kowalskiw.exe", .data = "window" },
        .{ .name = "kowalski-v0.2.0-windows-x86_64/README.md", .data = "ignored" },
    };
    const zip = try testZip(a, &files);
    defer a.free(zip);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zip_path, .data = zip });
    try extractExecutables(a, io, zip_path, stage, "0.2.0");
    const console = try Io.Dir.cwd().readFileAlloc(io, try join(a, &.{ stage, "kowalski.exe" }), a, .limited(100));
    defer a.free(console);
    try std.testing.expectEqualStrings("console", console);
    const bad = [_]ZipTestFile{
        .{ .name = "../kowalski.exe", .data = "bad" },
    };
    const bad_zip = try testZip(a, &bad);
    defer a.free(bad_zip);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zip_path, .data = bad_zip });
    try std.testing.expectError(error.ZipBadFilename, extractExecutables(a, io, zip_path, stage, "0.2.0"));
}

test "swap and rollback restore original executables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const exe_dir = try join(a, &.{ root, "bin" });
    defer a.free(exe_dir);
    const stage = try join(a, &.{ root, "stage" });
    defer a.free(stage);
    try Io.Dir.cwd().createDirPath(io, exe_dir);
    try Io.Dir.cwd().createDirPath(io, stage);
    for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try join(a, &.{ exe_dir, name }), .data = "old" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try join(a, &.{ stage, name }), .data = "new" });
    }
    const swap = try swapExecutables(a, io, exe_dir, stage);
    swap.rollback(a, io);
    for ([_][]const u8{ "kowalski.exe", "kowalskiw.exe" }) |name| {
        const data = try Io.Dir.cwd().readFileAlloc(io, try join(a, &.{ exe_dir, name }), a, .limited(100));
        defer a.free(data);
        try std.testing.expectEqualStrings("old", data);
    }
    try Io.Dir.cwd().deleteFile(io, try join(a, &.{ exe_dir, "kowalskiw.exe" }));
    try std.testing.expectError(error.FileNotFound, swapExecutables(a, io, exe_dir, stage));
    const first = try Io.Dir.cwd().readFileAlloc(io, try join(a, &.{ exe_dir, "kowalski.exe" }), a, .limited(100));
    defer a.free(first);
    try std.testing.expectEqualStrings("old", first);
}

test "release check uses the HTTP seam without network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var called = false;
    const fake: Fetcher = .{ .context = &called, .get = struct {
        fn get(context: *anyopaque, _: std.mem.Allocator, _: Io, url: []const u8, redirects: bool, max_size: usize) ![]const u8 {
            const seen: *bool = @ptrCast(@alignCast(context));
            seen.* = true;
            try std.testing.expectEqualStrings(releases_url, url);
            try std.testing.expect(!redirects);
            try std.testing.expectEqual(@as(usize, 1024 * 1024), max_size);
            return "{\"tag_name\":\"v0.2.0\",\"html_url\":\"https://example.test/notes\",\"assets\":[{\"name\":\"kowalski-v0.2.0-windows-x86_64.zip\",\"size\":2,\"browser_download_url\":\"https://example.test/download\"}]}";
        }
    }.get };
    const result = try check(arena.allocator(), std.testing.io, fake);
    try std.testing.expect(called);
    try std.testing.expect(result == .available);
}
