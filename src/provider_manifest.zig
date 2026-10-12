const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const prefix = "kowalski-provider-manifest-v1\n";
pub const max_manifest = 64 * 1024;
pub const max_dll = 64 * 1024 * 1024;

pub const Manifest = struct {
    provider: []const u8,
    channel: []const u8,
    sequence: i64,
    version: []const u8,
    file: []const u8,
    size: i64,
    sha256: []const u8,
};

pub fn validHex(s: []const u8, len: usize) bool {
    if (s.len != len) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 128 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}

pub fn validFile(s: []const u8) bool {
    return validName(s) and std.mem.endsWith(u8, s, ".dll");
}

pub fn validVersion(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (c < 32 or c > 126) return false;
    return true;
}

pub fn message(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ prefix, bytes });
}

pub fn verify(a: std.mem.Allocator, bytes: []const u8, signature: []const u8, key_hex: []const u8) !Manifest {
    if (bytes.len > max_manifest or !validHex(key_hex, 64)) return error.BadManifest;
    if (signature.len != 129 or signature[128] != '\n' or !validHex(signature[0..128], 128)) return error.BadSignature;
    var key: [32]u8 = undefined;
    var sig: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, key_hex) catch return error.BadSignature;
    _ = std.fmt.hexToBytes(&sig, signature[0..128]) catch return error.BadSignature;
    const public_key = Ed25519.PublicKey.fromBytes(key) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(sig).verify(try message(a, bytes), public_key) catch return error.BadSignature;
    return parse(a, bytes);
}

fn field(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.BadManifest;
}

fn string(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try field(object, name)) { .string => |s| s, else => error.BadManifest };
}

fn integer(object: std.json.ObjectMap, name: []const u8) !i64 {
    return switch (try field(object, name)) { .integer => |n| n, else => error.BadManifest };
}

/// Detect duplicate members before std.json's object map can replace one.
fn uniqueKeys(bytes: []const u8) !void {
    var seen: u16 = 0;
    var at: usize = 0;
    while (at < bytes.len and std.ascii.isWhitespace(bytes[at])) : (at += 1) {}
    if (at == bytes.len or bytes[at] != '{') return error.BadManifest;
    at += 1;
    while (at < bytes.len) {
        while (at < bytes.len and std.ascii.isWhitespace(bytes[at])) : (at += 1) {}
        if (at < bytes.len and bytes[at] == '}') break;
        if (at == bytes.len or bytes[at] != '"') return error.BadManifest;
        at += 1;
        const begin = at;
        while (at < bytes.len and bytes[at] != '"') : (at += 1) {
            if (bytes[at] == '\\') return error.BadManifest;
        }
        if (at == bytes.len) return error.BadManifest;
        const key = bytes[begin..at];
        const names = [_][]const u8{ "format", "provider", "channel", "sequence", "version", "contract", "arch", "file", "size", "sha256", "next_key" };
        var index: usize = 0;
        while (index < names.len and !std.mem.eql(u8, key, names[index])) : (index += 1) {}
        if (index == names.len) return error.BadManifest;
        const bit: u16 = @as(u16, 1) << @intCast(index);
        if (seen & bit != 0) return error.BadManifest;
        seen |= bit;
        at += 1;
        while (at < bytes.len and std.ascii.isWhitespace(bytes[at])) : (at += 1) {}
        if (at == bytes.len or bytes[at] != ':') return error.BadManifest;
        at += 1;
        var depth: usize = 0;
        var quoted = false;
        var escaped = false;
        while (at < bytes.len) : (at += 1) {
            const c = bytes[at];
            if (quoted) {
                if (escaped) { escaped = false; continue; }
                if (c == '\\') escaped = true else if (c == '"') quoted = false;
            } else switch (c) {
                '"' => quoted = true,
                '[', '{' => depth += 1,
                ']', '}' => { if (depth == 0) break else depth -= 1; },
                ',' => if (depth == 0) break,
                else => {},
            }
        }
        if (at < bytes.len and bytes[at] == '}') break;
        if (at == bytes.len) break;
        at += 1;
    }
    if (seen != (@as(u16, 1) << 11) - 1) return error.BadManifest;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Manifest {
    if (bytes.len > max_manifest) return error.BadManifest;
    try uniqueKeys(bytes);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.BadManifest;
    const object = switch (parsed) { .object => |o| o, else => return error.BadManifest };
    if (object.count() != 11 or try integer(object, "format") != 1 or try integer(object, "contract") != 3 or
        !std.mem.eql(u8, try string(object, "arch"), "x86_64-windows")) return error.BadManifest;
    if ((try field(object, "next_key")) != .null) return error.KeyRotationUnsupported;
    const m: Manifest = .{
        .provider = try string(object, "provider"), .channel = try string(object, "channel"),
        .sequence = try integer(object, "sequence"), .version = try string(object, "version"),
        .file = try string(object, "file"), .size = try integer(object, "size"), .sha256 = try string(object, "sha256"),
    };
    if (!validName(m.provider) or !validName(m.channel) or !validVersion(m.version) or !validFile(m.file) or
        m.sequence < 1 or m.sequence > 9_007_199_254_740_992 or m.size < 1 or m.size > max_dll or !validHex(m.sha256, 64)) return error.BadManifest;
    return m;
}

pub fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

test "manifest requires exact signed bytes and strict fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seed: [32]u8 = @splat(1);
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const bytes = "{\"format\":1,\"provider\":\"sample\",\"channel\":\"stable\",\"sequence\":1,\"version\":\"1\",\"contract\":3,\"arch\":\"x86_64-windows\",\"file\":\"sample-1.dll\",\"size\":1,\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"next_key\":null}";
    const msg = try message(a, bytes);
    defer a.free(msg);
    const sig = try pair.sign(msg, null);
    const sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&sig.toBytes()});
    defer a.free(sig_text);
    const key = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
    try std.testing.expectEqualStrings("sample", (try verify(a, bytes, sig_text, &key)).provider);
    try std.testing.expectError(error.BadSignature, verify(a, bytes ++ " ", sig_text, &key));
    try std.testing.expectError(error.BadManifest, parse(a, "{\"format\":1,\"format\":1}"));
}

