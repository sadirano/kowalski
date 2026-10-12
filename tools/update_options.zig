const std = @import("std");

pub const default_repo = "sadirano/kowalski";
pub const default_key = "6434b476d6f442042c85deeeb428620ee428a34dddbab545a183908a738c04b8";

pub fn validRepo(repo: []const u8) bool {
    if (repo.len == 0) return true;
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse return false;
    if (slash == 0 or slash + 1 == repo.len) return false;
    for (repo, 0..) |c, i| {
        if (i == slash) continue;
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    }
    return true;
}

pub fn validKey(key: []const u8) bool {
    if (key.len != 64) return false;
    for (key) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    }
    return true;
}

test "update repo build option accepts one safe owner/name or empty" {
    for ([_][]const u8{ "", "someone/fork", "A_b.c-1/Repo_2" }) |repo| try std.testing.expect(validRepo(repo));
    for ([_][]const u8{ "owner", "/repo", "owner/", "a/b/c", "a/b?", "a/with space", "a/é" }) |repo| try std.testing.expect(!validRepo(repo));
}

test "update key build option requires lowercase SHA-sized hex" {
    try std.testing.expect(validKey(default_key));
    try std.testing.expect(validKey("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validKey(""));
    try std.testing.expect(!validKey(default_key[0..63]));
    try std.testing.expect(!validKey("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"));
    try std.testing.expect(!validKey("gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"));
}
