const std = @import("std");

pub fn parse(bytes: []const u8) ![32]u8 {
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
