//! `kowalskiw.exe`: the daemon without a console window. With `--background`
//! (the logon entry, `kowalski start`) it serves quietly and logs to
//! `daemon.log` next to the database; double-clicked, it starts that daemon
//! and opens the dashboard.
const std = @import("std");
const daemon = @import("daemon.zig");
const paths = @import("paths.zig");
const opener = @import("opener.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch std.process.exit(1);
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var db_flag: ?[]const u8 = null;
    var background = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--background")) {
            background = true;
        } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len and db_flag == null) {
            db_flag = args[i + 1];
            i += 1;
        } else return error.Usage;
    }
    const db = db_flag orelse try paths.defaultDb(init.io, a);
    if (!background) return opener.openOrAlert(init.io, a, db, db_flag);
    const log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(db) orelse ".", "daemon.log" });
    try daemon.serve(init.io, init.gpa, .{ .db_path = db, .log_path = log_path });
}
