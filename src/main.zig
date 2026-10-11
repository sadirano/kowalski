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
const contract = @import("kowalski_provider");
const provider_impl = @import("provider_impl");
const windows = std.os.windows;

extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetConsoleMode(handle: windows.HANDLE, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(handle: windows.HANDLE, mode: u32) callconv(.winapi) i32;
extern "kernel32" fn ReadConsoleW(handle: windows.HANDLE, buffer: [*]u16, len: u32, read: *u32, control: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(handle: windows.HANDLE, data: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

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
    if (std.mem.eql(u8, command, "provider") and args.len == 1 and std.mem.eql(u8, args[0], "login")) return providerLogin(init);

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

fn providerLogin(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const table = provider_impl.kowalskiProvider(contract.version) orelse {
        try std.Io.File.stderr().writeStreamingAll(init.io, "no provider in this build\n");
        return 1;
    };
    var listed: contract.Bytes = .{};
    const listing = table.login_prompts(table.context, &listed);
    defer if (listing.message.ptr != null) table.free(table.context, listing.message);
    if (listing.code != 0) return loginFailed(init, listing.message.slice());
    const Prompt = struct { name: []const u8, label: []const u8, secret: bool = false };
    const prompts = std.json.parseFromSliceLeaky([]Prompt, a, listed.slice(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    table.free(table.context, listed);
    const list = prompts catch return loginFailed(init, "invalid login prompts");
    if (list.len == 0) return loginFailed(init, "the provider needs no login");

    const input = GetStdHandle(0xfffffff6) orelse return error.Stdin;
    if (input == windows.INVALID_HANDLE_VALUE) return error.Stdin;
    var mode: u32 = 0;
    const console = GetConsoleMode(input, &mode) != 0;
    var answers: std.Io.Writer.Allocating = .init(a);
    // Answers hold secrets; wipe them however this returns.
    defer @memset(answers.writer.buffer, 0);
    var json: std.json.Stringify = .{ .writer = &answers.writer };
    try json.beginObject();
    for (list) |prompt| {
        var line: [4096]u8 = undefined;
        defer @memset(&line, 0);
        if (console) try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "{s}: ", .{prompt.label}));
        const masked = console and prompt.secret;
        const value = if (masked) readMasked(init.io, input, &line, mode) catch |err| {
            try std.Io.File.stderr().writeStreamingAll(init.io, "\n");
            if (err == error.Interrupted) return loginFailed(init, "cancelled");
            return err;
        } else try readLine(input, &line);
        if (masked) try std.Io.File.stderr().writeStreamingAll(init.io, "\n");
        if (value.len == 0) return loginFailed(init, try std.fmt.allocPrint(a, "empty {s}", .{prompt.label}));
        try json.objectField(prompt.name);
        try json.write(value);
    }
    try json.endObject();
    const status = table.login(table.context, .of(answers.written()));
    defer if (status.message.ptr != null) table.free(table.context, status.message);
    if (status.code != 0) return loginFailed(init, status.message.slice());
    try std.Io.File.stdout().writeStreamingAll(init.io, "login saved\n");
    return 0;
}

fn loginFailed(init: std.process.Init, message: []const u8) !u8 {
    const text = if (message.len > 0) message else "provider error";
    try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(init.arena.allocator(), "kowalski: login failed: {s}\n", .{text}));
    return 1;
}

/// A secret typed at the console: one `*` per character, Backspace erases,
/// Ctrl+C cancels. Keys are read raw, so the console mode always comes back.
fn readMasked(io: std.Io, input: windows.HANDLE, buffer: []u8, mode: u32) ![]const u8 {
    // No processed, line or echo input.
    if (SetConsoleMode(input, mode & ~@as(u32, 0x0007)) == 0) return error.ConsoleMode;
    defer _ = SetConsoleMode(input, mode);
    const out = std.Io.File.stderr();
    var len: usize = 0;
    var high: ?u16 = null;
    while (true) {
        var unit: [1]u16 = undefined;
        var read: u32 = 0;
        if (ReadConsoleW(input, &unit, 1, &read, null) == 0) return error.Stdin;
        if (read == 0) continue;
        const u = unit[0];
        switch (u) {
            '\r', '\n' => break,
            0x03 => return error.Interrupted,
            0x08 => {
                if (len > 0) {
                    // Drop one whole UTF-8 character.
                    len -= 1;
                    while (len > 0 and buffer[len] & 0xC0 == 0x80) len -= 1;
                    try out.writeStreamingAll(io, "\x08 \x08");
                }
                continue;
            },
            else => if (u < 0x20) continue,
        }
        var code: u21 = u;
        if (u >= 0xD800 and u < 0xDC00) {
            high = u;
            continue;
        }
        if (u >= 0xDC00 and u < 0xE000) {
            const h = high orelse continue;
            code = 0x10000 + ((@as(u21, h) - 0xD800) << 10) + (u - 0xDC00);
        }
        high = null;
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &encoded) catch continue;
        if (len + n > buffer.len) return error.InputTooLong;
        @memcpy(buffer[len..][0..n], encoded[0..n]);
        len += n;
        try out.writeStreamingAll(io, "*");
    }
    return buffer[0..len];
}

/// One line from stdin into `buffer`.
fn readLine(input: windows.HANDLE, buffer: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        var read: u32 = 0;
        if (ReadFile(input, &byte, 1, &read, null) == 0) return error.Stdin;
        if (read == 0 or byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        if (len == buffer.len) return error.InputTooLong;
        buffer[len] = byte[0];
        len += 1;
    }
    return buffer[0..len];
}

fn usageError() u8 {
    std.debug.print("{s}", .{cli.usage});
    return @backingInt(cli.Exit.usage);
}

/// Starts kowalskiw and waits until it answers. `db` is the --db choice, if any.
fn start(ctx: *cli.Context, db: ?[]const u8) !u8 {
    if (cli.ping(ctx)) {
        std.debug.print("kowalski: the daemon is already running\n", .{});
        return 0;
    }
    try launch.spawn(ctx.a, try launch.backgroundCommand(ctx.a, db));
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
            try launch.setAutostart(a, launch.run_key, try launch.backgroundCommand(a, db));
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
    const zone = try zone_mod.Zone.load(zone_id);
    const now = if (at) |text| localMs(&zone, text) orelse return usageError() else clock.nowMs();
    const instance = if (provider_impl.kowalskiProvider(contract.version)) |table| table.instance.slice() else tour_mod.instance;
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
    _ = @import("cli.zig");
    _ = @import("daemon.zig");
    _ = @import("events.zig");
    _ = @import("launch.zig");
    _ = @import("worker.zig");
}
