//! User-initiated release checks and installation. No request runs at startup.
const std = @import("std");
const Io = std.Io;
const launch = @import("launch.zig");
const journal = @import("update_journal.zig");
const update_lock = @import("update_lock.zig");
const clock = @import("clock.zig");
extern "bcrypt" fn BCryptGenRandom(?*anyopaque, [*]u8, u32, u32) callconv(.winapi) i32;

pub const current_version = @import("build_options").version;
pub const release_repo = @import("build_options").update_repo;
pub const releases_url = "https://api.github.com/repos/" ++ release_repo ++ "/releases/latest";
pub const release_public_key: [32]u8 = blk: {
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, @import("build_options").update_key) catch unreachable;
    break :blk key;
};

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

pub fn versionFromFile(path: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(path);
    const prefix = "kowalski-v";
    const suffix = "-windows-x86_64.zip";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
    const version = name[prefix.len .. name.len - suffix.len];
    if (parseVersion(version) == null) return null;
    return version;
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
    asset_name: []const u8 = "",
    size: u64,
    digest: ?[]const u8,
    signature_url: ?[]const u8 = null,
    signed: bool = false,
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
    const signature_name = try std.fmt.allocPrint(a, "{s}.sig", .{name});
    var signature_url: ?[]const u8 = null;
    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const asset_name = asset.object.get("name") orelse continue;
        if (asset_name != .string or !std.mem.eql(u8, asset_name.string, signature_name)) continue;
        const url = asset.object.get("browser_download_url") orelse continue;
        if (url == .string) signature_url = url.string;
    }
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
            .asset_name = name,
            .size = @intCast(size.integer),
            .digest = digest,
            .signature_url = signature_url,
            .signed = signature_url != null,
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
        // An extra user-agent would go out beside std's own, and GitHub's
        // asset host rejects the request (400).
        .headers = .{ .user_agent = .{ .override = agent } },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
    }) catch |err| switch (err) {
        error.WriteFailed => return error.UpdateTooLarge,
        else => return err,
    };
    if (result.status != .ok) return error.UpdateHttp;
    return body.buffered();
}

pub fn check(a: std.mem.Allocator, io: Io, fetcher: Fetcher) anyerror!Check {
    if (release_repo.len == 0) return error.UpdatesDisabled;
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

pub fn signedMessage(a: std.mem.Allocator, asset_name: []const u8, hash: [32]u8) ![]u8 {
    return std.fmt.allocPrint(a, "kowalski-release-v1\n{s}\n{x}\n", .{ asset_name, &hash });
}

pub fn verifySignature(a: std.mem.Allocator, asset_name: []const u8, zip: []const u8, signature_text: []const u8, public_key: [32]u8) !void {
    if (signature_text.len != 129 or signature_text[128] != '\n') return error.BadSignature;
    for (signature_text[0..128]) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.BadSignature;
    }
    var sig_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig_bytes, signature_text[0..128]) catch return error.BadSignature;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &hash, .{});
    const message = try signedMessage(a, asset_name, hash);
    defer a.free(message);
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch return error.BadSignature;
    std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes).verify(message, key) catch return error.BadSignature;
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

extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// Renames a file, including the image of a running executable (Windows
/// allows that through MoveFileExW; std's rename asks for access it refuses).
/// Replaces an existing target and waits until the move is on disk.
pub fn moveFile(a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const from_w = try std.unicode.utf8ToUtf16LeAllocZ(a, from);
    defer a.free(from_w);
    const to_w = try std.unicode.utf8ToUtf16LeAllocZ(a, to);
    defer a.free(to_w);
    if (MoveFileExW(from_w, to_w, 1 | 8) == 0) return switch (GetLastError()) {
        2, 3 => error.FileNotFound,
        else => error.MoveFailed,
    };
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
            moveFile(a, old, current) catch {};
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
        // Leftovers of a finished update (the guard ran from them): the caller
        // holds the update lock and no transaction is pending, so they can go.
        cwd.deleteFile(io, old[i]) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.OldExePresent,
        };
        const source = try join(a, &.{ stage, name });
        try Io.Dir.copyFile(cwd, source, cwd, incoming[i], io, .{ .replace = true });
        copied += 1;
    }
    var moved_old: [2]bool = .{ false, false };
    var moved_new: [2]bool = .{ false, false };
    errdefer {
        for (0..2) |i| if (moved_new[i]) cwd.deleteFile(io, current[i]) catch {};
        for (0..2) |i| if (moved_old[i]) moveFile(a, old[i], current[i]) catch {};
    }
    for (0..2) |i| {
        try moveFile(a, current[i], old[i]);
        moved_old[i] = true;
    }
    for (0..2) |i| {
        try moveFile(a, incoming[i], current[i]);
        moved_new[i] = true;
    }
    return .{ .exe_dir = exe_dir, .stage = stage };
}

