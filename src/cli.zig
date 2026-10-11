//! Command-line client. Every command talks to the running daemon over the
//! loopback API; `--json` prints the API's answer unchanged for scripts.
const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const api = @import("api.zig");
const zone = @import("zone.zig");

pub const usage =
    \\usage: kowalski [--db <path>] [--json] <command> [args]
    \\       kowalski --version
    \\
    \\  serve                        run the daemon in this console (one per user)
    \\  start                        start the daemon without a console window
    \\  open                         start the daemon if needed and open the dashboard
    \\  autostart [on|off]           start the daemon at logon, or show the setting
    \\  status                       focus, parallel work and today's numbers
    \\  switch <task> [-m <text>]    focus on a task (created when nothing matches)
    \\  parallel <task> [-m <text>]  open a task next to the focus
    \\  stop <task>                  close a task's open interval
    \\  pause | resume               save and close everything open, or bring it back
    \\  note [-t <task>] <text>      note on the focus, or on the named task
    \\  tasks [<filter>]             tasks by recent use
    \\  new <title>                  create a task without opening it
    \\  rename <#id> <title>         change a task's title
    \\  delete <#id>                 delete a task and its time (not while running or posted)
    \\  day [<YYYY-MM-DD>]           totals, hops, timeline and summary
    \\  summary [<YYYY-MM-DD>] [<text>]  show or set a day's summary ("" clears)
    \\  settings | set <key> <value> | unset <key>
    \\  provider                     the compiled-in provider and its fields
    \\  provider login               sign in to the provider (prompts for the details)
    \\  bind <#id> <ref>             bind a task to an external ref (fields come from the provider)
    \\  postings [<YYYY-MM-DD>]      what can be posted for a day, and what was
    \\  post [<YYYY-MM-DD>] <task> [-m <text>] [-o <option,...>]
    \\                               post a task's focus time for a day
    \\  resolve <posting> posted|not-posted     settle a posting whose outcome is unknown
    \\  shutdown                     stop the daemon
    \\  demo [--lang en|pt|ja] [--at YYYY-MM-DDTHH:MM] [--port N]
    \\                               fill an empty database with made-up history
    \\
    \\A task is `#<id>`, an external ref, or a title (case-insensitive).
    \\The database defaults to <Roaming AppData>\sadirano\kowalski\kowalski.db.
    \\
;

pub const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, no_daemon = 3 };

pub const Context = struct {
    io: Io,
    a: std.mem.Allocator,
    db_path: []const u8,
    json: bool,
    out: *Io.Writer,
    err: *Io.Writer,
};

const Reply = struct { status: u16, body: []const u8 };

pub fn readPort(ctx: *Context) !u16 {
    var db: sqlite.Db = .{};
    db.openReadOnly(ctx.db_path) catch return error.NoDatabase;
    defer db.close();
    var stmt = db.prepare("SELECT value FROM settings WHERE key='http_port'") catch return api.default_port;
    defer stmt.finalize();
    if (try stmt.step() == .done) return api.default_port;
    return std.fmt.parseInt(u16, stmt.columnText(0).?, 10) catch api.default_port;
}

