const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("provider-keygen: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: zig build provider-keygen -- <key file path>\n");
        if (args.len == 1) return;
        return error.Usage;
    }
    var seed: [32]u8 = undefined;
    init.io.random(&seed);
    defer @memset(&seed, 0);
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const public = pair.public_key.toBytes();
    const contents = try std.fmt.allocPrint(a, "# Private provider signing key. Keep an offline backup.\n# Public key: {x}\nseed {x}\n", .{ &public, &seed });
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(init.io, args[1], .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, contents);
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "{x}\n", .{&public}));
}
