//! Opening kowalski the way a person does: by double-clicking an .exe or with
//! `kowalski open`. Starts the windowless daemon when it is not running,
//! waits for it, and opens the dashboard unless Settings turned that off.
//! Starts at logon and `kowalski start` stay quiet (`--background`).
const std = @import("std");
const cli = @import("cli.zig");
const launch = @import("launch.zig");
const sqlite = @import("sqlite.zig");
const doctor = @import("doctor.zig");

/// `force` opens the browser whatever the setting says (`kowalski open`).
/// `db_flag` is the `--db` the user gave, passed on to the daemon.
pub fn open(io: std.Io, a: std.mem.Allocator, db_path: []const u8, db_flag: ?[]const u8, force: bool) !?[]const u8 {
    const report = try doctor.run(io, a, db_path, db_flag, true);
    if (!report.healthy) return try report.format(a);
    if (!force and !wanted(db_path)) return null;
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: cli.Context = .{ .io = io, .a = a, .db_path = db_path, .json = false, .out = &out.writer, .err = &err.writer };
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{try cli.readPort(&ctx)});
    launch.openUrl(a, url) catch return try std.fmt.allocPrint(a, "The dashboard is answering, but the browser could not be opened. Open {s}\nLog: {s}\n", .{ url, report.log_path });
    return null;
}

/// The `open_on_launch` setting; on unless it says "0".
fn wanted(db_path: []const u8) bool {
    var db: sqlite.Db = .{};
    db.openReadOnly(db_path) catch return true;
    defer db.close();
    var stmt = db.prepare("SELECT value FROM settings WHERE key='open_on_launch'") catch return true;
    defer stmt.finalize();
    if ((stmt.step() catch return true) == .done) return true;
    return !std.mem.eql(u8, stmt.columnText(0) orelse "1", "0");
}

/// For a double-click: no console to report to, so a failure is a message box.
pub fn openOrAlert(io: std.Io, a: std.mem.Allocator, db_path: []const u8, db_flag: ?[]const u8) void {
    const problem = open(io, a, db_path, db_flag, false) catch |err| blk: {
        const log_path = std.fs.path.join(a, &.{ std.fs.path.dirname(db_path) orelse ".", "daemon.log" }) catch "daemon.log";
        break :blk std.fmt.allocPrint(a, "kowalski could not open the dashboard: {s}\nLog: {s}", .{ @errorName(err), log_path }) catch "kowalski could not open the dashboard";
    };
    if (problem) |message| launch.alert(a, message);
}
