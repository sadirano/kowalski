const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const manifest = @import("provider_manifest");
const source = @import("provider_source.zig");
const fetch = @import("provider_source_fetch.zig");
const loader = @import("provider_loader.zig");
const no_replace = @import("no_replace");
const publisher = @import("provider_publish");
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

test "publisher folder flows through enroll check install into source trust" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const key = try std.fs.path.join(a, &.{ root, "key.txt" });
    const input = try std.fs.path.join(a, &.{ root, "input.dll" });
    const out = try std.fs.path.join(a, &.{ root, "source" });
    const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = key, .data = "seed 0000000000000000000000000000000000000000000000000000000000000001\n" });
    try cwd.writeFile(io, .{ .sub_path = input, .data = "fake provider DLL" });
    const published = try publisher.publish(a, io, .{ .dll = input, .key_path = key, .provider = "sample", .channel = "stable", .sequence = 1, .version = "1", .out = out });
    const fetcher: fetch.Fetcher = .{ .context = undefined, .get = fetch.realGet };
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(15_000));
    const json = try fetch.boundedGet(io, a, fetcher, try fetch.location(a, out, "manifest.json"), manifest.max_manifest, deadline);
    const sig = try fetch.boundedGet(io, a, fetcher, try fetch.location(a, out, "manifest.sig"), manifest.max_manifest, deadline);
    const m = try manifest.verify(a, json, sig, published.public_key);
    var db: sqlite.Db = .{};
    try db.open(db_path);
    defer db.close();
    try schema.ensure(&db);
    try source.enroll(&db, 0, out, published.public_key, "compared", m, json, sig, 1);
    try std.testing.expectEqual(source.Outcome.same, try source.check(&db, a, 1, m, json, sig, 2));
    const cache_dir = try loader.cacheDir(a, db_path);
    try cwd.createDirPath(io, cache_dir);
    const stage = try std.fs.path.join(a, &.{ cache_dir, "incoming-test.tmp" });
    const stage_file = try cwd.createFile(io, stage, .{ .exclusive = true });
    const copier: fetch.Copier = .{ .context = undefined, .copy = fetch.realCopy };
    const copied = try fetch.boundedCopy(io, copier, try fetch.location(a, out, m.file), stage, stage_file, @intCast(m.size), std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(15_000)));
    try std.testing.expectEqual(@as(usize, @intCast(m.size)), copied.size);
    try std.testing.expectEqualStrings(m.sha256, &copied.digest);
    const dest = try loader.cachePath(a, db_path, m.sha256);
    try no_replace.move(a, stage, dest);
    const verified = try loader.verified(a, db_path, m.sha256);
    loader.close(verified);
    try source.installTrust(&db, a, 1, json, m, 3, false);
    var stmt = try db.prepare("SELECT sha256,mode FROM provider_trust WHERE id=1");
    defer stmt.finalize();
    try std.testing.expectEqual(.row, try stmt.step());
    try std.testing.expectEqualStrings(published.sha256, stmt.columnText(0).?);
    try std.testing.expectEqualStrings("source", stmt.columnText(1).?);
    const collision_stage = try std.fs.path.join(a, &.{ cache_dir, "collision.tmp" });
    try cwd.writeFile(io, .{ .sub_path = collision_stage, .data = "different" });
    try std.testing.expectError(error.PathAlreadyExists, no_replace.move(a, collision_stage, dest));
    const still = try loader.verified(a, db_path, m.sha256);
    loader.close(still);
}

test "cache collision with different content never replaces the file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
    const cache = try loader.cacheDir(a, db_path);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, cache);
    const hash = manifest.digest("correct");
    const dest = try loader.cachePath(a, db_path, &hash);
    const stage = try std.fs.path.join(a, &.{ cache, "incoming-test.tmp" });
    try cwd.writeFile(io, .{ .sub_path = dest, .data = "different" });
    try cwd.writeFile(io, .{ .sub_path = stage, .data = "correct" });
    try std.testing.expectError(error.PathAlreadyExists, no_replace.move(a, stage, dest));
    try std.testing.expectError(error.CacheHash, loader.verified(a, db_path, &hash));
    try std.testing.expectEqualStrings("different", try cwd.readFileAlloc(io, dest, a, .limited(100)));
}

test "generation change while DLL copy is running discards the install" {
    const Fake = struct {
        var started = std.atomic.Value(bool).init(false);
        fn copy(_: *anyopaque, _: std.mem.Allocator, io: std.Io, _: []const u8, file: std.Io.File, _: usize) !fetch.CopyResult {
            started.store(true, .release);
            try file.writeStreamingAll(io, "payload");
            Sleep(200);
            return .{ .size = 7, .digest = manifest.digest("payload") };
        }
    };
    Fake.started.store(false, .release);
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const db_path = try std.fs.path.join(a, &.{ root, "work.db" });
    var db: sqlite.Db = .{};
    try db.open(db_path);
    defer db.close();
    try schema.ensure(&db);
    const hash = manifest.digest("payload");
    const key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const m: manifest.Manifest = .{ .provider = "sample", .channel = "stable", .sequence = 1, .version = "1", .file = "sample-1.dll", .size = 7, .sha256 = &hash };
    try source.enroll(&db, 0, "folder", key, "compared", m, "manifest-one", "sig", 1);
    const cache = try loader.cacheDir(a, db_path);
    try std.Io.Dir.cwd().createDirPath(io, cache);
    const stage = try std.fs.path.join(a, &.{ cache, "pending.tmp" });
    const file = try std.Io.Dir.cwd().createFile(io, stage, .{ .exclusive = true });
    const copier: fetch.Copier = .{ .context = undefined, .copy = Fake.copy };
    var future = try io.concurrent(fetch.boundedCopy, .{ io, copier, "unused", stage, file, @as(usize, 7), std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(1000)) });
    for (0..40) |_| {
        if (Fake.started.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(Fake.started.load(.acquire));
    try source.stop(&db);
    try source.enroll(&db, 1, "second", key, "compared", m, "manifest-two", "sig", 2);
    const copied = try future.await(io);
    try fetch.verifyCopy(copied, 7, &hash);
    try std.testing.expectError(error.SourceChanged, source.installTrust(&db, a, 1, "manifest-one", m, 3, false));
    var stmt = try db.prepare("SELECT count(*) FROM provider_trust");
    defer stmt.finalize();
    try std.testing.expectEqual(.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 0), stmt.columnI64(0));
}
