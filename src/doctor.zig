//! Read-only launch diagnosis and guarded daemon recovery.
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const sqlite = @import("sqlite.zig");
const cli = @import("cli.zig");
const launch = @import("launch.zig");
const daemon = @import("daemon.zig");
const update_lock = @import("update_lock.zig");
const update_journal = @import("update_journal.zig");
const update_guard = @import("update_guard.zig");
const clock = @import("clock.zig");

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn QueryFullProcessImageNameW(windows.HANDLE, u32, [*]u16, *u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn CreateToolhelp32Snapshot(u32, u32) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn Process32FirstW(windows.HANDLE, *ProcessEntry) callconv(.winapi) i32;
extern "kernel32" fn Process32NextW(windows.HANDLE, *ProcessEntry) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(windows.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "iphlpapi" fn GetExtendedTcpTable(?*anyopaque, *u32, i32, u32, u32, u32) callconv(.winapi) u32;
extern "winhttp" fn WinHttpOpen([*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpConnect(*anyopaque, [*:0]const u16, u16, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpOpenRequest(*anyopaque, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpSetTimeouts(*anyopaque, i32, i32, i32, i32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpSendRequest(*anyopaque, ?[*:0]const u16, u32, ?*const anyopaque, u32, u32, usize) callconv(.winapi) i32;
extern "winhttp" fn WinHttpReceiveResponse(*anyopaque, ?*anyopaque) callconv(.winapi) i32;
extern "winhttp" fn WinHttpQueryHeaders(*anyopaque, u32, ?[*:0]const u16, ?*anyopaque, *u32, ?*u32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpReadData(*anyopaque, [*]u8, u32, *u32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpCloseHandle(*anyopaque) callconv(.winapi) i32;

const ProcessEntry = extern struct {
    size: u32 = @sizeOf(ProcessEntry), usage: u32 = 0, pid: u32 = 0,
    heap: usize = 0, module: u32 = 0, threads: u32 = 0, parent: u32 = 0,
    priority: i32 = 0, flags: u32 = 0, exe: [260]u16 = @splat(0),
};
const TcpRow = extern struct { state: u32, local_address: u32, local_port: u32, remote_address: u32, remote_port: u32, pid: u32 };
pub const ProbeState = enum { answering, foreign, silent, closed };
pub const Probe = struct { state: ProbeState, version: []const u8 = "", pid: u32 = 0 };
pub const Process = struct { pid: u32, image: []const u8 };
pub const Finding = struct { id: []const u8, ok: bool, detail: []const u8 };
pub const Repair = enum { none, spawn, wait_restart, restart_version };

pub fn classify(status: u32, body: []const u8, a: std.mem.Allocator) Probe {
    if (status != 200 or body.len == 0) return .{ .state = .foreign };
    const value = std.json.parseFromSliceLeaky(struct { version: []const u8, pid: u32 }, a, body, .{ .ignore_unknown_fields = true }) catch return .{ .state = .foreign };
    if (value.version.len == 0 or value.pid == 0) return .{ .state = .foreign };
    return .{ .state = .answering, .version = value.version, .pid = value.pid };
}

pub fn plan(update_running: bool, state: ProbeState, foreign_owner: bool, daemon_count: usize, version_match: bool) Repair {
    if (update_running or foreign_owner or state == .foreign) return .none;
    if (state == .answering) return if (version_match) .none else .restart_version;
    if (daemon_count != 0) return .wait_restart;
    return if (state == .closed) .spawn else .none;
}

fn remaining(deadline: u64) i32 {
    const now = GetTickCount64();
    return @intCast(@max(1, @min(2000, deadline -| now)));
}

fn http(a: std.mem.Allocator, port: u16, method: []const u8, target: []const u8) !Probe {
    const deadline = GetTickCount64() + 2000;
    const agent = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("kowalski-doctor"), 0, null, null, 0) orelse return .{ .state = .closed };
    defer _ = WinHttpCloseHandle(agent);
    const connection = WinHttpConnect(agent, std.unicode.utf8ToUtf16LeStringLiteral("127.0.0.1"), port, 0) orelse return .{ .state = .closed };
    defer _ = WinHttpCloseHandle(connection);
    const method_w = try std.unicode.utf8ToUtf16LeAllocZ(a, method);
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(a, target);
    const request = WinHttpOpenRequest(connection, method_w, target_w, null, null, null, 0) orelse return .{ .state = .closed };
    defer _ = WinHttpCloseHandle(request);
    const send_timeout = remaining(deadline);
    _ = WinHttpSetTimeouts(request, send_timeout, send_timeout, send_timeout, send_timeout);
    if (WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return .{ .state = if (GetLastError() == 12002) .silent else .closed };
    if (GetTickCount64() >= deadline) return .{ .state = .silent };
    const receive_timeout = remaining(deadline);
    _ = WinHttpSetTimeouts(request, receive_timeout, receive_timeout, receive_timeout, receive_timeout);
    if (WinHttpReceiveResponse(request, null) == 0) return .{ .state = .silent };
    var status: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (WinHttpQueryHeaders(request, 19 | 0x20000000, null, &status, &size, null) == 0) return .{ .state = .foreign };
    var data: std.ArrayList(u8) = .empty;
    while (data.items.len < 4096) {
        if (GetTickCount64() >= deadline) return .{ .state = .silent };
        const read_timeout = remaining(deadline);
        _ = WinHttpSetTimeouts(request, read_timeout, read_timeout, read_timeout, read_timeout);
        var buffer: [1024]u8 = undefined;
        var count: u32 = 0;
        if (WinHttpReadData(request, &buffer, buffer.len, &count) == 0) return .{ .state = .silent };
        if (count == 0) break;
        try data.appendSlice(a, buffer[0..count]);
    }
    return classify(status, data.items, a);
}

pub fn probe(a: std.mem.Allocator, port: u16) !Probe { return http(a, port, "GET", "/api/version"); }
pub fn boundedPing(a: std.mem.Allocator, port: u16) bool { return (probe(a, port) catch return false).state == .answering; }

fn imagePath(a: std.mem.Allocator, pid: u32) ![]const u8 {
    const handle = OpenProcess(0x1000, 0, pid) orelse return "(image unavailable)";
    defer _ = CloseHandle(handle);
    var buffer: [32768]u16 = undefined;
    var size: u32 = buffer.len;
    if (QueryFullProcessImageNameW(handle, 0, &buffer, &size) == 0) return "(image unavailable)";
    return std.unicode.utf16LeToUtf8Alloc(a, buffer[0..size]);
}

fn owner(a: std.mem.Allocator, port: u16) !?Process {
    var bytes: u32 = 0;
    _ = GetExtendedTcpTable(null, &bytes, 0, 2, 3, 0);
    if (bytes < 4 or bytes > 1024 * 1024) return null;
    const buffer = try a.alignedAlloc(u8, .of(u32), bytes);
    if (GetExtendedTcpTable(buffer.ptr, &bytes, 0, 2, 3, 0) != 0) return null;
    const count: *align(1) const u32 = @ptrCast(buffer.ptr);
    const rows: [*]align(1) const TcpRow = @ptrCast(buffer.ptr + 4);
    for (rows[0..@min(count.*, (bytes - 4) / @sizeOf(TcpRow))]) |row| {
        const p: u16 = @intCast(((row.local_port & 255) << 8) | ((row.local_port >> 8) & 255));
        if (p == port and (row.local_address == 0x0100007f or row.local_address == 0)) return .{ .pid = row.pid, .image = try imagePath(a, row.pid) };
    }
    return null;
}

fn daemonProcesses(a: std.mem.Allocator) ![]Process {
    const handle = CreateToolhelp32Snapshot(2, 0);
    if (handle == windows.INVALID_HANDLE_VALUE) return &.{};
    defer _ = CloseHandle(handle);
    var result: std.ArrayList(Process) = .empty;
    var entry: ProcessEntry = .{};
    var more = Process32FirstW(handle, &entry) != 0;
    while (more) : (more = Process32NextW(handle, &entry) != 0) {
        const name = std.mem.sliceTo(&entry.exe, 0);
        if (entry.pid != GetCurrentProcessId() and std.ascii.eqlIgnoreCase(std.unicode.utf16LeToUtf8Alloc(a, name) catch "", "kowalskiw.exe"))
            try result.append(a, .{ .pid = entry.pid, .image = try imagePath(a, entry.pid) });
    }
    return result.items;
}

/// Best-effort owner for the update mutex (Win32 mutexes do not expose a PID).
pub fn updateProcessPid() ?u32 {
    const handle = CreateToolhelp32Snapshot(2, 0);
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(handle);
    var fallback: ?u32 = null;
    var entry: ProcessEntry = .{};
    var more = Process32FirstW(handle, &entry) != 0;
    while (more) : (more = Process32NextW(handle, &entry) != 0) {
        if (entry.pid == GetCurrentProcessId()) continue;
        const name = std.mem.sliceTo(&entry.exe, 0);
        if (std.mem.eql(u16, name, std.unicode.utf8ToUtf16LeStringLiteral("kowalskiw.exe.old"))) return entry.pid;
        if (std.mem.eql(u16, name, std.unicode.utf8ToUtf16LeStringLiteral("kowalskiw.exe"))) fallback = entry.pid;
    }
    return fallback;
}

pub fn logTail(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var lines: [5][]const u8 = @splat("");
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!containsIgnoreCase(line, "error") and !containsIgnoreCase(line, "fail") and !containsIgnoreCase(line, "launcher:") and !containsIgnoreCase(line, "cannot") and !containsIgnoreCase(line, "could not") and !containsIgnoreCase(line, "already running")) continue;
        lines[count % lines.len] = line[0..@min(line.len, 300)];
        count += 1;
    }
    var output: std.ArrayList(u8) = .empty;
    const first = count - @min(count, lines.len);
    for (first..count) |i| {
        for (lines[i % lines.len]) |ch| try output.append(a, if (ch >= 32 and ch <= 126) ch else '?');
        try output.append(a, '\n');
    }
    return output.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}

pub const Report = struct {
    findings: []const Finding,
    actions: []const []const u8,
    healthy: bool,
    log_path: []const u8,
    tail: []const u8,

    pub fn format(self: Report, a: std.mem.Allocator) ![]const u8 {
        var w: Io.Writer.Allocating = .init(a);
        for (self.findings) |f| try w.writer.print("{s} {s}: {s}\n", .{ if (f.ok) @as([]const u8, "ok") else "FAIL", f.id, f.detail });
        for (self.actions) |step| try w.writer.print("action: {s}\n", .{step});
        if (!self.healthy) {
            if (self.tail.len > 0) try w.writer.print("Recent log lines:\n{s}", .{self.tail});
            try w.writer.print("Log: {s}\n", .{self.log_path});
        }
        return ascii(a, w.written());
    }
};

pub fn ascii(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    const output = try a.dupe(u8, input);
    for (output) |*ch| if (!std.ascii.isAscii(ch.*)) { ch.* = '?'; };
    return output;
}

fn add(a: std.mem.Allocator, list: *std.ArrayList(Finding), id: []const u8, ok: bool, detail: []const u8) !void {
    try list.append(a, .{ .id = id, .ok = ok, .detail = detail });
}
fn action(a: std.mem.Allocator, list: *std.ArrayList([]const u8), db_path: []const u8, detail: []const u8) !void {
    try list.append(a, detail);
    daemon.logBeforeStart(a, db_path, try std.fmt.allocPrint(a, "launcher: {s}", .{detail})) catch {};
}

fn waitAnswer(io: Io, a: std.mem.Allocator, port: u16, child: ?launch.Child, old_pid: u32) !Probe {
    const deadline = GetTickCount64() + 20_000;
    while (GetTickCount64() < deadline) {
        if (child) |c| if (!c.alive()) break;
        const p = try probe(a, port);
        if (p.state == .foreign or (p.state == .answering and p.pid != old_pid)) return p;
        try io.sleep(.fromMilliseconds(250), .awake);
    }
    return probe(a, port);
}

fn killMatching(a: std.mem.Allocator, processes: []const Process, db_path: []const u8, actions: *std.ArrayList([]const u8)) !void {
    const dir = try launch.exeDir(a);
    for (processes) |process| {
        if (!std.ascii.eqlIgnoreCase(std.fs.path.dirname(process.image) orelse "", dir)) continue;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(process.image), "kowalskiw.exe")) continue;
        const handle = OpenProcess(0x100001, 0, process.pid) orelse continue;
        defer _ = CloseHandle(handle);
        if (WaitForSingleObject(handle, 0) == 0x102) _ = TerminateProcess(handle, 1);
        _ = WaitForSingleObject(handle, 10_000);
        try action(a, actions, db_path, try std.fmt.allocPrint(a, "restarted unresponsive daemon pid {d}", .{process.pid}));
    }
}

pub fn run(io: Io, a: std.mem.Allocator, db_path: []const u8, db_flag: ?[]const u8, fix: bool) !Report {
    var findings: std.ArrayList(Finding) = .empty;
    var actions: std.ArrayList([]const u8) = .empty;
    const log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(db_path) orelse ".", "daemon.log" });
    try journalCopies(io, a, db_path, &findings);
    var db: sqlite.Db = .{};
    db.openReadOnly(db_path) catch {
        try add(a, &findings, "database", false, try std.fmt.allocPrint(a, "cannot open {s} read-only", .{db_path}));
        return .{ .findings = findings.items, .actions = actions.items, .healthy = false, .log_path = log_path, .tail = try readTail(io, a, log_path) };
    };
    db.close();
    try add(a, &findings, "database", true, db_path);
    var lock = update_lock.tryAcquire() orelse {
        try add(a, &findings, "update", false, "an update is running, try again in a minute");
        return .{ .findings = findings.items, .actions = actions.items, .healthy = false, .log_path = log_path, .tail = try readTail(io, a, log_path) };
    };
    lock.release();
    try add(a, &findings, "update", true, "no update running");
    var journal = update_journal.read(a, io, db_path) catch |err| blk: {
        if (!fix) {
            try add(a, &findings, "journal", false, @errorName(err));
            return .{ .findings = findings.items, .actions = actions.items, .healthy = false, .log_path = log_path, .tail = try readTail(io, a, log_path) };
        }
        const backup = try update_journal.abandon(a, io, db_path, null, "unreadable journal", clock.nowMs());
        try action(a, &actions, db_path, try std.fmt.allocPrint(a, "saved unreadable journal at {s}", .{backup}));
        try add(a, &findings, "journal copy", true, backup);
        break :blk null;
    };
    if (fix and journal != null and update_journal.needsRecovery(journal.?)) {
        var rollback_failed = false;
        const owned = update_guard.recoverOnLaunch(a, io, db_path) catch |err| blk: {
            rollback_failed = true;
            const backup = try update_journal.abandon(a, io, db_path, journal, "rollback failed", clock.nowMs());
            try action(a, &actions, db_path, try std.fmt.allocPrint(a, "rollback failed: {s}; saved journal at {s}", .{ @errorName(err), backup }));
            try add(a, &findings, "journal copy", true, backup);
            try add(a, &findings, "snapshot", true, try std.fs.path.join(a, &.{ std.fs.path.dirname(db_path) orelse ".", journal.?.snapshot }));
            break :blk false;
        };
        if (owned) {
            try add(a, &findings, "update", false, "an update is running, try again in a minute");
            return .{ .findings = findings.items, .actions = actions.items, .healthy = false, .log_path = log_path, .tail = try readTail(io, a, log_path) };
        }
        if (!rollback_failed) try action(a, &actions, db_path, "recovered interrupted update");
        journal = try update_journal.read(a, io, db_path);
    }
    const journal_ok = journal == null or !update_journal.needsRecovery(journal.?);
    try add(a, &findings, "journal", journal_ok, if (journal) |j| @tagName(j.phase) else "none");
    const port_ctx: cli.Context = .{ .io = io, .a = a, .db_path = db_path, .json = false, .out = undefined, .err = undefined };
    var mutable_ctx = port_ctx;
    const port = try cli.readPort(&mutable_ctx);
    try add(a, &findings, "port", true, try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port}));
    var p = try probe(a, port);
    const own = try owner(a, port);
    const processes = try daemonProcesses(a);
    const foreign_owner = if (own) |o| !std.ascii.eqlIgnoreCase(std.fs.path.basename(o.image), "kowalskiw.exe") else false;
    const local_version = @import("build_options").version;
    const version_match = p.state == .answering and std.mem.eql(u8, p.version, local_version);
    const probe_index = findings.items.len;
    try add(a, &findings, "probe", p.state == .answering, @tagName(p.state));
    try add(a, &findings, "port owner", !foreign_owner, if (own) |o| try std.fmt.allocPrint(a, "{s} (pid {d})", .{ o.image, o.pid }) else "none");
    for (processes) |process| try add(a, &findings, "daemon process", true, try std.fmt.allocPrint(a, "{s} (pid {d})", .{ process.image, process.pid }));
    const version_index = findings.items.len;
    if (p.state == .answering) try add(a, &findings, "version", version_match, try std.fmt.allocPrint(a, "daemon {s}; executable {s}", .{ p.version, local_version }));
    if (fix) switch (plan(false, p.state, foreign_owner, processes.len, version_match)) {
        .none => {},
        .spawn => {
            try action(a, &actions, db_path, "starting daemon");
            var child = try launch.spawnTracked(a, try launch.backgroundCommand(a, db_flag, null));
            defer child.close();
            p = try waitAnswer(io, a, port, child, 0);
        },
        .wait_restart => {
            try action(a, &actions, db_path, "waiting for daemon");
            p = try waitAnswer(io, a, port, null, 0);
            if (p.state != .answering and p.state != .foreign) {
                try killMatching(a, processes, db_path, &actions);
                var child = try launch.spawnTracked(a, try launch.backgroundCommand(a, db_flag, null));
                defer child.close();
                p = try waitAnswer(io, a, port, child, 0);
            }
        },
        .restart_version => {
            try action(a, &actions, db_path, "requesting daemon restart");
            const old_pid = p.pid;
            _ = try http(a, port, "POST", "/api/restart");
            p = try waitAnswer(io, a, port, null, old_pid);
        },
    };
    if (fix) {
        findings.items[probe_index].ok = p.state == .answering;
        findings.items[probe_index].detail = @tagName(p.state);
        if (p.state == .answering) {
            if (version_index == findings.items.len) try add(a, &findings, "version", std.mem.eql(u8, p.version, local_version), try std.fmt.allocPrint(a, "daemon {s}; executable {s}", .{ p.version, local_version }))
            else {
                findings.items[version_index].ok = std.mem.eql(u8, p.version, local_version);
                findings.items[version_index].detail = try std.fmt.allocPrint(a, "daemon {s}; executable {s}", .{ p.version, local_version });
            }
        }
    }
    const healthy = p.state == .answering and std.mem.eql(u8, p.version, local_version) and !foreign_owner and journal_ok;
    if (foreign_owner) try add(a, &findings, "repair", false, try std.fmt.allocPrint(a, "Port {d} is used by {s} (pid {d}). Close it and open kowalski again.", .{ port, own.?.image, own.?.pid }));
    if (fix) try add(a, &findings, "result", healthy, if (healthy) "dashboard answering" else "dashboard still unavailable");
    const tail = try readTail(io, a, log_path);
    try add(a, &findings, "log", true, if (tail.len == 0) "no recent error lines" else tail);
    return .{ .findings = findings.items, .actions = actions.items, .healthy = healthy, .log_path = log_path, .tail = tail };
}

fn readTail(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch return "";
    return logTail(a, bytes);
}

fn journalCopies(io: Io, a: std.mem.Allocator, db_path: []const u8, findings: *std.ArrayList(Finding)) !void {
    const dir_path = std.fs.path.dirname(db_path) orelse ".";
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "update.json.failed-")) {
            try add(a, findings, "journal copy", true, try std.fs.path.join(a, &.{ dir_path, entry.name }));
        }
    }
}