test "signed manifest rejects unknown duplicate bad filename numeric limits and rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seed: [32]u8 = @splat(2);
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const key = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
    const Cases = struct { tail: []const u8, expected: anyerror };
    const cases = [_]Cases{
        .{ .tail = ",\"unknown\":1", .expected = error.BadManifest },
        .{ .tail = ",\"format\":1", .expected = error.BadManifest },
        .{ .tail = "", .expected = error.BadManifest },
    };
    const stem = "{\"format\":1,\"provider\":\"sample\",\"channel\":\"stable\",\"sequence\":1,\"version\":\"1\",\"contract\":3,\"arch\":\"x86_64-windows\",\"file\":\"sample-1.dll\",\"size\":1,\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"next_key\":null";
    for (cases[0..2]) |case| {
        const bytes = try std.fmt.allocPrint(a, "{s}{s}}}", .{ stem, case.tail });
        const sig = try pair.sign(try message(a, bytes), null);
        const sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&sig.toBytes()});
        try std.testing.expectError(case.expected, verify(a, bytes, sig_text, &key));
    }
    _ = cases[2];
    const invalid = [_]struct { file: []const u8 = "sample-1.dll", sequence: i64 = 1, size: i64 = 1, next: []const u8 = "null", expected: anyerror }{
        .{ .file = "../bad.dll", .expected = error.BadManifest },
        .{ .sequence = 0, .expected = error.BadManifest },
        .{ .sequence = 9_007_199_254_740_993, .expected = error.BadManifest },
        .{ .size = 0, .expected = error.BadManifest },
        .{ .size = max_dll + 1, .expected = error.BadManifest },
        .{ .next = "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"", .expected = error.KeyRotationUnsupported },
    };
    for (invalid) |case| {
        const bytes = try std.fmt.allocPrint(a, "{{\"format\":1,\"provider\":\"sample\",\"channel\":\"stable\",\"sequence\":{d},\"version\":\"1\",\"contract\":3,\"arch\":\"x86_64-windows\",\"file\":\"{s}\",\"size\":{d},\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"next_key\":{s}}}", .{ case.sequence, case.file, case.size, case.next });
        const sig = try pair.sign(try message(a, bytes), null);
        const sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&sig.toBytes()});
        try std.testing.expectError(case.expected, verify(a, bytes, sig_text, &key));
    }
    const boundary = try std.fmt.allocPrint(a, "{{\"format\":1,\"provider\":\"sample\",\"channel\":\"stable\",\"sequence\":{d},\"version\":\"1\",\"contract\":3,\"arch\":\"x86_64-windows\",\"file\":\"sample-1.dll\",\"size\":{d},\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"next_key\":null}}", .{ 9_007_199_254_740_992, max_dll });
    const boundary_sig = try pair.sign(try message(a, boundary), null);
    const boundary_sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&boundary_sig.toBytes()});
    const parsed_boundary = try verify(a, boundary, boundary_sig_text, &key);
    try std.testing.expectEqual(@as(i64, 9_007_199_254_740_992), parsed_boundary.sequence);
    try std.testing.expectEqual(@as(i64, max_dll), parsed_boundary.size);
    const valid = try std.fmt.allocPrint(a, "{s}}}", .{stem});
    const wrong_prefix = try std.mem.concat(a, u8, &.{ "kowalski-provider-manifest-v2\n", valid });
    const wrong_sig = try pair.sign(wrong_prefix, null);
    const wrong_sig_text = try std.fmt.allocPrint(a, "{x}\n", .{&wrong_sig.toBytes()});
    try std.testing.expectError(error.BadSignature, verify(a, valid, wrong_sig_text, &key));
}