/// Verifies and stages a release, then swaps executables under the update lock.
pub const Installed = struct { swap: Swap, lock: update_lock.Lock };
pub const Outcome = struct {
    id: []const u8,
    from: []const u8,
    to: []const u8,
    phase: journal.Phase,
    reason: []const u8,
    ack: bool,
};

pub fn outcome(value: ?journal.Journal) ?Outcome {
    const j = value orelse return null;
    if (j.ack or (j.phase != .committed and j.phase != .rolled_back)) return null;
    return .{ .id = j.id, .from = j.from, .to = j.to, .phase = j.phase, .reason = j.reason, .ack = j.ack };
}

pub fn install(a: std.mem.Allocator, io: Io, fetcher: Fetcher, db_path: []const u8, version: []const u8, local_file: ?[]const u8) anyerror!Installed {
    var lock = update_lock.tryAcquire() orelse return error.UpdateInProgress;
    errdefer lock.release();
    // An unfinished transaction still needs its .old executables to roll back.
    if (try journal.read(a, io, db_path)) |pending| if (journal.needsRecovery(pending)) return error.UpdateInProgress;
    const cwd = Io.Dir.cwd();
    var bytes: []const u8 = undefined;
    var signature: []const u8 = undefined;
    var asset_name: []const u8 = undefined;
    if (local_file) |file| {
        if (!std.fs.path.isAbsolute(file)) return error.LocalFileMustBeAbsolute;
        asset_name = std.fs.path.basename(file);
        const expected = try std.fmt.allocPrint(a, "kowalski-v{s}-windows-x86_64.zip", .{version});
        if (!std.mem.eql(u8, asset_name, expected) or parseVersion(version) == null) return error.BadReleaseName;
        bytes = try cwd.readFileAlloc(io, file, a, .limited(256 * 1024 * 1024));
        signature = try cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}.sig", .{file}), a, .limited(1024));
    } else {
        if (release_repo.len == 0) return error.UpdatesDisabled;
        const latest = try check(a, io, fetcher);
        const release = switch (latest) {
            .up_to_date => return error.NoUpdate,
            .available => |r| r,
        };
        if (!std.mem.eql(u8, version, release.version)) return error.UpdateChanged;
        const signature_url = release.signature_url orelse return error.UnsignedRelease;
        if (!std.mem.startsWith(u8, release.download_url, "https://") or !std.mem.startsWith(u8, signature_url, "https://")) return error.BadRelease;
        if (release.size > 256 * 1024 * 1024) return error.UpdateTooLarge;
        signature = try fetcher.get(fetcher.context, a, io, signature_url, true, 1024);
        bytes = try fetcher.get(fetcher.context, a, io, release.download_url, true, @intCast(release.size));
        try validDownload(bytes, release);
        asset_name = release.asset_name;
    }
    try verifySignature(a, asset_name, bytes, signature, release_public_key);
    const root = std.fs.path.dirname(db_path) orelse ".";
    const update_dir = try join(a, &.{ root, "update" });
    const stage = try join(a, &.{ update_dir, version });
    const zip_path = try join(a, &.{ update_dir, try std.fmt.allocPrint(a, "{s}.zip", .{version}) });
    cwd.deleteTree(io, stage) catch |err| if (err != error.FileNotFound) return err;
    try cwd.createDirPath(io, stage);
    try cwd.writeFile(io, .{ .sub_path = zip_path, .data = bytes });
    try extractExecutables(a, io, zip_path, stage, version);
    return .{ .swap = try swapExecutables(a, io, try launch.exeDir(a), stage), .lock = lock };
}

