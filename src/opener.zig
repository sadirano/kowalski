//! Opening kowalski the way a person does: by double-clicking an .exe or with
//! `kowalski open`. Starts the windowless daemon when it is not running,
//! waits for it, and opens the dashboard unless Settings turned that off.
//! Starts at logon and `kowalski start` stay quiet (`--background`).
const std = @import("std");
const cli = @import("cli.zig");
const launch = @import("launch.zig");
const sqlite = @import("sqlite.zig");

pub const Error = error{NoDaemon};

/// `force` opens the browser whatever the setting says (`kowalski open`).
/// `db_flag` is the `--db` the user gave, passed on to the daemon.
pub fn open(io: std.Io, a: std.mem.Allocator, db_path: []const u8, db_flag: ?[]const u8, force: bool) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: cli.Context = .{ .io = io, .a = a, .db_path = db_path, .json = false, .out = &out.writer, .err = &err.writer };
    if (!cli.ping(&ctx)) {
        try launch.spawn(a, try launch.backgroundCommand(a, db_flag, null));
        var up = false;
        for (0..50) |_| {
            try io.sleep(.fromMilliseconds(100), .awake);
            if (cli.ping(&ctx)) {
                up = true;
                break;
            }
        }
        if (!up) return error.NoDaemon;
    }
    if (!force and !wanted(db_path)) return;
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{try cli.readPort(&ctx)});
    try launch.openUrl(a, url);
}

/// The `ui_open_on_launch` setting; on unless it says "0".
fn wanted(db_path: []const u8) bool {
    var db: sqlite.Db = .{};
    db.openReadOnly(db_path) catch return true;
    defer db.close();
    var stmt = db.prepare("SELECT value FROM settings WHERE key='ui_open_on_launch'") catch return true;
    defer stmt.finalize();
    if ((stmt.step() catch return true) == .done) return true;
    return !std.mem.eql(u8, stmt.columnText(0) orelse "1", "0");
}

/// For a double-click: no console to report to, so a failure is a message box.
pub fn openOrAlert(io: std.Io, a: std.mem.Allocator, db_path: []const u8, db_flag: ?[]const u8) void {
    open(io, a, db_path, db_flag, false) catch |err| {
        const text = switch (err) {
            error.NoDaemon => "kowalski did not start within 5 seconds. See daemon.log in %APPDATA%\\sadirano\\kowalski.",
            error.OpenUrl => "kowalski is running, but the browser could not be opened. The dashboard is at http://127.0.0.1:47100/.",
            else => "kowalski could not start.",
        };
        launch.alert(a, text);
    };
}