test "probe classification and repair plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(ProbeState.answering, classify(200, "{\"version\":\"1\",\"pid\":42}", a).state);
    for ([_][]const u8{ "", "garbage", "<html>foreign</html>" }) |body| try std.testing.expectEqual(ProbeState.foreign, classify(200, body, a).state);
    try std.testing.expectEqual(ProbeState.foreign, classify(404, "{}", a).state);
    try std.testing.expectEqual(Repair.none, plan(true, .closed, false, 0, false));
    try std.testing.expectEqual(Repair.none, plan(false, .foreign, true, 0, false));
    try std.testing.expectEqual(Repair.spawn, plan(false, .closed, false, 0, false));
    try std.testing.expectEqual(Repair.wait_restart, plan(false, .silent, false, 1, false));
    try std.testing.expectEqual(Repair.restart_version, plan(false, .answering, false, 1, false));
}

test "log tail and report are ASCII" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tail = try logTail(a, "ok\nerror one\nfail two\nerror three\nerror four\nerror five\nerror \xff\n");
    try std.testing.expect(std.mem.indexOf(u8, tail, "one") == null);
    for (tail) |ch| try std.testing.expect(std.ascii.isAscii(ch));
    const f = [_]Finding{.{ .id = "probe", .ok = false, .detail = "closed" }};
    const report: Report = .{ .findings = &f, .actions = &.{}, .healthy = false, .log_path = "daemon.log", .tail = tail };
    const rendered = try report.format(a);
    for (rendered) |ch| try std.testing.expect(std.ascii.isAscii(ch));
}
