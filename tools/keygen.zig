const std = @import("std");
const sign = @import("release_sign");
const Ed25519 = std.crypto.sign.Ed25519;
const windows = std.os.windows;

extern "kernel32" fn GetSystemTimePreciseAsFileTime(*windows.FILETIME) callconv(.winapi) void;

const usage = "usage: zig build keygen -- <key file path>\n";
const self_check = "kowalski-release-keygen-self-check";

fn writeKeyFile(a: std.mem.Allocator, io: std.Io, path: []const u8, seed: [32]u8, date: []const u8) ![32]u8 {
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const signature = try pair.sign(self_check, null);
    try signature.verify(self_check, pair.public_key);
    const public_key = pair.public_key.toBytes();
    const contents = try std.fmt.allocPrint(a,
        "# Private release signing key. Never commit or share this file.\n" ++
        "# Keep an offline backup. Losing both copies requires users to reinstall by hand.\n" ++
        "# Created UTC: {s}\n" ++
        "# Public key: {x}\n" ++
        "seed {x}\n", .{ date, &public_key, &seed });
    defer a.free(contents);
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{ .exclusive = true });
    errdefer cwd.deleteFile(io, path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
    return public_key;
}

fn utcDate(a: std.mem.Allocator) ![]u8 {
    var ft: windows.FILETIME = undefined;
    GetSystemTimePreciseAsFileTime(&ft);
    const ticks = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(@as(i128, ticks) - 116_444_736_000_000_000, 10_000_000)) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, month.month.numeric(), month.day_index + 1 });
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const message: []const u8 = switch (err) {
            error.PathAlreadyExists => "key file already exists; refusing to overwrite",
            else => @errorName(err),
        };
        std.debug.print("kowalski-keygen: {s}\n", .{message});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }
    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return error.Usage;
    }
    var seed: [32]u8 = undefined;
    init.io.random(&seed);
    defer @memset(&seed, 0);
    const public_key = try writeKeyFile(a, init.io, args[1], seed, try utcDate(a));
    const output = try std.fmt.allocPrint(a, "{x}\n-Dupdate-key={x}\n", .{ &public_key, &public_key });
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

test "generated key file parses for signing and refuses overwrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const path = try std.fs.path.join(a, &.{ root, "release-signing-key.txt" });
    var seed: [32]u8 = undefined;
    io.random(&seed);
    const public_key = try writeKeyFile(a, io, path, seed, "2026-10-12");
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try std.testing.expectEqualSlices(u8, &seed, &try sign.parseKeyFile(contents));
    try std.testing.expect(std.mem.indexOf(u8, contents, "# Public key: ") != null);
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    try std.testing.expectEqualSlices(u8, &public_key, &pair.public_key.toBytes());
    if (writeKeyFile(a, io, path, seed, "2026-10-13")) |_| return error.ExpectedOverwriteRefusal else |err| {
        try std.testing.expect(err == error.PathAlreadyExists or err == error.FileAlreadyExists);
    }
    const still = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try std.testing.expectEqualStrings(contents, still);
}
