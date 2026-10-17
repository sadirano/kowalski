const std = @import("std");
const sqlite = @import("sqlite.zig");
const store_mod = @import("store.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");
const daemon = @import("daemon.zig");
const cli = @import("cli.zig");
const launch = @import("launch.zig");
const opener = @import("opener.zig");
const demo = @import("demo.zig");
const tour_mod = @import("tour.zig");
const zone_mod = @import("zone.zig");
const update_guard = @import("update_guard.zig");

test { _ = @import("kowalskiw.zig"); }
test { _ = @import("update.zig"); }
test { _ = @import("update_journal.zig"); }
test { _ = @import("update_lock.zig"); }
test { _ = @import("update_snapshot.zig"); }
test { _ = @import("update_guard.zig"); }

extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) i32;
pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| blk: {
        std.debug.print("kowalski: {s}\n", .{@errorName(err)});
        break :blk @as(u8, 1);
    };
    std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const all = try init.minimal.args.toSlice(a);
    // Double-clicked (no arguments, a console of its own): open kowalski like
    // an app, and let the console window go.
    if (all.len == 1 and launch.ownConsole()) {
        launch.dropConsole();
        opener.openOrAlert(init.io, a, try paths.defaultDb(init.io, a), null);
        return 0;
    }
    // Titles and notes are UTF-8; say so to the console deliberately.
    _ = SetConsoleOutputCP(65001);

    var db_path: ?[]const u8 = null;
    var json = false;
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < all.len) : (i += 1) {
        const arg = all[i];
        if (std.mem.eql(u8, arg, "--db")) {
            if (i + 1 >= all.len or db_path != null) return usageError();
            db_path = all[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "kowalski " ++ @import("build_options").version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, cli.usage);
            return 0;
        } else try words.append(a, arg);
    }
    const command = if (words.items.len > 0) words.items[0] else "status";
    const args = if (words.items.len > 0) words.items[1..] else words.items;
    const db = db_path orelse try paths.defaultDb(init.io, a);

    if (std.mem.eql(u8, command, "serve")) {
        if (args.len != 0) return usageError();
        daemon.serve(init.io, init.gpa, .{ .db_path = db }) catch |err| switch (err) {
            error.AlreadyRunning => {
                std.debug.print("kowalski: the daemon is already running\n", .{});
                return 1;
            },
            else => return err,
        };
        return 0;
    }
    if (std.mem.eql(u8, command, "demo")) return demoData(init, db, args);

    var out: std.Io.Writer.Allocating = .init(a);
    var err_out: std.Io.Writer.Allocating = .init(a);
    var ctx: cli.Context = .{ .io = init.io, .a = a, .db_path = db, .json = json, .out = &out.writer, .err = &err_out.writer };
    if (std.mem.eql(u8, command, "start")) {
        if (args.len != 0) return usageError();
        return start(&ctx, db_path);
    }
    if (std.mem.eql(u8, command, "open")) {
        if (args.len != 0) return usageError();
        opener.open(init.io, a, db, db_path, true) catch |err| {
            std.debug.print("kowalski: could not open the dashboard: {s} (see daemon.log next to the database)\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }
    if (std.mem.eql(u8, command, "autostart")) return autostart(init, db_path, args);
    const exit = try cli.run(&ctx, command, args);
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
    try std.Io.File.stderr().writeStreamingAll(init.io, err_out.written());
    return @backingInt(exit);
}

fn usageError() u8 {
    std.debug.print("{s}", .{cli.usage});
    return @backingInt(cli.Exit.usage);
}

/// Starts kowalskiw and waits until it answers. `db` is the --db choice, if any.
fn start(ctx: *cli.Context, db: ?[]const u8) !u8 {
    if (try update_guard.recoverOnLaunch(ctx.a, ctx.io, ctx.db_path)) return 0;
    if (cli.ping(ctx)) {
        std.debug.print("kowalski: the daemon is already running\n", .{});
        return 0;
    }
    try launch.spawn(ctx.a, try launch.backgroundCommand(ctx.a, db, null));
    for (0..50) |_| {
        try ctx.io.sleep(.fromMilliseconds(100), .awake);
        if (cli.ping(ctx)) {
            std.debug.print("kowalski: daemon started\n", .{});
            return 0;
        }
    }
    std.debug.print("kowalski: the daemon did not answer within 5 s (see daemon.log next to the database)\n", .{});
    return 1;
}

fn autostart(init: std.process.Init, db: ?[]const u8, args: []const []const u8) !u8 {
    const a = init.arena.allocator();
    if (args.len > 1) return usageError();
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "on")) {
            try launch.setAutostart(a, launch.run_key, try launch.backgroundCommand(a, db, null));
        } else if (std.mem.eql(u8, args[0], "off")) {
            try launch.removeAutostart(a, launch.run_key);
        } else return usageError();
    }
    const out = std.Io.File.stdout();
    if (try launch.getAutostart(a, launch.run_key)) |command| {
        try out.writeStreamingAll(init.io, try std.fmt.allocPrint(a, "autostart: on ({s})\n", .{command}));
    } else try out.writeStreamingAll(init.io, "autostart: off\n");
    return 0;
}