pub fn newJournal(a: std.mem.Allocator, version: []const u8) !journal.Journal {
    var random: [32]u8 = undefined;
    if (BCryptGenRandom(null, &random, random.len, 2) != 0) return error.RandomFailed;
    const id = std.fmt.bytesToHex(random[0..16].*, .lower);
    const nonce = std.fmt.bytesToHex(random[16..32].*, .lower);
    return .{
        .id = try a.dupe(u8, &id), .from = current_version, .to = version, .phase = .swapped,
        .nonce = try a.dupe(u8, &nonce),
        .snapshot = try std.fmt.allocPrint(a, "update-snapshot-{s}.db", .{id}),
        .exe_dir = try launch.exeDir(a), .started_ms = clock.nowMs(),
    };
}

/// Called only after a successful daemon start; stale backups stay untouched.
pub fn cleanup(a: std.mem.Allocator, io: Io, db_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const value = try journal.read(a, io, db_path);
    if (value) |j| if (journal.needsRecovery(j)) return;
    const exe_dir = try launch.exeDir(a);
    inline for (.{ "kowalski.exe.old", "kowalskiw.exe.old" }) |name| {
        const path = try join(a, &.{ exe_dir, name });
        // The guard can still be running from kowalskiw.exe.old.
        cwd.deleteFile(io, path) catch {};
    }
    const stage = try join(a, &.{ std.fs.path.dirname(db_path) orelse ".", "update" });
    cwd.deleteTree(io, stage) catch {};
    if (value) |j| {
        if (!std.fs.path.isAbsolute(j.snapshot) and std.mem.eql(u8, j.snapshot, std.fs.path.basename(j.snapshot))) {
            const path = try join(a, &.{ std.fs.path.dirname(db_path) orelse ".", j.snapshot });
            cwd.deleteFile(io, path) catch {};
        }
    }
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
    const json = "{\"tag_name\":\"v99.0.0\",\"html_url\":\"https://example.test/notes\",\"assets\":[{\"name\":\"kowalski-v99.0.0-windows-x86_64.zip.extra\",\"size\":1,\"browser_download_url\":\"https://example.test/wrong\"},{\"name\":\"kowalski-v99.0.0-windows-x86_64.zip\",\"size\":2,\"browser_download_url\":\"https://example.test/right\"}]}";
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const result = try parseRelease(arena.allocator(), json);
    try std.testing.expectEqualStrings("https://example.test/right", result.available.download_url);
    try std.testing.expect(!result.available.signed);
    const missing = try parseRelease(arena.allocator(), "{\"tag_name\":\"v99.0.0\",\"assets\":[]}");
    try std.testing.expect(missing == .up_to_date);
}

test "signed message is byte exact and signature binds ZIP and asset name" {
    const a = std.testing.allocator;
    const Ed25519 = std.crypto.sign.Ed25519;
    var seed: [32]u8 = undefined;
    @memset(&seed, 7);
    const key = try Ed25519.KeyPair.generateDeterministic(seed);
    const zip = "ZIP bytes";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &hash, .{});
    const name = "kowalski-v99.0.0-windows-x86_64.zip";
    const message = try signedMessage(a, name, hash);
    defer a.free(message);
    const expected = "kowalski-release-v1\nkowalski-v99.0.0-windows-x86_64.zip\n701ea42a760110f2b9933887d30ba10418fbaaa1642f2c9ab2a942d8759b8775\n";
    try std.testing.expectEqualStrings(expected, message);
    const signature = try key.sign(message, null);
    const signature_text = try std.fmt.allocPrint(a, "{x}\n", .{&signature.toBytes()});
    defer a.free(signature_text);
    const public_key = key.public_key.toBytes();
    try verifySignature(a, name, zip, signature_text, public_key);
    try std.testing.expectError(error.BadSignature, verifySignature(a, name, "ZIP byteS", signature_text, public_key));
    try std.testing.expectError(error.BadSignature, verifySignature(a, "kowalski-v0.3.0-windows-x86_64.zip", zip, signature_text, public_key));
    try std.testing.expectError(error.BadSignature, verifySignature(a, name, zip, "abc\n", public_key));
    var invalid: [129]u8 = undefined;
    @memcpy(&invalid, signature_text);
    invalid[0] = 'g';
    try std.testing.expectError(error.BadSignature, verifySignature(a, name, zip, &invalid, public_key));
}

test "release finds signature asset independently of ZIP order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"tag_name\":\"v99.0.0\",\"html_url\":\"https://example.test/notes\",\"assets\":[{\"name\":\"kowalski-v99.0.0-windows-x86_64.zip\",\"size\":2,\"browser_download_url\":\"https://example.test/zip\"},{\"name\":\"kowalski-v99.0.0-windows-x86_64.zip.sig\",\"size\":129,\"browser_download_url\":\"https://example.test/sig\"}]}";
    const result = try parseRelease(arena.allocator(), json);
    try std.testing.expect(result.available.signed);
    try std.testing.expectEqualStrings("https://example.test/sig", result.available.signature_url.?);
}