fn call(ctx: *Context, method: []const u8, target: []const u8, body: ?[]const u8) !Reply {
    const port = try readPort(ctx);
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = address.connect(ctx.io, .{ .mode = .stream }) catch return error.NoDaemon;
    defer stream.close(ctx.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(ctx.io, &write_buffer);
    const payload = body orelse "";
    try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nX-Kowalski: 1\r\nConnection: close\r\n", .{ method, target, port });
    if (body != null) try writer.interface.print("Content-Type: application/json\r\nContent-Length: {d}\r\n", .{payload.len});
    try writer.interface.writeAll("\r\n");
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(ctx.io, &read_buffer);
    const raw = try reader.interface.allocRemaining(ctx.a, .limited(64 * 1024 * 1024));
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    if (raw.len < 12 or !std.mem.startsWith(u8, raw, "HTTP/1.1 ")) return error.BadResponse;
    const code = std.fmt.parseInt(u16, raw[9..12], 10) catch return error.BadResponse;
    return .{ .status = code, .body = raw[head_end + 4 ..] };
}

const Task = struct { id: i64, title: []const u8, ref: ?[]const u8 = null };
const Note = struct { at_ms: i64, text: []const u8 };
const Interval = struct {
    task: Task,
    role: []const u8,
    start_ms: i64,
    end_ms: ?i64 = null,
    text: ?[]const u8 = null,
    notes: []Note = &.{},
};
const Numbers = struct {
    total_ms: i64,
    hops: u32,
    working: bool,
    remaining_ms: i64,
    clock_out_ms: ?i64 = null,
    expected_return_ms: ?i64 = null,
    earliest_clock_out_ms: ?i64 = null,
};
const Saved = struct { task: Task, role: []const u8 };
const State = struct {
    now_ms: i64,
    zone: []const u8,
    date: []const u8,
    focus: ?Interval = null,
    parallel: []Interval = &.{},
    saved: []Saved = &.{},
    numbers: Numbers,
    daily_work_minutes: i64,
};
const Posting = struct { id: i64, day: []const u8, task: i64, state: []const u8, amount_text: []const u8, start: ?[]const u8 = null, end: ?[]const u8 = null };
const Failure = struct { @"error": []const u8, message: []const u8 = "", candidates: ?[]Task = null, posting: ?Posting = null };

fn parse(comptime T: type, ctx: *Context, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, ctx.a, body, .{ .ignore_unknown_fields = true });
}

fn writeTask(w: *Io.Writer, t: Task) !void {
    try w.print("#{d} {s}", .{ t.id, t.title });
    if (t.ref) |ref| try w.print(" [{s}]", .{ref});
}

fn duration(w: *Io.Writer, ms: i64) !void {
    const minutes = @divFloor(@max(ms, 0), 60_000);
    if (minutes >= 60) try w.print("{d}h {d:0>2}m", .{ @divFloor(minutes, 60), @mod(minutes, 60) }) else try w.print("{d}m", .{minutes});
}

fn clockTime(w: *Io.Writer, z: *const zone.Zone, ms: i64) !void {
    const t = try z.localOf(ms);
    try w.print("{d:0>2}:{d:0>2}", .{ t.hour, t.minute });
}

/// Whether a daemon answers on this database's port.
pub fn ping(ctx: *Context) bool {
    const reply = call(ctx, "GET", "/api/health", null) catch return false;
    return reply.status == 200;
}

/// Runs one command. Output goes to ctx.out / ctx.err; the caller flushes.
pub fn run(ctx: *Context, command: []const u8, args: []const []const u8) !Exit {
    return dispatch(ctx, command, args) catch |err| switch (err) {
        error.NoDaemon => {
            try ctx.err.writeAll("kowalski: the daemon is not running (start it with: kowalski start)\n");
            return .no_daemon;
        },
        error.NoDatabase => {
            try ctx.err.print("kowalski: no database at {s} (run kowalski start once)\n", .{ctx.db_path});
            return .no_daemon;
        },
        error.Usage => {
            try ctx.err.writeAll(usage);
            return .usage;
        },
        else => return err,
    };
}

fn joined(ctx: *Context, words: []const []const u8) ![]const u8 {
    return std.mem.join(ctx.a, " ", words);
}

/// Splits `-flag value` pairs (named in `flags`) from the free words.
fn options(ctx: *Context, args: []const []const u8, comptime flags: []const []const u8) !struct { words: []const []const u8, values: [flags.len]?[]const u8 } {
    var words: std.ArrayList([]const u8) = .empty;
    var values: [flags.len]?[]const u8 = @splat(null);
    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        inline for (flags, 0..) |flag, f| {
            if (std.mem.eql(u8, args[i], flag)) {
                if (i + 1 >= args.len) return error.Usage;
                values[f] = args[i + 1];
                i += 1;
                continue :outer;
            }
        }
        try words.append(ctx.a, args[i]);
    }
    return .{ .words = words.items, .values = values };
}

fn jsonBody(ctx: *Context, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(ctx.a, value, .{});
}

fn pathEscape(ctx: *Context, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_') try out.append(ctx.a, ch) else try out.print(ctx.a, "%{X:0>2}", .{ch});
    }
    return out.items;
}