/// `demo [--lang en|pt|ja] [--at YYYY-MM-DDTHH:MM] [--port N]`: fills an
/// empty database with made-up history, as of `--at` (local time) or now, for
/// screenshots. `--port` gives it its own, so the browser keeps its state apart.
fn demoData(init: std.process.Init, destination: []const u8, args: []const []const u8) !u8 {
    const a = init.arena.allocator();
    var lang: demo.Lang = .en;
    var at: ?[]const u8 = null;
    var port: ?u16 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return usageError();
        if (std.mem.eql(u8, args[i], "--lang")) {
            lang = demo.langOf(args[i + 1]) orelse return usageError();
        } else if (std.mem.eql(u8, args[i], "--at")) {
            at = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--port")) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch return usageError();
        } else return usageError();
    }
    var db: sqlite.Db = .{};
    try db.open(destination);
    defer db.close();
    var store = try store_mod.Store.init(&db, a);
    const zone_id = try store.reportingZone() orelse blk: {
        const id = try zone_mod.currentId(a);
        try store.setSetting("reporting_zone", id, clock.nowMs());
        break :blk id;
    };
    defer a.free(zone_id);
    const zone = try store.loadZone();
    const now = if (at) |text| localMs(&zone, text) orelse return usageError() else clock.nowMs();
    const instance = try store.getSetting("provider_instance") orelse tour_mod.instance;
    demo.seed(&db, a, .{ .lang = lang, .instance = instance, .now_ms = now, .zone = &zone }) catch |err| switch (err) {
        error.NotEmpty => {
            std.debug.print("kowalski: the database already has tasks; demo fills an empty one\n", .{});
            return 1;
        },
        else => return err,
    };
    if (port) |p| {
        var buffer: [8]u8 = undefined;
        try store.setSetting("http_port", std.fmt.bufPrint(&buffer, "{d}", .{p}) catch unreachable, clock.nowMs());
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "demo history written\n");
    return 0;
}

/// `YYYY-MM-DDTHH:MM` in the zone, as UTC milliseconds.
fn localMs(z: *const zone_mod.Zone, text: []const u8) ?i64 {
    if (text.len != 16 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':') return null;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u16, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u16, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    const bounds = z.dayBounds(year, month, day) catch return null;
    return bounds.start_ms + (hour * 60 + minute) * 60_000;
}

test {
    _ = @import("demo.zig");
    _ = @import("tour.zig");
    _ = @import("sqlite.zig");
    _ = @import("schema.zig");
    _ = @import("store.zig");
    _ = @import("days.zig");
    _ = @import("zone.zig");
    _ = @import("clock.zig");
    _ = @import("paths.zig");
    _ = @import("query.zig");
    _ = @import("api.zig");
    _ = @import("settings.zig");
    _ = @import("cli.zig");
    _ = @import("daemon.zig");
    _ = @import("provider_loader.zig");
    _ = @import("events.zig");
    _ = @import("launch.zig");
    _ = @import("worker.zig");
}
