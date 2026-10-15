//! Command-line client. Every command talks to the running daemon over the
//! loopback API; `--json` prints the API's answer unchanged for scripts.
const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const api = @import("api.zig");
const store_mod = @import("store.zig");
const zone = @import("zone.zig");
const windows = std.os.windows;

extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetConsoleMode(handle: windows.HANDLE, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(handle: windows.HANDLE, mode: u32) callconv(.winapi) i32;
extern "kernel32" fn ReadConsoleW(handle: windows.HANDLE, buffer: [*]u16, len: u32, read: *u32, control: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(handle: windows.HANDLE, data: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;

pub const usage =
    \\usage: kowalski [--db <path>] [--json] <command> [args]
    \\       kowalski --version
    \\
    \\  serve                        run the daemon in this console (one per user)
    \\  start                        start the daemon without a console window
    \\  open                         start the daemon if needed and open the dashboard
    \\  autostart [on|off]           start the daemon at logon, or show the setting
    \\  status                       focus, parallel work and today's numbers
    \\  switch|track [--project <#id|unassigned>] <task> [-m <text>]
    \\  parallel [--project <#id|unassigned>] <task> [-m <text>]
    \\  stop <task>                  close a task's open interval
    \\  pause | resume               save and close everything open, or bring it back
    \\  note [-t <task>] <text>      note on the focus, or on the named task
    \\  capture <kind> --source <s> --run <r> [--event <id>] [--subject <task>]
    \\          [--default <task>] [--project-key <key>] [--project-hint <hint>]
    \\          [--first-prompt <text>] [--unattended]
    \\                               record an outside run (start|subject|prompt|busy|stop|end)
    \\  tasks [<filter>]             tasks by recent use
    \\  new <title>                  create a task without opening it
    \\  rename <#id> <title>         change a task's title
    \\  project list [--all]         list projects
    \\  project add <label>          add a project
    \\  project rename <#id> <label> rename a project
    \\  project archive <#id> [--undo]  archive or unarchive
    \\  project assign <#id|unassigned> --task <#id> [--apply <hash>]
    \\  project assign <#id|unassigned> --interval <#id>... [--apply <hash>]
    \\  project assign <#id|unassigned> --suggest [--apply <hash>]
    \\  delete <#id>                 delete a task and its time (not while running or posted)
    \\  day [<YYYY-MM-DD>]           totals, hops, timeline and summary
    \\  summary [<YYYY-MM-DD>] [<text>]  show or set a day's summary ("" clears)
    \\  settings | set <key> <value> | unset <key>
    \\  provider                     provider status and fields
    \\  provider trust <sha256>      approve a DLL against a known SHA-256
    \\  provider trust --current     accept the current DLL as it is
    \\  provider source <S> --key <hex> [--yes]  enroll a signed source
    \\  provider source --from-setup --key <hex>|--accept-as-is [--yes]
    \\  provider source --stop       return to manual DLL discovery
    \\  provider check               check the signed source
    \\  provider install [--sequence N] [--yes]  install a verified release
    \\  provider login               sign in to the provider (prompts for the details)
    \\  bind <#id> <ref>             bind a task to an external ref (fields come from the provider)
    \\  postings [<YYYY-MM-DD>]      what can be posted for a day, and what was
    \\  post [<YYYY-MM-DD>] <task> [-m <text>] [-o <option,...>]
    \\                               post a task's focus time for a day
    \\  resolve <posting> posted|not-posted     settle a posting whose outcome is unknown
    \\  shutdown                     stop the daemon
    \\  restart                      restart the daemon to load an approved provider
    \\  update [--yes] | --from <zip> check for a release or install a signed local ZIP
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
    call_override: ?*const fn (*Context, []const u8, []const u8, ?[]const u8) anyerror!Reply = null,
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
    if (ctx.call_override) |override| return override(ctx, method, target, body);
    const port = try readPort(ctx);
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = address.connect(ctx.io, .{ .mode = .stream }) catch return error.NoDaemon;
    defer stream.close(ctx.io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(ctx.io, &write_buffer);
    const payload = body orelse "";
    try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nX-Kowalski: 1\r\nConnection: close\r\n", .{ method, target, port });
    if (body) |data| if (std.mem.indexOf(u8, data, "\"file\":") != null) try writer.interface.writeAll("X-Kowalski-Local-File: 1\r\n");
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
    day_start_min: u16 = 0,
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

fn hashId(text: []const u8) !i64 {
    if (text.len < 2 or text[0] != '#') return error.Usage;
    const id = std.fmt.parseInt(i64, text[1..], 10) catch return error.Usage;
    if (id <= 0) return error.Usage;
    return id;
}

fn projectId(text: []const u8) !?i64 {
    if (std.mem.eql(u8, text, "unassigned")) return null;
    return try hashId(text);
}

const Project = struct { id: i64, label: []const u8, archived: bool };

fn projectLabel(projects: []const Project, id: ?i64) []const u8 {
    const wanted = id orelse return "Unassigned";
    for (projects) |project| if (project.id == wanted) return project.label;
    return "(missing project)";
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

fn providerLogin(ctx: *Context) !Exit {
    const reply = try call(ctx, "GET", "/api/provider/login", null);
    if (reply.status < 200 or reply.status >= 300) {
        _ = try settle(ctx, reply);
        return .failed;
    }
    const Prompt = struct { name: []const u8, label: []const u8, secret: bool = false };
    const listed = try parse(struct { prompts: []Prompt }, ctx, reply.body);
    if (listed.prompts.len == 0) {
        try ctx.err.writeAll("kowalski: login failed: the provider needs no login\n");
        return .failed;
    }
    const input = GetStdHandle(0xfffffff6) orelse return error.Stdin;
    if (input == windows.INVALID_HANDLE_VALUE) return error.Stdin;
    var mode: u32 = 0;
    const console = GetConsoleMode(input, &mode) != 0;
    var answers: Io.Writer.Allocating = .init(ctx.a);
    // Answers hold secrets; wipe them however this returns.
    defer @memset(answers.writer.buffer, 0);
    var json: std.json.Stringify = .{ .writer = &answers.writer };
    try json.beginObject();
    for (listed.prompts) |prompt| {
        var line: [4096]u8 = undefined;
        defer @memset(&line, 0);
        if (console) {
            const out = Io.File.stderr();
            for (prompt.label) |c| {
                const printable: [1]u8 = .{if (std.ascii.isPrint(c)) c else '?'};
                try out.writeStreamingAll(ctx.io, &printable);
            }
            try out.writeStreamingAll(ctx.io, ": ");
        }
        const masked = console and prompt.secret;
        const value = if (masked) readMasked(ctx.io, input, &line, mode) catch |err| {
            try Io.File.stderr().writeStreamingAll(ctx.io, "\n");
            if (err == error.Interrupted) {
                try ctx.err.writeAll("kowalski: login failed: cancelled\n");
                return .failed;
            }
            return err;
        } else try readLine(input, &line);
        if (masked) try Io.File.stderr().writeStreamingAll(ctx.io, "\n");
        if (value.len == 0) {
            try ctx.err.writeAll("kowalski: login failed: empty answer\n");
            return .failed;
        }
        try json.objectField(prompt.name);
        try json.write(value);
    }
    try json.endObject();
    const signed = try call(ctx, "POST", "/api/provider/login", answers.written());
    if (!try settle(ctx, signed)) return .ok;
    try ctx.out.writeAll("signed in\n");
    return .ok;
}

/// A secret typed at the console: one `*` per character, Backspace erases,
/// Ctrl+C cancels. Keys are read raw, so the console mode always comes back.
fn readMasked(io: Io, input: windows.HANDLE, buffer: []u8, mode: u32) ![]const u8 {
    if (SetConsoleMode(input, mode & ~@as(u32, 0x0007)) == 0) return error.ConsoleMode;
    defer _ = SetConsoleMode(input, mode);
    const out = Io.File.stderr();
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
                    len -= 1;
                    while (len > 0 and buffer[len] & 0xC0 == 0x80) len -= 1;
                    try out.writeStreamingAll(io, "\x08 \x08");
                }
                continue;
            },
            else => if (u < 0x20) continue,
        }
        var code: u21 = u;
        if (u >= 0xD800 and u < 0xDC00) { high = u; continue; }
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
    if (std.mem.eql(u8, f.@"error", "update_unsigned") or std.mem.eql(u8, f.@"error", "update_bad_signature")) {
        try ctx.err.print("kowalski: {s}\n", .{f.message});
        return error.Reported;
    }
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

fn projectCommand(ctx: *Context, args: []const []const u8) !Exit {
    if (args.len == 0) return error.Usage;
    const eql = std.mem.eql;
    if (eql(u8, args[0], "list")) {
        if (args.len > 2 or (args.len == 2 and !eql(u8, args[1], "--all"))) return error.Usage;
        const reply = try call(ctx, "GET", if (args.len == 2) "/api/projects?archived=1" else "/api/projects", null);
        if (!try settle(ctx, reply)) return .ok;
        const list = try parse(struct { projects: []Project }, ctx, reply.body);
        for (list.projects) |project| try ctx.out.print("#{d} {s}{s}\n", .{ project.id, project.label, if (project.archived) " (archived)" else "" });
        return .ok;
    }
    if (eql(u8, args[0], "add")) {
        if (args.len < 2) return error.Usage;
        const reply = try call(ctx, "POST", "/api/projects", try jsonBody(ctx, .{ .label = try joined(ctx, args[1..]) }));
        if (!try settle(ctx, reply)) return .ok;
        const result = try parse(struct { project: Project }, ctx, reply.body);
        try ctx.out.print("#{d} {s}\n", .{ result.project.id, result.project.label });
        return .ok;
    }
    if (eql(u8, args[0], "rename")) {
        if (args.len < 3) return error.Usage;
        const id = try hashId(args[1]);
        const reply = try call(ctx, "PATCH", try std.fmt.allocPrint(ctx.a, "/api/projects/{d}", .{id}), try jsonBody(ctx, .{ .label = try joined(ctx, args[2..]) }));
        if (!try settle(ctx, reply)) return .ok;
        const result = try parse(struct { project: Project }, ctx, reply.body);
        try ctx.out.print("#{d} {s}\n", .{ result.project.id, result.project.label });
        return .ok;
    }
    if (eql(u8, args[0], "archive")) {
        if (args.len < 2 or args.len > 3 or (args.len == 3 and !eql(u8, args[2], "--undo"))) return error.Usage;
        const id = try hashId(args[1]);
        const archived = args.len == 2;
        const reply = try call(ctx, "PATCH", try std.fmt.allocPrint(ctx.a, "/api/projects/{d}", .{id}), try jsonBody(ctx, .{ .archived = archived }));
        if (!try settle(ctx, reply)) return .ok;
        try ctx.out.print("#{d} {s}\n", .{ id, if (archived) "archived" else "active" });
        return .ok;
    }
    if (eql(u8, args[0], "assign")) {
        if (args.len < 3) return error.Usage;
        const target = try projectId(args[1]);
        var task: ?i64 = null;
        var intervals: std.ArrayList(i64) = .empty;
        var suggest = false;
        var apply_hash: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (eql(u8, args[i], "--task")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                task = try hashId(args[i]);
            } else if (eql(u8, args[i], "--interval")) {
                i += 1;
                if (i >= args.len or !std.mem.startsWith(u8, args[i], "#")) return error.Usage;
                while (i < args.len and std.mem.startsWith(u8, args[i], "#")) : (i += 1) try intervals.append(ctx.a, try hashId(args[i]));
                i -= 1;
            } else if (eql(u8, args[i], "--suggest")) suggest = true
            else if (eql(u8, args[i], "--apply")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                apply_hash = args[i];
            }
            else return error.Usage;
        }
        const modes: u8 = @intFromBool(task != null) + @as(u8, @intFromBool(intervals.items.len > 0)) + @as(u8, @intFromBool(suggest));
        if (modes != 1) return error.Usage;
        const scope = .{ .task_id = task, .interval_ids = if (intervals.items.len > 0) @as(?[]const i64, intervals.items) else null, .unassigned_suggestions = suggest };
        const preview_reply = try call(ctx, "POST", "/api/projects/assign/preview", try jsonBody(ctx, .{ .scope = scope, .project_id = target }));
        if (preview_reply.status < 200 or preview_reply.status >= 300) {
            _ = try settle(ctx, preview_reply);
            return .failed;
        }
        const preview = try parse(store_mod.AssignmentPreview, ctx, preview_reply.body);
        const snapshot_json = try std.json.Stringify.valueAlloc(ctx.a, preview.snapshot, .{});
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(snapshot_json, &digest, .{});
        const alphabet = "0123456789abcdef";
        var seen_hash: [16]u8 = undefined;
        for (digest[0..8], 0..) |byte, n| {
            seen_hash[n * 2] = alphabet[byte >> 4];
            seen_hash[n * 2 + 1] = alphabet[byte & 15];
        }
        if (!ctx.json) {
            const project_reply = try call(ctx, "GET", "/api/projects?archived=1", null);
            if (project_reply.status < 200 or project_reply.status >= 300) {
                _ = try settle(ctx, project_reply);
                return .failed;
            }
            const all = try parse(struct { projects: []Project }, ctx, project_reply.body);
            for (preview.snapshot.intervals) |row| try ctx.out.print("#{d} {s} -> {s} ({d} ms focus)\n", .{ row.id, projectLabel(all.projects, row.project_id), projectLabel(all.projects, target), row.focus_ms });
            for (preview.snapshot.totals) |total| try ctx.out.print("{s} {s}: {d} ms focus\n", .{ total.date, projectLabel(all.projects, total.project_id), total.focus_ms });
            for (preview.skipped) |row| try ctx.out.print("#{d} skipped (open)\n", .{row.id});
        } else if (apply_hash == null) {
            try ctx.out.writeAll(preview_reply.body);
            try ctx.out.writeAll("\n");
        }
        if (apply_hash == null) {
            try ctx.out.print("preview hash: {s}\n", .{seen_hash});
            return .ok;
        }
        if (!std.mem.eql(u8, apply_hash.?, &seen_hash)) {
            try ctx.out.print("preview changed: expected {s}, got {s}; preview again before applying\n", .{ apply_hash.?, seen_hash });
            return .failed;
        }
        const apply_reply = try call(ctx, "POST", "/api/projects/assign/apply", try jsonBody(ctx, .{ .snapshot = preview.snapshot }));
        if (!try settle(ctx, apply_reply)) return .ok;
        const result = try parse(store_mod.AssignmentResult, ctx, apply_reply.body);
        try ctx.out.print("changed {d} intervals ({d} ms focus)\n", .{ result.changed, result.focus_ms });
        return .ok;
    }
    return error.Usage;
}

fn dispatchInner(ctx: *Context, command: []const u8, args: []const []const u8) !Exit {
    const eql = std.mem.eql;
    if (eql(u8, command, "project")) return projectCommand(ctx, args);
    if (eql(u8, command, "status")) {
        if (args.len != 0) return error.Usage;
        return status(ctx);
    }
    if (eql(u8, command, "switch") or eql(u8, command, "track") or eql(u8, command, "parallel")) {
        const o = try options(ctx, args, &.{ "-m", "--text", "--project" });
        if (o.words.len == 0) return error.Usage;
        const text = o.values[0] orelse o.values[1];
        const target = if (eql(u8, command, "parallel")) "/api/parallel" else "/api/switch";
        var body: std.json.ObjectMap = .empty;
        try body.put(ctx.a, "task", .{ .string = try joined(ctx, o.words) });
        try body.put(ctx.a, "text", if (text) |value| .{ .string = value } else .null);
        if (o.values[2]) |raw| {
            const id = try projectId(raw);
            try body.put(ctx.a, "project_id", if (id) |value| .{ .integer = value } else .null);
        }
        const reply = try call(ctx, "POST", target, try jsonBody(ctx, std.json.Value{ .object = body }));
        if (!try settle(ctx, reply)) return .ok;
        const r = try parse(struct { task: Task, created: bool }, ctx, reply.body);
        try ctx.out.writeAll(if (eql(u8, command, "parallel")) "parallel  " else "focus     ");
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
    if (eql(u8, command, "capture")) {
        var rest: std.ArrayList([]const u8) = .empty;
        var attended = true;
        for (args) |arg| {
            if (eql(u8, arg, "--unattended")) attended = false else try rest.append(ctx.a, arg);
        }
        const o = try options(ctx, rest.items, &.{ "--source", "--run", "--event", "--subject", "--default", "--project-key", "--project-hint", "--first-prompt" });
        if (o.words.len != 1 or o.values[0] == null or o.values[1] == null) return error.Usage;
        const reply = try call(ctx, "POST", "/api/capture", try jsonBody(ctx, .{
            .source = o.values[0].?,
            .run = o.values[1].?,
            .event = o.values[2],
            .kind = o.words[0],
            .subject = o.values[3],
            .default_subject = o.values[4],
            .project_key = o.values[5],
            .project_hint = o.values[6],
            .first_prompt = o.values[7],
            .attended = attended,
        }));
        if (!try settle(ctx, reply)) return .failed;
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
        if (args.len == 1 and eql(u8, args[0], "login")) return providerLogin(ctx);
        if (args.len > 0 and eql(u8, args[0], "source")) return providerSource(ctx, args[1..]);
        if (args.len == 1 and eql(u8, args[0], "check")) {
            const reply = try call(ctx, "POST", "/api/provider/source/check", "{}");
            if (!try settle(ctx, reply)) return .failed;
            if (ctx.json) return .ok;
            const result = try parse(struct { outcome: []const u8, release: struct { sequence: i64, version: []const u8 } }, ctx, reply.body);
            if (eql(u8, result.outcome, "older")) try ctx.out.print("older release offered (sequence {d}); ignored\n", .{result.release.sequence})
            else try ctx.out.print("{s}: {s} (sequence {d})\n", .{ result.outcome, result.release.version, result.release.sequence });
            return .ok;
        }
        if (args.len > 0 and eql(u8, args[0], "install")) return providerInstall(ctx, args[1..]);
        if (args.len == 2 and eql(u8, args[0], "trust")) {
            const current = eql(u8, args[1], "--current");
            const sha = if (current) blk: {
                const status_reply = try call(ctx, "GET", "/api/provider", null);
                if (!try settle(ctx, status_reply)) return .ok;
                const provider_reply = try parse(struct { status: api.ProviderStatus }, ctx, status_reply.body);
                break :blk if (provider_reply.status.candidate) |candidate| candidate.sha256 else return error.Usage;
            } else args[1];
            if (!@import("provider_loader.zig").validHash(sha)) return error.Usage;
            const approved = try call(ctx, "POST", "/api/provider/approve", try jsonBody(ctx, .{ .sha256 = sha, .how = if (current) "accepted" else "compared" }));
            if (!try settle(ctx, approved)) return .ok;
            const result = try parse(struct { restart: bool }, ctx, approved.body);
            if (current) try ctx.out.writeAll("trusted the current file as it is, without comparing it with a published hash\n") else try ctx.out.writeAll("provider hash approved\n");
            if (result.restart) try ctx.out.writeAll("restart the daemon to load the approved provider\n");
            return .ok;
        }
        if (args.len != 0) return error.Usage;
        const reply = try call(ctx, "GET", "/api/provider", null);
        if (!try settle(ctx, reply)) return .ok;
        const Named = struct { name: []const u8, label: []const u8 = "" };
        const r = try parse(struct { instance: ?[]const u8, status: api.ProviderStatus, fields: []Named, settings: []Named = &.{}, post_options: []Named = &.{}, sessions: bool = false }, ctx, reply.body);
        switch (r.status.state) {
            .none => try ctx.out.writeAll("no provider\n"),
            .unavailable => try ctx.out.print("provider unavailable: {s}\n", .{r.status.reason}),
            .loaded => try ctx.out.print("provider  {s} {s} (loaded)\n", .{ r.status.name, r.status.build }),
            .awaiting_approval => try ctx.out.writeAll("provider awaiting approval\n"),
        }
        const source_reply = try call(ctx, "GET", "/api/provider/source", null);
        if (source_reply.status == 200) {
            const source_state = try parse(struct { enrollment: ?struct { source: []const u8 }, ignored_drop_folder: bool = false }, ctx, source_reply.body);
            if (source_state.ignored_drop_folder and source_state.enrollment != null) {
                try ctx.out.writeAll("a DLL in the providers folder is ignored: the provider comes from ");
                try asciiLine(ctx.out, source_state.enrollment.?.source);
            }
        }
        if (r.status.candidate) |candidate| {
            const safe_file = try ctx.a.dupe(u8, candidate.file);
            for (safe_file) |*c| if (!std.ascii.isPrint(c.*)) { c.* = '?'; };
            const z = try currentZone(ctx);
            const modified = try z.localOf(candidate.modified_ms);
            try ctx.out.print("candidate  {s} ({d} bytes, modified {d:0>4}-{d:0>2}-{d:0>2} ", .{ safe_file, candidate.size, modified.year, modified.month, modified.day });
            try clockTime(ctx.out, &z, candidate.modified_ms);
            try ctx.out.writeAll(")\n");
            const version = candidate.version;
            if (version.product_name.len == 0 and version.file_version.len == 0 and version.company_name.len == 0) {
                try ctx.out.writeAll("claimed  (none)\n");
            } else {
                if (version.product_name.len != 0) try ctx.out.print("claimed product  {s}\n", .{version.product_name});
                if (version.file_version.len != 0) try ctx.out.print("claimed version  {s}\n", .{version.file_version});
                if (version.company_name.len != 0) try ctx.out.print("claimed company  {s}\n", .{version.company_name});
            }
            try ctx.out.print("sha256  {s}\n", .{candidate.sha256});
            try ctx.out.print("approve after comparison: kowalski provider trust {s}\n", .{candidate.sha256});
            try ctx.out.writeAll("accept as is: kowalski provider trust --current\n");
        }
        const instance = r.instance orelse {
            return .ok;
        };
        _ = instance;
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
    if (eql(u8, command, "restart")) {
        if (args.len != 0) return error.Usage;
        const before = daemonPid(ctx);
        const reply = try call(ctx, "POST", "/api/restart", "");
        if (!try settle(ctx, reply)) return .failed;
        return waitForRestart(ctx, before, 70);
    }
    if (eql(u8, command, "update")) {
        const local_file: ?[]const u8 = if (args.len == 2 and eql(u8, args[0], "--from")) args[1] else null;
        if (local_file == null and (args.len > 1 or (args.len == 1 and !eql(u8, args[0], "--yes")))) return error.Usage;
        const outcome_reply = try call(ctx, "GET", "/api/update?outcome=1", null);
        if (!try settle(ctx, outcome_reply)) return .failed;
        const Outcome = struct { id: []const u8, from: []const u8, to: []const u8, phase: []const u8, reason: []const u8 };
        const outcome_info = try parse(struct { last: ?Outcome = null }, ctx, outcome_reply.body);
        if (outcome_info.last) |last| {
            if (eql(u8, last.phase, "committed")) {
                try ctx.out.print("Updated to {s}\n", .{last.to});
            } else {
                try ctx.out.print("The update to {s} did not start and was rolled back to {s}: {s}\n", .{ last.to, last.from, last.reason });
            }
            const ack = try call(ctx, "POST", "/api/update/ack", try jsonBody(ctx, .{ .id = last.id }));
            if (!try settle(ctx, ack)) return .failed;
        }
        if (local_file) |file| {
            if (!std.fs.path.isAbsolute(file)) return error.Usage;
            const before = daemonPid(ctx);
            const installed = try call(ctx, "POST", "/api/update", try jsonBody(ctx, .{ .file = file }));
            if (!try settle(ctx, installed)) return .failed;
            return waitForRestart(ctx, before, 320);
        }
        const yes = args.len == 1;
        const reply = try call(ctx, "GET", "/api/update", null);
        if (!try settle(ctx, reply)) return .ok;
        const info = try parse(struct { state: []const u8, version: []const u8 = "", current: []const u8 = "", notes_url: []const u8 = "", signed: bool = false }, ctx, reply.body);
        if (eql(u8, info.state, "disabled")) {
            try ctx.out.writeAll("updates are turned off in this build\n");
            return .ok;
        }
        if (eql(u8, info.state, "up_to_date")) {
            try ctx.out.print("up to date ({s})\n", .{info.version});
            return .ok;
        }
        if (!eql(u8, info.state, "available")) return error.BadResponse;
        if (!info.signed) {
            try ctx.out.writeAll("this release is not signed; kowalski will not install it\n");
            return .ok;
        }
        if (!yes) {
            const input = GetStdHandle(0xfffffff6) orelse {
                try ctx.out.print("{s} is available (current {s})\n", .{ info.version, info.current });
                try asciiLine(ctx.out, info.notes_url);
                try ctx.out.writeAll("run kowalski update --yes to install\n");
                return .ok;
            };
            var mode: u32 = 0;
            if (GetConsoleMode(input, &mode) == 0) {
                try ctx.out.print("{s} is available (current {s})\n", .{ info.version, info.current });
                try asciiLine(ctx.out, info.notes_url);
                try ctx.out.writeAll("run kowalski update --yes to install\n");
                return .ok;
            }
            // The normal output buffer is flushed by main after this returns;
            // print the prompt directly so it is visible while waiting.
            var prompt: Io.Writer.Allocating = .init(ctx.a);
            try prompt.writer.print("{s} is available (current {s})\n", .{ info.version, info.current });
            try asciiLine(&prompt.writer, info.notes_url);
            try prompt.writer.writeAll("Install it now? [y/N] ");
            try Io.File.stdout().writeStreamingAll(ctx.io, prompt.written());
            var answer_buffer: [16]u8 = undefined;
            const answer = try readLine(input, &answer_buffer);
            if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) return .ok;
        } else {
            try ctx.out.print("{s} is available (current {s})\n", .{ info.version, info.current });
            try asciiLine(ctx.out, info.notes_url);
        }
        const before = daemonPid(ctx);
        const installed = try call(ctx, "POST", "/api/update", try jsonBody(ctx, .{ .version = info.version }));
        if (!try settle(ctx, installed)) return .failed;
        return waitForRestart(ctx, before, 320);
    }
    return error.Usage;
}

fn confirm(ctx: *Context, label: []const u8) !bool {
    const input = GetStdHandle(0xfffffff6) orelse return false;
    var mode: u32 = 0;
    if (GetConsoleMode(input, &mode) == 0) return false;
    try Io.File.stdout().writeStreamingAll(ctx.io, label);
    var buffer: [16]u8 = undefined;
    const answer = try readLine(input, &buffer);
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn providerSource(ctx: *Context, args: []const []const u8) !Exit {
    const eql = std.mem.eql;
    if (args.len == 0) {
        const reply = try call(ctx, "GET", "/api/provider/source", null);
        if (!try settle(ctx, reply)) return .failed;
        if (ctx.json) return .ok;
        const r = try parse(struct { enrollment: ?struct { source: []const u8, provider: []const u8, channel: []const u8, highest_sequence: i64, last_error: ?[]const u8 = null } }, ctx, reply.body);
        if (r.enrollment) |e| {
            try asciiLine(ctx.out, e.source);
            try ctx.out.print("  {s}/{s}  sequence {d}\n", .{ e.provider, e.channel, e.highest_sequence });
            if (e.last_error) |problem| try ctx.out.print("last check: {s}\n", .{problem});
        } else try ctx.out.writeAll("no provider source enrolled\n");
        return .ok;
    }
    if (args.len == 1 and eql(u8, args[0], "--stop")) {
        const reply = try call(ctx, "DELETE", "/api/provider/source", null);
        if (!try settle(ctx, reply)) return .failed;
        if (!ctx.json) try ctx.out.writeAll("provider source stopped; manual discovery resumed\n");
        return .ok;
    }
    const from_setup = eql(u8, args[0], "--from-setup");
    var source: []const u8 = undefined;
    var setup_key: ?[]const u8 = null;
    if (from_setup) {
        const path = try std.fs.path.join(ctx.a, &.{ std.fs.path.dirname(ctx.db_path) orelse ".", "providers", "source.json" });
        const bytes = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.a, .limited(64 * 1024));
        const setup = std.json.parseFromSliceLeaky(struct { source: []const u8, key: []const u8 }, ctx.a, bytes, .{ .ignore_unknown_fields = false }) catch return error.Usage;
        source = setup.source;
        setup_key = setup.key;
        if (!ctx.json) {
            try ctx.out.writeAll("unverified source proposal: ");
            try asciiLine(ctx.out, source);
            try ctx.out.print("public key: {s}\n", .{setup.key});
        }
    } else source = args[0];
    var typed_key: ?[]const u8 = null;
    var accepted = false;
    var yes = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eql(u8, args[i], "--key") and i + 1 < args.len) {
            i += 1;
            typed_key = args[i];
        } else if (eql(u8, args[i], "--accept-as-is")) accepted = true
        else if (eql(u8, args[i], "--yes")) yes = true
        else return error.Usage;
    }
    if (accepted and (!from_setup or typed_key != null)) return error.Usage;
    if (from_setup and typed_key != null and !eql(u8, typed_key.?, setup_key.?)) return error.Usage;
    if (from_setup and !accepted and typed_key == null) return error.Usage;
    const key = typed_key orelse setup_key orelse return error.Usage;
    if (!@import("provider_manifest").validHex(key, 64)) return error.Usage;
    const how: []const u8 = if (accepted) "accepted" else "compared";
    const proposal = try call(ctx, "POST", "/api/provider/source", try jsonBody(ctx, .{ .source = source, .key = key, .how = how, .confirmed = true, .yes = false }));
    if (proposal.status < 200 or proposal.status >= 300) {
        _ = try settle(ctx, proposal);
        return .failed;
    }
    const r = try parse(struct { proposal: struct { provider: []const u8, channel: []const u8, version: []const u8, sequence: i64 }, proposal_token: []const u8 }, ctx, proposal.body);
    if (!ctx.json) try ctx.out.print("{s}/{s}  {s}  sequence {d}\n", .{ r.proposal.provider, r.proposal.channel, r.proposal.version, r.proposal.sequence });
    if (ctx.json and !yes) {
        try ctx.out.writeAll(proposal.body);
        try ctx.out.writeAll("\n");
        return .ok;
    }
    if (!yes and !try confirm(ctx, "Enroll this source and pin this provider/channel? [y/N] ")) return .ok;
    const enrolled = try call(ctx, "POST", "/api/provider/source", try jsonBody(ctx, .{ .source = source, .key = key, .how = how, .confirmed = true, .yes = true, .proposal_token = r.proposal_token }));
    if (!try settle(ctx, enrolled)) return .ok;
    if (!ctx.json) try ctx.out.writeAll("provider source enrolled; run kowalski provider install\n");
    return .ok;
}

fn providerInstall(ctx: *Context, args: []const []const u8) !Exit {
    const eql = std.mem.eql;
    var sequence: ?i64 = null;
    var yes = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(u8, args[i], "--sequence") and i + 1 < args.len) {
            i += 1;
            sequence = std.fmt.parseInt(i64, args[i], 10) catch return error.Usage;
        } else if (eql(u8, args[i], "--yes")) yes = true
        else return error.Usage;
    }
    if (sequence != null and !yes and !try confirm(ctx, "Install this older verified release? [y/N] ")) return .ok;
    const reply = try call(ctx, "POST", "/api/provider/source/install", try jsonBody(ctx, .{ .sequence = sequence, .yes = true }));
    if (!try settle(ctx, reply)) return .failed;
    if (ctx.json) return .ok;
    const r = try parse(struct { installed: struct { version: []const u8, sequence: i64 }, restart: bool }, ctx, reply.body);
    try ctx.out.print("installed {s} (sequence {d})\n", .{ r.installed.version, r.installed.sequence });
    if (r.restart) try ctx.out.writeAll("restart the daemon to load it\n");
    return .ok;
}

test "JSON source enrollment confirms the proposal and prints the final response" {
    const Fake = struct {
        var calls: usize = 0;
        fn callSource(_: *Context, method: []const u8, target: []const u8, body: ?[]const u8) !Reply {
            try std.testing.expectEqualStrings("POST", method);
            try std.testing.expectEqualStrings("/api/provider/source", target);
            calls += 1;
            if (calls == 1) {
                try std.testing.expect(std.mem.indexOf(u8, body.?, "\"yes\":false") != null);
                return .{ .status = 200, .body = "{\"proposal\":{\"provider\":\"sample\",\"channel\":\"stable\",\"version\":\"1\",\"sequence\":1},\"proposal_token\":\"one-use\",\"enrolled\":false}" };
            }
            try std.testing.expect(std.mem.indexOf(u8, body.?, "\"yes\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, body.?, "one-use") != null);
            return .{ .status = 200, .body = "{\"enrolled\":true}" };
        }
    };
    Fake.calls = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    var ctx: Context = .{ .io = std.testing.io, .a = arena.allocator(), .db_path = "unused", .json = true,
        .out = &out.writer, .err = &err.writer, .call_override = Fake.callSource };
    const key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectEqual(Exit.ok, try providerSource(&ctx, &.{ "folder", "--key", key, "--yes" }));
    try std.testing.expectEqual(@as(usize, 2), Fake.calls);
    try std.testing.expectEqualStrings("{\"enrolled\":true}\n", out.written());
}

fn asciiLine(w: *Io.Writer, bytes: []const u8) !void {
    for (bytes) |c| try w.writeByte(if (std.ascii.isPrint(c)) c else '?');
    try w.writeByte('\n');
}

/// The process id of the daemon answering now, or null when none answers.
fn daemonPid(ctx: *Context) ?u32 {
    const reply = call(ctx, "GET", "/api/version", null) catch return null;
    if (reply.status != 200) return null;
    const r = parse(struct { pid: u32 }, ctx, reply.body) catch return null;
    return r.pid;
}

/// Done when a different daemon answers: a restart can finish between polls.
fn waitForRestart(ctx: *Context, before: ?u32, attempts: usize) !Exit {
    for (0..attempts) |_| {
        try ctx.io.sleep(.fromMilliseconds(500), .awake);
        const now = daemonPid(ctx) orelse continue;
        if (before == null or now != before.?) {
            if (!ctx.json) try ctx.out.writeAll("daemon restarted\n");
            return .ok;
        }
    }
    try ctx.err.print("kowalski: daemon did not restart within {d} s (run kowalski start)\n", .{attempts / 2});
    return .failed;
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
    var z = try zone.Zone.load(s.zone);
    z.day_start_min = s.day_start_min;
    return z;
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
    var z = try zone.Zone.load(s.zone);
    z.day_start_min = s.day_start_min;
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
        day_start_min: u16 = 0,
        numbers: Numbers,
        tasks: []struct { task: Task, focus_ms: i64, hops: u32 },
        intervals: []Interval,
        summary: ?[]const u8 = null,
    };
    const d = try parse(Day, ctx, body);
    var z = try zone.Zone.load(d.zone);
    z.day_start_min = d.day_start_min;
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