/// Prints the reply as JSON when asked, or reports a failure. True when the
/// caller should render a success.
fn settle(ctx: *Context, reply: Reply) !bool {
    if (reply.status >= 200 and reply.status < 300) {
        if (ctx.json) {
            try ctx.out.writeAll(reply.body);
            try ctx.out.writeAll("\n");
            return false;
        }
        return true;
    }
    if (ctx.json) {
        try ctx.out.writeAll(reply.body);
        try ctx.out.writeAll("\n");
        return error.Reported;
    }
    const f = parse(Failure, ctx, reply.body) catch {
        try ctx.err.print("kowalski: HTTP {d}\n", .{reply.status});
        return error.Reported;
    };
    try ctx.err.print("kowalski: {s}", .{f.@"error"});
    if (f.message.len > 0) try ctx.err.print(": {s}", .{f.message});
    try ctx.err.writeAll("\n");
    if (f.candidates) |list| for (list) |t| {
        try ctx.err.writeAll("  ");
        try writeTask(ctx.err, t);
        try ctx.err.writeAll("\n");
    };
    if (f.posting) |p| {
        try ctx.err.print("  posting #{d} is {s}", .{ p.id, p.state });
        if (std.mem.eql(u8, p.state, "unknown")) try ctx.err.print(" (check the remote, then: kowalski resolve {d} posted|not-posted)", .{p.id});
        try ctx.err.writeAll("\n");
    }
    return error.Reported;
}

fn dispatch(ctx: *Context, command: []const u8, args: []const []const u8) !Exit {
    return dispatchInner(ctx, command, args) catch |err| switch (err) {
        error.Reported => .failed,
        else => err,
    };
}

