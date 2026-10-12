const std = @import("std");
const check = @import("kowalski_provider_check");
const example = @import("example_provider");
const worker = @import("worker.zig");

fn dataDir(a: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fs.path.resolve(a, &.{ ".zig-cache", "tmp", sub_path });
}

test "example provider follows v3 contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try dataDir(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(dir);
    try check.check(example.kowalskiProvider, example.kowalskiProviderInfo, dir);
}

test "worker fake follows v3 contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try dataDir(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(dir);
    try check.check(worker.Fake.entry, worker.Fake.info, dir);
}
