const std = @import("std");
const update = @import("release_update");
const paths = @import("release_paths");
const Ed25519 = std.crypto.sign.Ed25519;

const usage = "usage: zig build sign -- <zip path> [--key <path>]\n";

pub fn parseKeyFile(bytes: []const u8) ![32]u8 {
    var seed: ?[32]u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "seed ") or seed != null or line.len != 69) return error.BadKeyFile;
        var decoded: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&decoded, line[5..]) catch return error.BadKeyFile;
        seed = decoded;
    }
    return seed orelse error.BadKeyFile;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const message: []const u8 = switch (err) {
            error.WrongReleaseKey => "this key is not the release key built into kowalski",
            error.BadKeyFile => "invalid release signing key file",
            else => @errorName(err),
        };
        std.debug.print("kowalski-sign: {s}\n", .{message});
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
    if (args.len != 2 and args.len != 4) {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return error.Usage;
    }
    if (args.len == 4 and !std.mem.eql(u8, args[2], "--key")) return error.Usage;
    const key_path = if (args.len == 4) args[3] else blk: {
        const base = try paths.roamingAppData(a);
        break :blk try std.fs.path.join(a, &.{ base, "sadirano", "kowalski-dev", "release-signing-key.txt" });
    };
    const cwd = std.Io.Dir.cwd();
    const key_text = try cwd.readFileAlloc(init.io, key_path, a, .limited(4096));
    const seed = try parseKeyFile(key_text);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    if (!std.mem.eql(u8, &key_pair.public_key.toBytes(), &update.release_public_key)) return error.WrongReleaseKey;
    const zip_path = args[1];
    const zip = try cwd.readFileAlloc(init.io, zip_path, a, .limited(256 * 1024 * 1024));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &hash, .{});
    const message = try update.signedMessage(a, std.fs.path.basename(zip_path), hash);
    const signature = try key_pair.sign(message, null);
    const sig_path = try std.fmt.allocPrint(a, "{s}.sig", .{zip_path});
    const sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&signature.toBytes()});
    try cwd.writeFile(init.io, .{ .sub_path = sig_path, .data = sig_text });
    const display_path = try a.dupe(u8, sig_path);
    for (display_path) |*c| if (!std.ascii.isPrint(c.*)) { c.* = '?'; };
    const output = try std.fmt.allocPrint(a, "{s}\nsha256 {x}\n", .{ display_path, &hash });
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

test "key file parser accepts comments and rejects invalid seeds" {
    const hex = "0000000000000000000000000000000000000000000000000000000000000001";
    const seed = try parseKeyFile("# comment\nseed " ++ hex ++ "\n");
    try std.testing.expectEqual(@as(u8, 1), seed[31]);
    try std.testing.expectError(error.BadKeyFile, parseKeyFile("# no key\n"));
    try std.testing.expectError(error.BadKeyFile, parseKeyFile("seed nothex\n"));
    try std.testing.expectError(error.BadKeyFile, parseKeyFile("seed " ++ hex ++ "\nseed " ++ hex));
}
