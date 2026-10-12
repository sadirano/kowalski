const std = @import("std");
const manifest = @import("provider_manifest");
const key_file = @import("provider_key_file.zig");
const no_replace = @import("no_replace");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("provider-publish: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 14) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: zig build provider-publish -- <dll> --key <file> --provider <instance> --channel <name> --sequence <n> --version <v> --out <dir>\n");
        if (args.len == 1) return;
        return error.Usage;
    }
    var key_path: ?[]const u8 = null;
    var provider: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var sequence_text: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var index: usize = 2;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--key")) key_path = args[index + 1]
        else if (std.mem.eql(u8, args[index], "--provider")) provider = args[index + 1]
        else if (std.mem.eql(u8, args[index], "--channel")) channel = args[index + 1]
        else if (std.mem.eql(u8, args[index], "--sequence")) sequence_text = args[index + 1]
        else if (std.mem.eql(u8, args[index], "--version")) version = args[index + 1]
        else if (std.mem.eql(u8, args[index], "--out")) out = args[index + 1]
        else return error.Usage;
    }
    const provider_name = provider orelse return error.Usage;
    const channel_name = channel orelse return error.Usage;
    const display_version = version orelse return error.Usage;
    const sequence = try std.fmt.parseInt(i64, sequence_text orelse return error.Usage, 10);
    const result = try publish(a, init.io, .{ .dll = args[1], .key_path = key_path orelse return error.Usage,
        .provider = provider_name, .channel = channel_name, .sequence = sequence,
        .version = display_version, .out = out orelse return error.Usage });
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\nsha256 {s}\n", .{ result.dll_path, result.sig_path, result.json_path, result.sha256 }));
}

pub const Options = struct { dll: []const u8, key_path: []const u8, provider: []const u8, channel: []const u8, sequence: i64, version: []const u8, out: []const u8 };
pub const Result = struct { dll_path: []const u8, sig_path: []const u8, json_path: []const u8, sha256: []const u8, public_key: []const u8 };

pub fn publish(a: std.mem.Allocator, io: std.Io, options: Options) !Result {
    const provider_name = options.provider;
    const channel_name = options.channel;
    const display_version = options.version;
    const sequence = options.sequence;
    if (!manifest.validName(provider_name) or !manifest.validName(channel_name) or !manifest.validVersion(display_version) or sequence < 1 or sequence > 9_007_199_254_740_992) return error.BadManifest;
    const file_name = try std.fmt.allocPrint(a, "{s}-{d}.dll", .{ provider_name, sequence });
    if (!manifest.validFile(file_name)) return error.BadManifest;
    const cwd = std.Io.Dir.cwd();
    const key_text = try cwd.readFileAlloc(io, options.key_path, a, .limited(4096));
    const seed = try key_file.parse(key_text);
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const dll = try cwd.readFileAlloc(io, options.dll, a, .limited(manifest.max_dll + 1));
    if (dll.len == 0 or dll.len > manifest.max_dll) return error.BadDllSize;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(dll, &hash, .{});
    const hash_hex = std.fmt.bytesToHex(hash, .lower);
    const json = try std.json.Stringify.valueAlloc(a, .{
        .format = 1, .provider = provider_name, .channel = channel_name, .sequence = sequence,
        .version = display_version, .contract = 3, .arch = "x86_64-windows", .file = file_name,
        .size = dll.len, .sha256 = &hash_hex, .next_key = @as(?[]const u8, null),
    }, .{});
    _ = try manifest.parse(a, json);
    const msg = try manifest.message(a, json);
    const signature = try pair.sign(msg, null);
    const sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&signature.toBytes()});
    const key_hex = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
    _ = try manifest.verify(a, json, sig_text, &key_hex);
    const dir = options.out;
    try cwd.createDirPath(io, dir);
    const dll_path = try std.fs.path.join(a, &.{ dir, file_name });
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const dll_tmp = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ dll_path, &nonce });
    {
        var staged = try cwd.createFile(io, dll_tmp, .{ .exclusive = true });
        defer staged.close(io);
        try staged.writeStreamingAll(io, dll);
    }
    defer cwd.deleteFile(io, dll_tmp) catch {};
    no_replace.move(a, dll_tmp, dll_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const old = try cwd.readFileAlloc(io, dll_path, a, .limited(manifest.max_dll + 1));
            if (!std.mem.eql(u8, old, dll)) return error.DifferentDllExists;
        },
        else => return err,
    };
    const json_tmp = try std.fs.path.join(a, &.{ dir, "manifest.json.tmp" });
    const sig_tmp = try std.fs.path.join(a, &.{ dir, "manifest.sig.tmp" });
    const json_path = try std.fs.path.join(a, &.{ dir, "manifest.json" });
    const sig_path = try std.fs.path.join(a, &.{ dir, "manifest.sig" });
    {
        var file = try cwd.createFile(io, json_tmp, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, json);
    }
    errdefer cwd.deleteFile(io, json_tmp) catch {};
    {
        var file = try cwd.createFile(io, sig_tmp, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, sig_text);
    }
    errdefer cwd.deleteFile(io, sig_tmp) catch {};
    try cwd.rename(sig_tmp, cwd, sig_path, io);
    try cwd.rename(json_tmp, cwd, json_path, io);
    return .{ .dll_path = dll_path, .sig_path = sig_path, .json_path = json_path,
        .sha256 = try a.dupe(u8, &hash_hex), .public_key = try a.dupe(u8, &key_hex) };
}

test "published files read back with the manifest verifier and reject a collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const key_path = try std.fs.path.join(a, &.{ dir, "key.txt" });
    const dll_path = try std.fs.path.join(a, &.{ dir, "input.dll" });
    const out = try std.fs.path.join(a, &.{ dir, "out" });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = key_path, .data = "# test\nseed 0000000000000000000000000000000000000000000000000000000000000001\n" });
    try cwd.writeFile(io, .{ .sub_path = dll_path, .data = "fake dll" });
    const options: Options = .{ .dll = dll_path, .key_path = key_path, .provider = "sample", .channel = "stable", .sequence = 1, .version = "1", .out = out };
    const published = try publish(a, io, options);
    const json = try cwd.readFileAlloc(io, published.json_path, a, .limited(manifest.max_manifest));
    const sig = try cwd.readFileAlloc(io, published.sig_path, a, .limited(manifest.max_manifest));
    const parsed = try manifest.verify(a, json, sig, published.public_key);
    try std.testing.expectEqualStrings("sample-1.dll", parsed.file);
    try std.testing.expectEqualStrings(published.sha256, parsed.sha256);
    try cwd.writeFile(io, .{ .sub_path = published.dll_path, .data = "different" });
    try std.testing.expectError(error.DifferentDllExists, publish(a, io, options));
}
