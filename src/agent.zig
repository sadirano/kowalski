//! `kowalski --agent`: what each command does to the user's data, for agents
//! and launchers. One table feeds the text and the JSON form.
const std = @import("std");

pub const Safety = enum {
    /// Reads only.
    safe,
    /// Writes the live tracker; run it when the user's request covers it.
    writes_live,
    /// Sends to the provider or changes what kowalski runs or trusts.
    outward,
    /// Starts, stops or installs the daemon.
    system,
};

pub const Command = struct {
    name: []const u8,
    usage: []const u8,
    safety: Safety,
    summary: []const u8,
    /// What a write touches beyond the named task, so a request for one
    /// thing is not read as permission for another.
    effects: []const []const u8 = &.{},
    /// Takes `--project-key` (and `--project-hint` on writes).
    project_key: bool = false,
};

pub const spec_version = 1;

pub const header =
    \\Every write goes to the running daemon and its live database, also with
    \\--db (which only redirects reads). Check a write against a scratch
    \\daemon, never the user's.
    \\--project-key <key> is opaque: one key names one project whichever
    \\source sent it. A read never creates a project; a write makes one from
    \\--project-hint (or the key) on first sight, reusing an unclaimed project
    \\of that name.
;

pub const commands = [_]Command{
    .{ .name = "status", .usage = "status [--project-key <key>]", .safety = .safe, .project_key = true, .summary = "focus, parallel work and today's numbers; with a key, whether the focus is in that project" },
    .{ .name = "day", .usage = "day [<YYYY-MM-DD>] [--project-key <key>]", .safety = .safe, .project_key = true, .summary = "a day's totals, timeline and summary; with a key, that project's share" },
    .{ .name = "tasks", .usage = "tasks [<filter>] [--project-key <key>]", .safety = .safe, .project_key = true, .summary = "tasks by recent use" },
    .{ .name = "project list", .usage = "project list [--all]", .safety = .safe, .summary = "projects" },
    .{ .name = "postings", .usage = "postings [<YYYY-MM-DD>]", .safety = .safe, .summary = "what can be posted for a day, and what was" },
    .{ .name = "settings", .usage = "settings", .safety = .safe, .summary = "every setting" },
    .{ .name = "provider", .usage = "provider", .safety = .safe, .summary = "provider status and fields" },
    .{ .name = "doctor", .usage = "doctor [--json]", .safety = .safe, .summary = "diagnose launch (without --fix)" },
    .{ .name = "track", .usage = "track [--project <#id> | --project-key <key> [--project-hint <h>]] <task> [-m <text>]", .safety = .writes_live, .project_key = true, .summary = "focus a task; a new title creates it", .effects = &.{ "closes the open focus, in any project", "opens focus on the task" } },
    .{ .name = "parallel", .usage = "parallel [--project <#id> | --project-key <key> [--project-hint <h>]] <task> [-m <text>]", .safety = .writes_live, .project_key = true, .summary = "open parallel work on a task", .effects = &.{"opens a parallel interval; the focus stays"} },
    .{ .name = "stop", .usage = "stop <task>", .safety = .writes_live, .summary = "close a task's open interval", .effects = &.{"closes that task's interval, focus or parallel"} },
    .{ .name = "pause", .usage = "pause", .safety = .writes_live, .summary = "save and close everything open", .effects = &.{"closes every open interval, in every project"} },
    .{ .name = "resume", .usage = "resume", .safety = .writes_live, .summary = "bring back what pause saved", .effects = &.{"reopens the saved focus and parallel work"} },
    .{ .name = "note", .usage = "note [-t <task>] <text>", .safety = .writes_live, .summary = "a note on the focus, or on the named task's open interval", .effects = &.{"adds a note; nothing closes"} },
    .{ .name = "new", .usage = "new [--project-key <key> [--project-hint <h>]] <title>", .safety = .writes_live, .project_key = true, .summary = "create a task without opening it", .effects = &.{"adds a task"} },
    .{ .name = "rename", .usage = "rename <#id> <title>", .safety = .writes_live, .summary = "change a task's title", .effects = &.{"renames the task everywhere it shows; history keeps interval text"} },
    .{ .name = "project bind", .usage = "project bind <#id> --key <key>", .safety = .writes_live, .summary = "point a project key at a project (an alias rename keeps its project)", .effects = &.{"moves every source's mapping of the key"} },
    .{ .name = "summary", .usage = "summary [<YYYY-MM-DD>] [<text>]", .safety = .writes_live, .summary = "show a day's summary; with text, replace it", .effects = &.{"with text: replaces the day's summary"} },
    .{ .name = "delete", .usage = "delete <#id>", .safety = .writes_live, .summary = "delete a task and its time", .effects = &.{"removes the task's intervals and notes for good"} },
    .{ .name = "post", .usage = "post [<YYYY-MM-DD>] <task> [-m <text>]", .safety = .outward, .summary = "send a task's hours for a day to the provider", .effects = &.{"sends hours outside the machine"} },
    .{ .name = "resolve", .usage = "resolve <posting> posted|not-posted", .safety = .outward, .summary = "settle a posting whose outcome is unknown" },
    .{ .name = "provider login|trust|source|install", .usage = "provider <subcommand>", .safety = .outward, .summary = "sign in, approve or install provider code" },
    .{ .name = "set|unset", .usage = "set <key> <value> | unset <key>", .safety = .outward, .summary = "change a setting" },
    .{ .name = "start|open|shutdown|restart|autostart|update", .usage = "<command>", .safety = .system, .summary = "run, stop or replace the daemon" },
};

pub fn find(name: []const u8) ?Command {
    for (commands) |c| {
        var names = std.mem.splitScalar(u8, c.name, '|');
        while (names.next()) |n| if (std.mem.eql(u8, n, name)) return c;
    }
    return null;
}

pub fn writeText(w: *std.Io.Writer, only: ?Command) !void {
    if (only) |c| return writeCommand(w, c);
    try w.writeAll("kowalski agent spec " ++ std.fmt.comptimePrint("{d}", .{spec_version}) ++ "\n\n" ++ header ++ "\n");
    inline for (.{ .safe, .writes_live, .outward, .system }) |safety| {
        try w.print("{s}\n", .{switch (@as(Safety, safety)) {
            .safe => "SAFE - reads only; run freely",
            .writes_live => "WRITES LIVE - run when the user's request covers the effect",
            .outward => "OUTWARD - only on the user's explicit instruction",
            .system => "SYSTEM - the user's; do not run",
        }});
        for (commands) |c| if (c.safety == safety) try writeCommand(w, c);
        try w.writeAll("\n");
    }
}

fn writeCommand(w: *std.Io.Writer, c: Command) !void {
    try w.print("  {s}\n      {s}\n", .{ c.usage, c.summary });
    for (c.effects) |e| try w.print("      effect: {s}\n", .{e});
}

pub fn writeJson(w: *std.Io.Writer, only: ?Command) !void {
    if (only) |c| return std.json.Stringify.value(c, .{}, w);
    try std.json.Stringify.value(.{ .spec = spec_version, .tool = "kowalski", .note = header, .commands = commands }, .{}, w);
}

test "every command is found by each of its names" {
    try std.testing.expect(find("track") != null);
    try std.testing.expect(find("shutdown").?.safety == .system);
    try std.testing.expect(find("unset").?.safety == .outward);
    try std.testing.expect(find("nope") == null);
}