test "unsigned release returns before fetching ZIP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var calls: usize = 0;
    const fake: Fetcher = .{ .context = &calls, .get = struct {
        fn get(context: *anyopaque, _: std.mem.Allocator, _: Io, url: []const u8, _: bool, _: usize) ![]const u8 {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
            try std.testing.expectEqualStrings(releases_url, url);
            return "{\"tag_name\":\"v99.0.0\",\"html_url\":\"https://example.test/notes\",\"assets\":[{\"name\":\"kowalski-v99.0.0-windows-x86_64.zip\",\"size\":2,\"browser_download_url\":\"https://example.test/download\"}]}";
        }
    }.get };
    if (release_repo.len == 0) {
        try std.testing.expectError(error.UpdatesDisabled, install(arena.allocator(), std.testing.io, fake, "unused.db", "99.0.0", null));
        try std.testing.expectEqual(@as(usize, 0), calls);
    } else {
        try std.testing.expectError(error.UnsignedRelease, install(arena.allocator(), std.testing.io, fake, "unused.db", "99.0.0", null));
        try std.testing.expectEqual(@as(usize, 1), calls);
    }
}

test "install refuses a held update lock" {
    const State = struct {
        ready: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn hold(state: *@This()) void {
            var lock = update_lock.tryAcquire().?;
            state.ready.store(true, .release);
            while (!state.done.load(.acquire)) std.Thread.yield() catch {};
            lock.release();
        }
        fn noFetch(_: *anyopaque, _: std.mem.Allocator, _: Io, _: []const u8, _: bool, _: usize) ![]const u8 {
            return error.UnexpectedFetch;
        }
    };
    var state: State = .{};
    const thread = try std.Thread.spawn(.{}, State.hold, .{&state});
    defer {
        state.done.store(true, .release);
        thread.join();
    }
    while (!state.ready.load(.acquire)) std.Thread.yield() catch {};
    const fetcher: Fetcher = .{ .context = &state, .get = State.noFetch };
    try std.testing.expectError(error.UpdateInProgress, install(std.testing.allocator, std.testing.io, fetcher, "unused.db", "1.0.0", "missing.zip"));
}

test "digest mismatch rejects download" {
    const release: Release = .{ .version = "99.0.0", .notes_url = "", .download_url = "", .size = 3, .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
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
        .{ .name = "kowalski-v99.0.0-windows-x86_64/kowalski.exe", .data = "console" },
        .{ .name = "kowalski-v99.0.0-windows-x86_64/kowalskiw.exe", .data = "window" },
        .{ .name = "kowalski-v99.0.0-windows-x86_64/README.md", .data = "ignored" },
    };
    const zip = try testZip(a, &files);
    defer a.free(zip);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zip_path, .data = zip });
    try extractExecutables(a, io, zip_path, stage, "99.0.0");
    const console = try Io.Dir.cwd().readFileAlloc(io, try join(a, &.{ stage, "kowalski.exe" }), a, .limited(100));
    defer a.free(console);
    try std.testing.expectEqualStrings("console", console);
    const bad = [_]ZipTestFile{
        .{ .name = "../kowalski.exe", .data = "bad" },
    };
    const bad_zip = try testZip(a, &bad);
    defer a.free(bad_zip);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zip_path, .data = bad_zip });
    try std.testing.expectError(error.ZipBadFilename, extractExecutables(a, io, zip_path, stage, "99.0.0"));
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
            return "{\"tag_name\":\"v99.0.0\",\"html_url\":\"https://example.test/notes\",\"assets\":[{\"name\":\"kowalski-v99.0.0-windows-x86_64.zip\",\"size\":2,\"browser_download_url\":\"https://example.test/download\"}]}";
        }
    }.get };
    if (release_repo.len == 0) {
        try std.testing.expectError(error.UpdatesDisabled, check(arena.allocator(), std.testing.io, fake));
        try std.testing.expect(!called);
    } else {
        const result = try check(arena.allocator(), std.testing.io, fake);
        try std.testing.expect(called);
        try std.testing.expect(result == .available);
    }
}