fn dispatchInner(ctx: *Context, command: []const u8, args: []const []const u8) !Exit {
    const eql = std.mem.eql;
    if (eql(u8, command, "status")) {
        if (args.len != 0) return error.Usage;
        return status(ctx);
    }
    if (eql(u8, command, "switch") or eql(u8, command, "parallel")) {
        const o = try options(ctx, args, &.{ "-m", "--text" });
        if (o.words.len == 0) return error.Usage;
        const text = o.values[0] orelse o.values[1];
        const target = if (eql(u8, command, "switch")) "/api/switch" else "/api/parallel";
        const reply = try call(ctx, "POST", target, try jsonBody(ctx, .{ .task = try joined(ctx, o.words), .text = text }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { task: Task, created: bool }, ctx, reply.body);
        try ctx.out.writeAll(if (eql(u8, command, "switch")) "focus     " else "parallel  ");
        try writeTask(ctx.out, r.task);
        try ctx.out.writeAll(if (r.created) " (new task)\n" else "\n");
        return .ok;
    }
    if (eql(u8, command, "stop")) {
        if (args.len == 0) return error.Usage;
        const reply = try call(ctx, "POST", "/api/stop", try jsonBody(ctx, .{ .task = try joined(ctx, args) }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { task: Task }, ctx, reply.body);
        try ctx.out.writeAll("stopped   ");
        try writeTask(ctx.out, r.task);
        try ctx.out.writeAll("\n");
        return .ok;
    }
    if (eql(u8, command, "pause") or eql(u8, command, "resume")) {
        if (args.len != 0) return error.Usage;
        const reply = try call(ctx, "POST", if (eql(u8, command, "pause")) "/api/pause" else "/api/resume", "");
        if (!try settle(ctx, reply)) return .ok;
        try renderState(ctx, try parse(State, ctx, reply.body));
        return .ok;
    }
    if (eql(u8, command, "note")) {
        const o = try options(ctx, args, &.{ "-t", "--task" });
        if (o.words.len == 0) return error.Usage;
        const task = o.values[0] orelse o.values[1];
        const reply = try call(ctx, "POST", "/api/notes", try jsonBody(ctx, .{ .task = task, .text = try joined(ctx, o.words) }));
        if (!try settle(ctx, reply)) return .ok;
        try ctx.out.writeAll("noted\n");
        return .ok;
    }
    if (eql(u8, command, "tasks")) {
        const target = if (args.len == 0) "/api/tasks?limit=40" else try std.fmt.allocPrint(ctx.a, "/api/tasks?limit=200&q={s}", .{try pathEscape(ctx, try joined(ctx, args))});
        const reply = try call(ctx, "GET", target, null);
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { tasks: []struct { id: i64, title: []const u8, ref: ?[]const u8 = null, last_ms: ?i64 = null } }, ctx, reply.body);
        const z = try currentZone(ctx);
        for (r.tasks) |t| {
            var id_buf: [24]u8 = undefined;
            try ctx.out.print("{s: <6} ", .{try std.fmt.bufPrint(&id_buf, "#{d}", .{t.id})});
            if (t.last_ms) |ms| {
                const local = try z.localOf(ms);
                try ctx.out.print("{d:0>4}-{d:0>2}-{d:0>2}  ", .{ local.year, local.month, local.day });
            } else try ctx.out.writeAll("never       ");
            try ctx.out.print("{s}", .{t.title});
            if (t.ref) |ref| try ctx.out.print(" [{s}]", .{ref});
            try ctx.out.writeAll("\n");
        }
        return .ok;
    }
    if (eql(u8, command, "new")) {
        if (args.len == 0) return error.Usage;
        const reply = try call(ctx, "POST", "/api/tasks", try jsonBody(ctx, .{ .title = try joined(ctx, args) }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { task: Task }, ctx, reply.body);
        try ctx.out.writeAll("created   ");
        try writeTask(ctx.out, r.task);
        try ctx.out.writeAll("\n");
        return .ok;
    }
    if (eql(u8, command, "rename")) {
        if (args.len < 2) return error.Usage;
        const id_text = if (std.mem.startsWith(u8, args[0], "#")) args[0][1..] else args[0];
        const id = std.fmt.parseInt(i64, id_text, 10) catch return error.Usage;
        const reply = try call(ctx, "PATCH", try std.fmt.allocPrint(ctx.a, "/api/tasks/{d}", .{id}), try jsonBody(ctx, .{ .title = try joined(ctx, args[1..]) }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { task: Task }, ctx, reply.body);
        try ctx.out.writeAll("renamed   ");
        try writeTask(ctx.out, r.task);
        try ctx.out.writeAll("\n");
        return .ok;
    }
    if (eql(u8, command, "delete")) {
        if (args.len != 1) return error.Usage;
        const id_text = if (std.mem.startsWith(u8, args[0], "#")) args[0][1..] else args[0];
        const id = std.fmt.parseInt(i64, id_text, 10) catch return error.Usage;
        const reply = try call(ctx, "POST", try std.fmt.allocPrint(ctx.a, "/api/tasks/{d}/delete", .{id}), "{}");
        if (!try settle(ctx, reply)) return .ok;
        try ctx.out.print("deleted   #{d}\n", .{id});
        return .ok;
    }
    if (eql(u8, command, "day")) {
        if (args.len > 1) return error.Usage;
        const target = if (args.len == 1) try std.fmt.allocPrint(ctx.a, "/api/day?date={s}", .{try pathEscape(ctx, args[0])}) else "/api/day";
        const reply = try call(ctx, "GET", target, null);
        if (!try settle(ctx, reply)) return .ok;
        try renderDay(ctx, reply.body);
        return .ok;
    }
    if (eql(u8, command, "summary")) {
        var rest = args;
        var date: ?[]const u8 = null;
        if (rest.len > 0 and isDate(rest[0])) {
            date = rest[0];
            rest = rest[1..];
        }
        if (rest.len == 0) {
            const target = if (date) |d| try std.fmt.allocPrint(ctx.a, "/api/summary?date={s}", .{d}) else "/api/summary";
            const reply = try call(ctx, "GET", target, null);
            if (!try settle(ctx, reply)) return .ok;
            const r = try parse(struct { date: []const u8, text: ?[]const u8 = null }, ctx, reply.body);
            try ctx.out.print("{s}  {s}\n", .{ r.date, r.text orelse "(no summary)" });
            return .ok;
        }
        const day_text = date orelse blk: {
            const s = try fetchState(ctx);
            break :blk s.date;
        };
        const reply = try call(ctx, "POST", "/api/summary", try jsonBody(ctx, .{ .date = day_text, .text = try joined(ctx, rest) }));
        if (!try settle(ctx, reply)) return .ok;
        try ctx.out.print("summary saved for {s}\n", .{day_text});
        return .ok;
    }
    if (eql(u8, command, "settings")) {
        if (args.len != 0) return error.Usage;
        const reply = try call(ctx, "GET", "/api/settings", null);
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { settings: []struct { key: []const u8, value: []const u8 } }, ctx, reply.body);
        for (r.settings) |s| try ctx.out.print("{s: <20} {s}\n", .{ s.key, s.value });
        return .ok;
    }
    if (eql(u8, command, "set") or eql(u8, command, "unset")) {
        const setting = eql(u8, command, "set");
        if ((setting and args.len < 2) or (!setting and args.len != 1)) return error.Usage;
        var body: std.json.ObjectMap = .empty;
        try body.put(ctx.a, args[0], if (setting) .{ .string = try joined(ctx, args[1..]) } else .null);
        const reply = try call(ctx, "PATCH", "/api/settings", try jsonBody(ctx, std.json.Value{ .object = body }));
        if (!try settle(ctx, reply)) return .ok;
        try ctx.out.print("{s} {s}\n", .{ if (setting) "set" else "unset", args[0] });
        if (std.mem.eql(u8, args[0], "http_port")) try ctx.out.writeAll("restart the daemon to listen on the new port\n");
        return .ok;
    }
    if (eql(u8, command, "provider")) {
        if (args.len != 0) return error.Usage;
        const reply = try call(ctx, "GET", "/api/provider", null);
        if (!try settle(ctx, reply)) return .ok;
        const Named = struct { name: []const u8, label: []const u8 = "" };
        const r = try parse(struct { instance: ?[]const u8, fields: []Named, settings: []Named = &.{}, post_options: []Named = &.{}, sessions: bool = false }, ctx, reply.body);
        const instance = r.instance orelse {
            try ctx.out.writeAll("no provider in this build\n");
            return .ok;
        };
        try ctx.out.print("provider  {s}\n", .{instance});
        if (r.sessions) try ctx.out.writeAll("sessions: supported (kowalski set post_sessions 1)\n");
        for (r.fields) |f| try ctx.out.print("  {s: <16} {s}\n", .{ f.name, f.label });
        if (r.settings.len > 0) try ctx.out.writeAll("settings (kowalski set provider.<name> <value>)\n");
        for (r.settings) |f| try ctx.out.print("  {s: <16} {s}\n", .{ f.name, f.label });
        if (r.post_options.len > 0) try ctx.out.writeAll("post options (post -o <name>)\n");
        for (r.post_options) |f| try ctx.out.print("  {s: <16} {s}\n", .{ f.name, f.label });
        return .ok;
    }
    if (eql(u8, command, "bind")) {
        if (args.len != 2) return error.Usage;
        const id_text = if (std.mem.startsWith(u8, args[0], "#")) args[0][1..] else args[0];
        const id = std.fmt.parseInt(i64, id_text, 10) catch return error.Usage;
        const reply = try call(ctx, "POST", try std.fmt.allocPrint(ctx.a, "/api/tasks/{d}/bind", .{id}), try jsonBody(ctx, .{ .ref = args[1] }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { task: Task, remote_title: ?[]const u8 = null, fields: []struct { name: []const u8, value: []const u8 } }, ctx, reply.body);
        try ctx.out.writeAll("bound     ");
        try writeTask(ctx.out, r.task);
        try ctx.out.writeAll("\n");
        if (r.remote_title) |t| try ctx.out.print("  remote title  {s}\n", .{t});
        for (r.fields) |f| try ctx.out.print("  {s: <13} {s}\n", .{ f.name, f.value });
        return .ok;
    }
    if (eql(u8, command, "postings")) {
        if (args.len > 1) return error.Usage;
        const target = if (args.len == 1) try std.fmt.allocPrint(ctx.a, "/api/postings?date={s}", .{try pathEscape(ctx, args[0])}) else "/api/postings";
        const reply = try call(ctx, "GET", target, null);
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { date: []const u8, instance: ?[]const u8 = null, sessions_mode: bool = false, offers: []struct { task: Task, total_focus_ms: i64, postable: bool, ref: ?[]const u8 = null, postings: []Posting, sessions: []struct { start: []const u8, end: []const u8 } = &.{}, open_session: bool = false } }, ctx, reply.body);
        try ctx.out.print("{s}  provider {s}\n", .{ r.date, r.instance orelse "(none)" });
        for (r.offers) |o| {
            try ctx.out.writeAll(if (o.postable) "  postable    " else if (o.ref == null) "  not bound   " else "  -           ");
            try duration(ctx.out, o.total_focus_ms);
            try ctx.out.writeAll("  ");
            try writeTask(ctx.out, o.task);
            try ctx.out.writeAll("\n");
            if (r.sessions_mode) {
                if (o.sessions.len > 0) {
                    try ctx.out.writeAll("      sessions ");
                    for (o.sessions, 0..) |s, i| {
                        if (i > 0) try ctx.out.writeAll(", ");
                        try ctx.out.print("{s}-{s}", .{ s.start, s.end });
                    }
                    try ctx.out.writeAll("\n");
                }
                if (o.open_session) try ctx.out.writeAll("      (running session not included)\n");
            }
            for (o.postings) |p| try ctx.out.print("      posting #{d} {s} {s}\n", .{ p.id, p.state, p.amount_text });
        }
        return .ok;
    }
    if (eql(u8, command, "post")) {
        const o = try options(ctx, args, &.{ "-m", "--text", "-o", "--option" });
        var words = o.words;
        // `-o a,b` turns on the provider's post options a and b.
        var chosen: std.json.ArrayHashMap(bool) = .{};
        if (o.values[2] orelse o.values[3]) |list| {
            var names = std.mem.tokenizeScalar(u8, list, ',');
            while (names.next()) |name| try chosen.map.put(ctx.a, std.mem.trim(u8, name, " "), true);
        }
        var date: ?[]const u8 = null;
        if (words.len > 0 and isDate(words[0])) {
            date = words[0];
            words = words[1..];
        }
        if (words.len == 0) return error.Usage;
        const reply = try call(ctx, "POST", "/api/postings", try jsonBody(ctx, .{ .date = date, .task = try joined(ctx, words), .text = o.values[0] orelse o.values[1], .options = chosen }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { posting: Posting, postings: ?[]Posting = null }, ctx, reply.body);
        if (r.postings) |all| {
            for (all) |p| try ctx.out.print("posted    #{d} {s} on {s} (task #{d}) {s}-{s}\n", .{ p.id, p.amount_text, p.day, p.task, p.start orelse "", p.end orelse "" });
        } else try ctx.out.print("posted    #{d} {s} on {s} (task #{d})\n", .{ r.posting.id, r.posting.amount_text, r.posting.day, r.posting.task });
        return .ok;
    }
    if (eql(u8, command, "resolve")) {
        if (args.len != 2) return error.Usage;
        const id_text = if (std.mem.startsWith(u8, args[0], "#")) args[0][1..] else args[0];
        const id = std.fmt.parseInt(i64, id_text, 10) catch return error.Usage;
        const posted = if (eql(u8, args[1], "posted")) true else if (eql(u8, args[1], "not-posted")) false else return error.Usage;
        const reply = try call(ctx, "POST", try std.fmt.allocPrint(ctx.a, "/api/postings/{d}/resolve", .{id}), try jsonBody(ctx, .{ .posted = posted }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { posting: Posting }, ctx, reply.body);
        try ctx.out.print("posting   #{d} is {s}\n", .{ r.posting.id, r.posting.state });
        return .ok;
    }
    if (eql(u8, command, "shutdown")) {
        if (args.len != 0) return error.Usage;
        const reply = try call(ctx, "POST", "/api/shutdown", "");
        if (!try settle(ctx, reply)) return .ok;
        try ctx.out.writeAll("daemon stopping\n");
        return .ok;
    }
    return error.Usage;
}

fn isDate(text: []const u8) bool {
    var scratch: [16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    _ = api.parseDate(fba.allocator(), text) catch return false;
    return true;
}

fn fetchState(ctx: *Context) !State {
    const reply = try call(ctx, "GET", "/api/state", null);
    const saved_json = ctx.json;
    ctx.json = false;
    defer ctx.json = saved_json;
    _ = try settle(ctx, reply);
    return parse(State, ctx, reply.body);
}

fn currentZone(ctx: *Context) !zone.Zone {
    const s = try fetchState(ctx);
    return zone.Zone.load(s.zone);
}

fn status(ctx: *Context) !Exit {
    const reply = try call(ctx, "GET", "/api/state", null);
    if (!try settle(ctx, reply)) return .ok;
    try renderState(ctx, try parse(State, ctx, reply.body));
    return .ok;
}

fn renderOpen(ctx: *Context, z: *const zone.Zone, label: []const u8, i: Interval, now: i64) !void {
    const w = ctx.out;
    try w.print("{s: <10}", .{label});
    try writeTask(w, i.task);
    try w.writeAll("  since ");
    try clockTime(w, z, i.start_ms);
    try w.writeAll(" (");
    try duration(w, now - i.start_ms);
    try w.writeAll(")\n");
}

fn renderState(ctx: *Context, s: State) !void {
    const w = ctx.out;
    const z = try zone.Zone.load(s.zone);
    if (s.focus) |f| try renderOpen(ctx, &z, "focus", f, s.now_ms) else try w.writeAll("focus     (none)\n");
    for (s.parallel) |p| try renderOpen(ctx, &z, "parallel", p, s.now_ms);
    if (s.focus == null and s.parallel.len == 0 and s.saved.len > 0) {
        try w.writeAll("paused    resume brings back:");
        for (s.saved) |item| {
            try w.writeAll(" ");
            try writeTask(w, item.task);
            try w.print(" ({s})", .{item.role});
        }
        try w.writeAll("\n");
    }
    const n = s.numbers;
    try w.print("today     ", .{});
    try duration(w, n.total_ms);
    try w.writeAll(" of ");
    try duration(w, s.daily_work_minutes * 60_000);
    try w.print(", {d} hop{s}", .{ n.hops, if (n.hops == 1) "" else "s" });
    if (n.clock_out_ms) |ms| {
        try w.writeAll(", clock-out ");
        try clockTime(w, &z, ms);
    } else if (n.earliest_clock_out_ms) |ms| {
        if (n.expected_return_ms) |back| if (back > s.now_ms) {
            try w.writeAll(", back by ");
            try clockTime(w, &z, back);
        };
        try w.writeAll(", clock-out ");
        try clockTime(w, &z, ms);
    }
    try w.writeAll("\n");
}

fn renderDay(ctx: *Context, body: []const u8) !void {
    const Day = struct {
        date: []const u8,
        zone: []const u8,
        numbers: Numbers,
        tasks: []struct { task: Task, focus_ms: i64, hops: u32 },
        intervals: []Interval,
        summary: ?[]const u8 = null,
    };
    const d = try parse(Day, ctx, body);
    const z = try zone.Zone.load(d.zone);
    const w = ctx.out;
    try w.print("{s}  ", .{d.date});
    try duration(w, d.numbers.total_ms);
    try w.print(" focus, {d} hop{s}\n\n", .{ d.numbers.hops, if (d.numbers.hops == 1) "" else "s" });
    for (d.tasks) |t| {
        try w.writeAll("  ");
        var buf: [16]u8 = undefined;
        var fw: Io.Writer = .fixed(&buf);
        try duration(&fw, t.focus_ms);
        try w.print("{s: >8}  ", .{fw.buffered()});
        try writeTask(w, t.task);
        if (t.hops > 0) try w.print("  ({d} hop{s})", .{ t.hops, if (t.hops == 1) "" else "s" });
        try w.writeAll("\n");
    }
    if (d.intervals.len > 0) try w.writeAll("\n");
    for (d.intervals) |i| {
        try w.writeAll("  ");
        try clockTime(w, &z, i.start_ms);
        try w.writeAll("-");
        if (i.end_ms) |end| try clockTime(w, &z, end) else try w.writeAll("now  ");
        try w.writeAll(if (std.mem.eql(u8, i.role, "focus")) "  " else "  + ");
        try writeTask(w, i.task);
        if (i.text) |text| try w.print("  \"{s}\"", .{text});
        try w.writeAll("\n");
        for (i.notes) |note| {
            try w.writeAll("        ");
            try clockTime(w, &z, note.at_ms);
            try w.print("  {s}\n", .{note.text});
        }
    }
    if (d.summary) |text| try w.print("\nsummary: {s}\n", .{text});
}
