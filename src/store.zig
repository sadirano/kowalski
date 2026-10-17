const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const zone = @import("zone.zig");

pub const Error = error{
    Sqlite,
    ForeignKeyViolation,
    SchemaVersion,
    OutOfMemory,
    TooLarge,
    EmptyStatement,
    NoSpaceLeft,
    InvalidCharacter,
    Overflow,
    UnknownZone,
    ZoneApi,
    NoFocus,
    NoOpenInterval,
    AlreadyOpen,
    SomethingOpen,
    UnknownTask,
    BindingConflict,
    TaskBound,
    EmptyText,
    InvalidState,
    PostingBlocked,
    InvalidSetting,
    InvalidTime,
    InvalidDate,
    UnknownInterval,
    UnknownNote,
    /// The interval changed since the caller read it.
    Stale,
    /// Two focus intervals, or two intervals of one task, would overlap.
    Overlap,
    /// A note would fall outside its interval.
    NoteOutside,
    /// An open interval's end is "now"; it cannot be set.
    OpenEnd,
    InvalidRange,
    NotMergeable,
    /// A task with posting history is kept, so the history stays whole.
    TaskHasPostings,
    /// A task with an open interval is stopped before it is deleted.
    TaskOpen,
    UnknownProject,
    DuplicateProject,
    InvalidProjectLabel,
    InvalidProjectKey,
    AmbiguousTask,
};

/// Times outside [0, max_time_ms) (years 1970..9999) are refused.
pub const max_time_ms: i64 = 253_402_300_800_000;

pub const Role = enum { focus, parallel };
pub const ProjectChoice = union(enum) { omitted, selected: ?i64 };
pub const AssignmentScope = union(enum) { task_id: i64, interval_ids: []const i64, unassigned_suggestions };
pub const AssignmentRow = struct {
    id: i64,
    task_id: i64,
    project_id: ?i64,
    role: []const u8,
    start_ms: i64,
    end_ms: ?i64,
    focus_ms: i64,
    reason: []const u8 = "selected",
};
pub const AssignmentTotal = struct { project_id: ?i64, date: []const u8, focus_ms: i64 };
pub const AssignmentSnapshot = struct {
    project_id: ?i64,
    intervals: []const AssignmentRow,
    totals: []const AssignmentTotal,
    reporting_zone: []const u8,
    day_start_min: u16 = 0,
};
pub const AssignmentPreview = struct { snapshot: AssignmentSnapshot, skipped: []const AssignmentRow };
pub const AssignmentResult = struct { changed: usize, focus_ms: i64 };

pub fn parseDayStart(value: []const u8) !u16 {
    if (value.len != 5 or value[2] != ':') return error.InvalidSetting;
    for ([_]usize{ 0, 1, 3, 4 }) |i| if (!std.ascii.isDigit(value[i])) return error.InvalidSetting;
    const hour = try std.fmt.parseInt(u16, value[0..2], 10);
    const minute = try std.fmt.parseInt(u16, value[3..5], 10);
    if (hour > 12 or minute > 59 or (hour == 12 and minute != 0)) return error.InvalidSetting;
    return hour * 60 + minute;
}

pub fn assignmentTotals(a: std.mem.Allocator, rows: []const AssignmentRow, z: zone.Zone) ![]AssignmentTotal {
    var totals: std.ArrayList(AssignmentTotal) = .empty;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.role, "focus")) continue;
        const end = row.end_ms orelse continue;
        var at = row.start_ms;
        while (at < end) {
            const d = try z.dateOf(at);
            const bounds = try z.dayBounds(d.year, d.month, d.day);
            const next = @min(end, bounds.end_ms);
            const day = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
            var found = false;
            for (totals.items) |*total| {
                if (total.project_id == row.project_id and std.mem.eql(u8, total.date, day)) {
                    total.focus_ms += next - at;
                    found = true;
                    break;
                }
            }
            if (!found) try totals.append(a, .{ .project_id = row.project_id, .date = day, .focus_ms = next - at }) else a.free(day);
            at = next;
        }
    }
    return totals.toOwnedSlice(a);
}

/// One event from an outside time source; see `Store.capture`.
pub const CaptureKind = enum { start, subject, prompt, busy, stop, end };
pub const Capture = struct {
    source: []const u8,
    run: []const u8,
    /// Stable id from the source; a repeat is ignored. Null skips the check.
    event: ?[]const u8 = null,
    kind: CaptureKind,
    /// The task a `subject` event names.
    task: ?i64 = null,
    /// The run's task until a `subject` names one (e.g. its repository).
    default_task: ?i64 = null,
    /// False for a run nobody watches; holding sources still take focus.
    attended: bool = true,
    /// A note for the run's open interval: the prompt's text on `prompt`,
    /// what came of the turn on `stop`. Written once per event id.
    note: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    default_subject: ?[]const u8 = null,
    project_key: ?[]const u8 = null,
    project_hint: ?[]const u8 = null,
    first_prompt: ?[]const u8 = null,
};
pub const CaptureResult = struct { applied: bool, project_id: ?i64, task_id: ?i64 };
pub const HistoryNote = struct { event: []const u8, at_ms: i64, text: []const u8 };
pub const HistoryInterval = struct {
    event: []const u8,
    subject: []const u8,
    start_ms: i64,
    end_ms: i64,
    notes: []const HistoryNote,
};
pub const HistoryResult = union(enum) {
    applied: struct { applied: usize, skipped: usize, notes: usize },
    conflict: struct { index: usize, reason: []const u8 },
    invalid_subject: usize,
};
/// A working run that sends nothing for this long is taken as gone.
pub const capture_lease_ms: i64 = 20 * 60_000;
/// A run's task stays open this long after its turn ends, so the next
/// prompt carries on the same interval; unused, it closes at the turn's end.
pub const capture_idle_ms: i64 = 5 * 60_000;
pub const focus_sustain_ms: i64 = 10 * 60_000;
pub const OpenedBy = enum { @"switch", parallel, @"resume" };
pub const ClosedBy = enum { @"switch", pause, stop, recovered };
pub const PostingState = enum { sending, confirmed, unknown, cancelled };

fn sqlText(value: anytype) []const u8 {
    return @tagName(value);
}

pub const Store = struct {
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    // Finding a named Windows zone walks the registry; every request needs
    // the zone, so the last one found is kept.
    zone_cache: ?struct { id: [128]u8, len: usize, zone: zone.Zone } = null,

    fn validProjectLabel(label: []const u8) bool {
        return label.len > 0 and label.len <= 200 and
            std.mem.eql(u8, label, std.mem.trim(u8, label, " \t\r\n")) and
            std.unicode.utf8ValidateSlice(label);
    }

    fn projectExists(s: *Store, id: i64) !bool {
        var stmt = try s.db.prepare("SELECT 1 FROM projects WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        return try stmt.step() == .row;
    }

    fn projectByLabel(s: *Store, label: []const u8) !?i64 {
        var stmt = try s.db.prepare("SELECT id FROM projects WHERE label=?1 COLLATE NOCASE");
        defer stmt.finalize();
        try stmt.bindText(1, label);
        return if (try stmt.step() == .row) stmt.columnI64(0) else null;
    }

    fn insertProject(s: *Store, label: []const u8) !i64 {
        if (!validProjectLabel(label)) return error.InvalidProjectLabel;
        if (try s.projectByLabel(label) != null) return error.DuplicateProject;
        var stmt = try s.db.prepare("INSERT INTO projects(label) VALUES(?1) RETURNING id");
        defer stmt.finalize();
        try stmt.bindText(1, label);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        return id;
    }

    pub fn createProject(s: *Store, label: []const u8, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const id = try s.insertProject(label);
        try tx.commit();
        return id;
    }

    pub fn renameProject(s: *Store, id: i64, label: []const u8, now_ms: i64) Error!void {
        if (!validProjectLabel(label)) return error.InvalidProjectLabel;
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (!try s.projectExists(id)) return error.UnknownProject;
        if (try s.projectByLabel(label)) |other| if (other != id) return error.DuplicateProject;
        var stmt = try s.db.prepare("UPDATE projects SET label=?1 WHERE id=?2");
        defer stmt.finalize();
        try stmt.bindText(1, label);
        try stmt.bindI64(2, id);
        _ = try stmt.step();
        try tx.commit();
    }

    pub fn archiveProject(s: *Store, id: i64, archived: bool, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (!try s.projectExists(id)) return error.UnknownProject;
        var stmt = try s.db.prepare("UPDATE projects SET archived=?1 WHERE id=?2");
        defer stmt.finalize();
        try stmt.bindI64(1, @intFromBool(archived));
        try stmt.bindI64(2, id);
        _ = try stmt.step();
        try tx.commit();
    }

    /// Removes a project. Its tasks, time and capture keys move to `into`;
    /// with no target the time becomes unassigned and the keys are dropped,
    /// so the next capture from them finds a project again.
    pub fn deleteProject(s: *Store, id: i64, into: ?i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (!try s.projectExists(id)) return error.UnknownProject;
        if (into) |target| if (target == id or !try s.projectExists(target)) return error.UnknownProject;
        var spans = try s.db.prepare("SELECT start_ms,coalesce(end_ms,start_ms) FROM intervals WHERE project_id=?1");
        defer spans.finalize();
        try spans.bindI64(1, id);
        while (try spans.step() == .row) try s.markEdited(spans.columnI64(0), spans.columnI64(1), now_ms);
        for ([_][]const u8{
            "UPDATE tasks SET project_id=?2 WHERE project_id=?1",
            "UPDATE intervals SET project_id=?2 WHERE project_id=?1",
            "UPDATE saved_set SET project_id=?2 WHERE project_id=?1",
            "UPDATE capture_runs SET project_id=?2 WHERE project_id=?1",
        }) |sql| {
            var stmt = try s.db.prepare(sql);
            defer stmt.finalize();
            try stmt.bindI64(1, id);
            if (into) |target| try stmt.bindI64(2, target) else try stmt.bindNull(2);
            _ = try stmt.step();
        }
        var keys = try s.db.prepare(if (into == null) "DELETE FROM capture_project_keys WHERE project_id=?1" else "UPDATE capture_project_keys SET project_id=?2 WHERE project_id=?1");
        defer keys.finalize();
        try keys.bindI64(1, id);
        if (into) |target| try keys.bindI64(2, target);
        _ = try keys.step();
        var drop = try s.db.prepare("DELETE FROM projects WHERE id=?1");
        defer drop.finalize();
        try drop.bindI64(1, id);
        _ = try drop.step();
        try tx.commit();
    }

    pub fn setTaskProject(s: *Store, task: i64, project: ?i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (project) |id| if (!try s.projectExists(id)) return error.UnknownProject;
        var stmt = try s.db.prepare("UPDATE tasks SET project_id=?1,project_choice_explicit=1,project_fallback_eligible=0 WHERE id=?2");
        defer stmt.finalize();
        if (project) |id| try stmt.bindI64(1, id) else try stmt.bindNull(1);
        try stmt.bindI64(2, task);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.UnknownTask;
        try tx.commit();
    }

    pub fn updateTask(s: *Store, task: i64, title: ?[]const u8, choice: ProjectChoice, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (title) |value| {
            if (value.len == 0) return error.EmptyText;
            var bound = try s.db.prepare("SELECT 1 FROM task_bindings WHERE task_id=?1");
            defer bound.finalize();
            try bound.bindI64(1, task);
            if (try bound.step() == .row) return error.TaskBound;
            var rename = try s.db.prepare("UPDATE tasks SET title=?1 WHERE id=?2");
            defer rename.finalize();
            try rename.bindText(1, value);
            try rename.bindI64(2, task);
            _ = try rename.step();
            if (s.db.changes() == 0) return error.UnknownTask;
            try s.clearProvisionalTitles(task);
        }
        if (choice == .selected) {
            if (choice.selected) |id| if (!try s.projectExists(id)) return error.UnknownProject;
            var assign = try s.db.prepare("UPDATE tasks SET project_id=?1,project_choice_explicit=1,project_fallback_eligible=0 WHERE id=?2");
            defer assign.finalize();
            if (choice.selected) |id| try assign.bindI64(1, id) else try assign.bindNull(1);
            try assign.bindI64(2, task);
            _ = try assign.step();
            if (s.db.changes() == 0) return error.UnknownTask;
        }
        try tx.commit();
    }

    pub fn applyProjectAssign(s: *Store, snapshot: AssignmentSnapshot, target: ?i64, now_ms: i64) Error!AssignmentResult {
        if (now_ms < 0 or now_ms >= max_time_ms) return error.InvalidTime;
        var tx = try s.db.transaction();
        defer tx.deinit();
        if (target != snapshot.project_id) return error.Stale;
        if (target) |id| if (!try s.projectExists(id)) return error.UnknownProject;
        const zone_setting = try s.getSetting("reporting_zone");
        defer if (zone_setting) |name| s.allocator.free(name);
        if (!std.mem.eql(u8, snapshot.reporting_zone, zone_setting orelse "UTC")) return error.Stale;
        const current_zone = try s.loadZone();
        if (snapshot.day_start_min != current_zone.day_start_min) return error.Stale;
        var focus_ms: i64 = 0;
        for (snapshot.intervals, 0..) |row, i| {
            if (row.end_ms == null or row.project_id == target) return error.Stale;
            for (snapshot.intervals[0..i]) |prior| if (prior.id == row.id) return error.Stale;
            var stmt = try s.db.prepare("SELECT task_id,project_id,role,start_ms,end_ms FROM intervals WHERE id=?1");
            defer stmt.finalize();
            try stmt.bindI64(1, row.id);
            if (try stmt.step() != .row) return error.Stale;
            const old_project: ?i64 = if (stmt.columnIsNull(1)) null else stmt.columnI64(1);
            if (stmt.columnIsNull(4) or stmt.columnI64(0) != row.task_id or old_project != row.project_id or
                !std.mem.eql(u8, stmt.columnText(2).?, row.role) or stmt.columnI64(3) != row.start_ms or
                stmt.columnI64(4) != row.end_ms.?) return error.Stale;
            const actual_focus: i64 = if (std.mem.eql(u8, row.role, "focus")) row.end_ms.? - row.start_ms else 0;
            if (actual_focus != row.focus_ms) return error.Stale;
            focus_ms += actual_focus;
        }
        const totals = try assignmentTotals(s.allocator, snapshot.intervals, current_zone);
        defer {
            for (totals) |total| s.allocator.free(total.date);
            s.allocator.free(totals);
        }
        if (totals.len != snapshot.totals.len) return error.Stale;
        for (totals) |total| {
            var found = false;
            for (snapshot.totals) |reviewed| if (total.project_id == reviewed.project_id and std.mem.eql(u8, total.date, reviewed.date) and total.focus_ms == reviewed.focus_ms) { found = true; break; };
            if (!found) return error.Stale;
        }
        for (snapshot.intervals) |row| {
            var stmt = try s.db.prepare("UPDATE intervals SET project_id=?1 WHERE id=?2");
            defer stmt.finalize();
            if (target) |id| try stmt.bindI64(1, id) else try stmt.bindNull(1);
            try stmt.bindI64(2, row.id);
            _ = try stmt.step();
            try s.markEdited(row.start_ms, row.end_ms.?, now_ms);
        }
        try tx.commit();
        return .{ .changed = snapshot.intervals.len, .focus_ms = focus_ms };
    }

    pub fn setCaptureProjectKey(s: *Store, source: []const u8, key: []const u8, hint: []const u8, project: i64, now_ms: i64) Error!void {
        if (key.len == 0 or key.len > 2048 or hint.len > 200) return error.InvalidProjectLabel;
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (!try s.projectExists(project)) return error.UnknownProject;
        var stmt = try s.db.prepare("INSERT INTO capture_project_keys(source,project_key,project_id,project_hint) VALUES(?1,?2,?3,?4) ON CONFLICT(source,project_key) DO UPDATE SET project_id=excluded.project_id,project_hint=excluded.project_hint");
        defer stmt.finalize();
        try stmt.bindText(1, source);
        try stmt.bindText(2, key);
        try stmt.bindI64(3, project);
        try stmt.bindText(4, hint);
        _ = try stmt.step();
        try tx.commit();
    }

    fn mappedProject(s: *Store, source: []const u8, key: []const u8) !?i64 {
        var stmt = try s.db.prepare("SELECT project_id FROM capture_project_keys WHERE source=?1 AND project_key=?2");
        defer stmt.finalize();
        try stmt.bindText(1, source);
        try stmt.bindText(2, key);
        return if (try stmt.step() == .row) stmt.columnI64(0) else null;
    }

    /// A project the user made with this label: unarchived and claimed by no
    /// capture key, so a new key lands there instead of beside it.
    /// The project every source already maps this key to; none when the
    /// sources disagree, so a new source does not pick a side.
    fn keyProject(s: *Store, key: []const u8) !?i64 {
        var stmt = try s.db.prepare("SELECT min(project_id) FROM capture_project_keys WHERE project_key=?1 HAVING count(DISTINCT project_id)=1");
        defer stmt.finalize();
        try stmt.bindText(1, key);
        return if (try stmt.step() == .row) stmt.columnI64(0) else null;
    }

    /// Points every source's mapping of a key at one project.
    pub fn setKeyProject(s: *Store, key: []const u8, project: i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (!try s.projectExists(project)) return error.UnknownProject;
        var stmt = try s.db.prepare("UPDATE capture_project_keys SET project_id=?2 WHERE project_key=?1");
        defer stmt.finalize();
        try stmt.bindText(1, key);
        try stmt.bindI64(2, project);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.UnknownProject;
        try tx.commit();
    }

    fn unclaimedProject(s: *Store, label: []const u8) !?i64 {
        var stmt = try s.db.prepare("SELECT id FROM projects p WHERE label=?1 COLLATE NOCASE AND archived=0 AND NOT EXISTS (SELECT 1 FROM capture_project_keys k WHERE k.project_id=p.id)");
        defer stmt.finalize();
        try stmt.bindText(1, label);
        return if (try stmt.step() == .row) stmt.columnI64(0) else null;
    }

    fn uniqueCaptureLabel(s: *Store, source: []const u8, key: []const u8, hint: []const u8) ![]const u8 {
        const base = std.mem.trim(u8, hint, " \t\r\n");
        if (!validProjectLabel(base)) return error.InvalidProjectLabel;
        if (try s.projectByLabel(base) == null) return try s.allocator.dupe(u8, base);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(source);
        hasher.update(&.{0});
        hasher.update(key);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const alphabet = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, i| {
            hex[i * 2] = alphabet[byte >> 4];
            hex[i * 2 + 1] = alphabet[byte & 15];
        }
        var prefix: usize = 8;
        var number: usize = 0;
        while (true) {
            var suffix_buf: [96]u8 = undefined;
            const suffix = if (number == 0)
                try std.fmt.bufPrint(&suffix_buf, "-{s}", .{hex[0..prefix]})
            else
                try std.fmt.bufPrint(&suffix_buf, "-{s}-{d}", .{ hex, number });
            var base_len = @min(base.len, 200 - suffix.len);
            while (base_len > 0 and !std.unicode.utf8ValidateSlice(base[0..base_len])) : (base_len -= 1) {}
            const label = try std.mem.concat(s.allocator, u8, &.{ base[0..base_len], suffix });
            if (try s.projectByLabel(label) == null) return label;
            s.allocator.free(label);
            if (prefix < 64) prefix = @min(64, prefix + 4) else number += 1;
        }
    }

    fn resolveCaptureProject(s: *Store, source: []const u8, key: ?[]const u8, hint: ?[]const u8, task: ?i64) !?i64 {
        if (key) |k| {
            if (k.len == 0 or k.len > 2048) return error.InvalidProjectKey;
            if (try s.mappedProject(source, k)) |id| return id;
            const raw = hint orelse return error.InvalidProjectLabel;
            if (raw.len > 200) return error.InvalidProjectLabel;
            // The same key from another source is the same work.
            const id = if (try s.keyProject(k)) |shared| shared else if (try s.unclaimedProject(std.mem.trim(u8, raw, " \t\r\n"))) |own| own else blk: {
                const label = try s.uniqueCaptureLabel(source, k, raw);
                defer s.allocator.free(label);
                break :blk try s.insertProject(label);
            };
            var stmt = try s.db.prepare("INSERT INTO capture_project_keys(source,project_key,project_id,project_hint) VALUES(?1,?2,?3,?4)");
            defer stmt.finalize();
            try stmt.bindText(1, source);
            try stmt.bindText(2, k);
            try stmt.bindI64(3, id);
            try stmt.bindText(4, std.mem.trim(u8, raw, " \t\r\n"));
            _ = try stmt.step();
            return id;
        }
        return if (task) |t| try s.taskProject(t) else null;
    }

    fn resolveCaptureTask(s: *Store, text: []const u8, scope: ?i64, now_ms: i64) !i64 {
        const title = std.mem.trim(u8, text, " \t");
        if (title.len == 0) return error.EmptyText;
        if (title[0] == '#') {
            const id = std.fmt.parseInt(i64, title[1..], 10) catch return error.UnknownTask;
            var by_id = try s.db.prepare("SELECT 1 FROM tasks WHERE id=?1");
            defer by_id.finalize();
            try by_id.bindI64(1, id);
            if (try by_id.step() != .row) return error.UnknownTask;
            return id;
        }
        const steps = [_][]const u8{
            "SELECT task_id FROM task_bindings WHERE external_ref=?1 ORDER BY task_id LIMIT 2",
            "SELECT id FROM tasks WHERE title=?1 COLLATE NOCASE AND project_id IS ?2 ORDER BY id LIMIT 2",
        };
        for (steps, 0..) |sql, i| {
            var stmt = try s.db.prepare(sql);
            defer stmt.finalize();
            try stmt.bindText(1, title);
            if (i == 1) {
                if (scope) |id| try stmt.bindI64(2, id) else try stmt.bindNull(2);
            }
            if (try stmt.step() == .row) {
                const id = stmt.columnI64(0);
                if (try stmt.step() == .row) return error.AmbiguousTask;
                return id;
            }
        }
        return s.insertTask(title, .{ .selected = scope }, now_ms);
    }

    fn weakSessionSeed(seed: []const u8) bool {
        const trimmed = std.mem.trim(u8, seed, " \t\r\n");
        const clean = std.mem.trimEnd(u8, trimmed, " \t\r\n.,!?;:");
        if (clean.len == 0) return true;
        const digits = if (clean[0] == '#') clean[1..] else clean;
        var only_digits = digits.len > 0;
        for (digits) |ch| if (!std.ascii.isDigit(ch)) {
            only_digits = false;
            break;
        };
        if (only_digits) return true;
        const acknowledgements = [_][]const u8{
            "go ahead", "yes", "ok", "continue", "do it", "proceed", "sure", "thanks",
            "sim", "pode", "continua", "manda ver",
        };
        for (acknowledgements) |ack| if (std.ascii.eqlIgnoreCase(clean, ack)) return true;
        var words = std.mem.tokenizeAny(u8, clean, " \t\r\n");
        var count: usize = 0;
        while (words.next() != null) {
            count += 1;
            if (count >= 3) return false;
        }
        return true;
    }

    fn sessionTitle(s: *Store, seed: ?[]const u8) ![]const u8 {
        const raw = seed orelse "";
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidCharacter;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(s.allocator);
        var pending_space = false;
        for (raw) |ch| {
            if (std.ascii.isWhitespace(ch)) {
                if (out.items.len > 0) pending_space = true;
            } else {
                if (pending_space) try out.append(s.allocator, ' ');
                pending_space = false;
                try out.append(s.allocator, ch);
            }
        }
        if (out.items.len == 0) {
            out.deinit(s.allocator);
            return s.allocator.dupe(u8, "Session");
        }
        var i: usize = 0;
        var points: usize = 0;
        var boundary: ?usize = null;
        while (i < out.items.len and points < 60) {
            const ch = out.items[i];
            const width = std.unicode.utf8ByteSequenceLength(ch) catch unreachable;
            const next = i + width;
            points += 1;
            if (ch == ' ') boundary = i;
            if ((ch == '.' or ch == '!' or ch == '?') and (next == out.items.len or out.items[next] == ' ')) {
                out.shrinkRetainingCapacity(i);
                return out.toOwnedSlice(s.allocator);
            }
            i = next;
        }
        if (i < out.items.len) {
            out.shrinkRetainingCapacity(if (out.items[i] == ' ') i else boundary orelse i);
            try out.appendSlice(s.allocator, "...");
        }
        return out.toOwnedSlice(s.allocator);
    }

    pub fn init(db: *sqlite.Db, allocator: std.mem.Allocator) Error!Store {
        try schema.ensure(db);
        return .{ .db = db, .allocator = allocator };
    }

    fn begin(s: *Store, now_ms: i64, force: bool) !sqlite.Transaction {
        if (now_ms < 0 or now_ms >= max_time_ms) return error.InvalidTime;
        var recovery_tx = try s.db.transaction();
        defer recovery_tx.deinit();
        if (force) try s.recover() else try s.guard(now_ms);
        try recovery_tx.commit();
        return s.db.transaction();
    }

    fn lastHeartbeat(s: *Store) !?i64 {
        var stmt = try s.db.prepare("SELECT value FROM meta WHERE key='last_heartbeat_ms'");
        defer stmt.finalize();
        if (try stmt.step() == .done) return null;
        return std.fmt.parseInt(i64, stmt.columnText(0).?, 10) catch null;
    }

    fn heartbeat(s: *Store, now_ms: i64) !void {
        var buffer: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buffer, "{d}", .{now_ms});
        var stmt = try s.db.prepare("INSERT INTO meta(key,value) VALUES('last_heartbeat_ms',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
        defer stmt.finalize();
        try stmt.bindText(1, value);
        _ = try stmt.step();
    }

    fn hasOpen(s: *Store) !bool {
        var stmt = try s.db.prepare("SELECT 1 FROM intervals WHERE end_ms IS NULL LIMIT 1");
        defer stmt.finalize();
        return try stmt.step() == .row;
    }

    fn guard(s: *Store, now_ms: i64) !void {
        if (!try s.hasOpen()) return;
        const last = try s.lastHeartbeat();
        if (last == null or @as(i128, now_ms) - @as(i128, last.?) > 180_000) try s.recover();
    }

    // Caller owns the transaction. Recovery is also used unconditionally at startup and resume.
    fn recover(s: *Store) !void {
        if (!try s.hasOpen()) return;
        const last = try s.lastHeartbeat();
        try s.db.exec("DELETE FROM saved_set");
        try s.db.exec("INSERT INTO saved_set(task_id,role,project_id) SELECT task_id,role,project_id FROM intervals WHERE end_ms IS NULL");
        var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,coalesce(?1,start_ms)), closed_by='recovered' WHERE end_ms IS NULL");
        defer stmt.finalize();
        if (last) |ms| try stmt.bindI64(1, ms) else try stmt.bindNull(1);
        _ = try stmt.step();
    }

    pub fn onStart(s: *Store, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, true);
        defer tx.deinit();
        try s.db.exec("UPDATE postings SET state='unknown' WHERE state='sending'");
        try s.heartbeat(now_ms);
        try tx.commit();
    }

    pub fn onResume(s: *Store, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, true);
        defer tx.deinit();
        try s.heartbeat(now_ms);
        try tx.commit();
    }

    pub fn onHeartbeat(s: *Store, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        // Captured runs gone quiet close on time, not at the next event.
        try s.expireRuns(now_ms);
        try s.heartbeat(now_ms);
        try tx.commit();
    }

    /// A screen lock pauses, like the pause button, inside one of the
    /// `lock_pause` windows ("11:30-13:30,17:00-19:00"; a window may cross
    /// midnight), read in the reporting zone. Returns whether it paused.
    pub fn onLock(s: *Store, now_ms: i64) Error!bool {
        const windows = try s.getSetting("lock_pause") orelse return false;
        defer s.allocator.free(windows);
        const id = try s.reportingZone() orelse return false;
        defer s.allocator.free(id);
        const z = try s.loadZone();
        const local = z.localOf(now_ms) catch return error.InvalidTime;
        if (!(lockWindowsContain(windows, @as(u16, local.hour) * 60 + local.minute) orelse false)) return false;
        if (!try s.hasOpen()) return false;
        try s.pause(now_ms);
        return true;
    }

    pub fn createTask(s: *Store, title: []const u8, now_ms: i64) Error!i64 {
        return s.createTaskWithProject(title, .omitted, now_ms);
    }

    pub fn createTaskWithProject(s: *Store, title: []const u8, choice: ProjectChoice, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (title.len == 0) return error.EmptyText;
        const id = try s.insertTask(title, choice, now_ms);
        try tx.commit();
        return id;
    }

    fn insertTask(s: *Store, title: []const u8, choice: ProjectChoice, now_ms: i64) !i64 {
        const project: ?i64 = switch (choice) { .omitted => null, .selected => |id| id };
        if (project) |id| if (!try s.projectExists(id)) return error.UnknownProject;
        var stmt = try s.db.prepare("INSERT INTO tasks(title,created_ms,project_id,project_choice_explicit,project_fallback_eligible) VALUES(?1,?2,?3,?4,?5) RETURNING id");
        defer stmt.finalize();
        try stmt.bindText(1, title);
        try stmt.bindI64(2, now_ms);
        if (project) |id| try stmt.bindI64(3, id) else try stmt.bindNull(3);
        try stmt.bindI64(4, if (choice == .omitted) 0 else 1);
        try stmt.bindI64(5, if (choice == .omitted) 1 else 0);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        return id;
    }

    fn taskProject(s: *Store, task: i64) !?i64 {
        var stmt = try s.db.prepare("SELECT project_id FROM tasks WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        if (try stmt.step() == .done) return error.UnknownTask;
        return if (stmt.columnIsNull(0)) null else stmt.columnI64(0);
    }

    fn chosenProject(s: *Store, task: i64, choice: ProjectChoice) !?i64 {
        return switch (choice) {
            .omitted => try s.taskProject(task),
            .selected => |id| blk: {
                if (id) |v| if (!try s.projectExists(v)) return error.UnknownProject;
                break :blk id;
            },
        };
    }

    pub fn setTitle(s: *Store, task: i64, title: []const u8, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (title.len == 0) return error.EmptyText;
        var stmt = try s.db.prepare("UPDATE tasks SET title=?1 WHERE id=?2");
        defer stmt.finalize();
        try stmt.bindText(1, title);
        try stmt.bindI64(2, task);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.UnknownTask;
        try s.clearProvisionalTitles(task);
        try tx.commit();
    }

    fn clearProvisionalTitles(s: *Store, task: i64) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET provisional_title=0 WHERE task_id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        _ = try stmt.step();
    }

    pub fn bind(s: *Store, task: i64, instance: []const u8, ref: []const u8, now_ms: i64) Error!void {
        return s.bindWithFields(task, instance, ref, &.{}, now_ms);
    }

    pub const FieldValue = struct { name: []const u8, value: []const u8 };

    /// Binds a task and stores the provider's field values in one transaction.
    /// An empty value removes the field; fields not named are left alone.
    pub fn bindWithFields(s: *Store, task: i64, instance: []const u8, ref: []const u8, values: []const FieldValue, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (try s.taskByBinding(instance, ref)) |bound_task| {
            if (bound_task != task) return error.BindingConflict;
        }
        var stmt = try s.db.prepare("INSERT INTO task_bindings(task_id,provider_instance,external_ref) VALUES(?1,?2,?3) ON CONFLICT(task_id) DO UPDATE SET provider_instance=excluded.provider_instance,external_ref=excluded.external_ref");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, instance);
        try stmt.bindText(3, ref);
        _ = try stmt.step();
        for (values) |v| try s.putField(task, v.name, v.value);
        try s.applyProviderProjectFallback(task, values);
        try tx.commit();
    }

    fn applyProviderProjectFallback(s: *Store, task: i64, values: []const FieldValue) !void {
        var eligible = try s.db.prepare("SELECT project_fallback_eligible FROM tasks WHERE id=?1");
        defer eligible.finalize();
        try eligible.bindI64(1, task);
        if (try eligible.step() != .row or eligible.columnI64(0) == 0) return;
        var consume = try s.db.prepare("UPDATE tasks SET project_fallback_eligible=0 WHERE id=?1");
        defer consume.finalize();
        try consume.bindI64(1, task);
        _ = try consume.step();
        var setting = try s.db.prepare("SELECT value FROM settings WHERE key='project_provider_field'");
        defer setting.finalize();
        if (try setting.step() != .row) return;
        const name = setting.columnText(0).?;
        if (name.len == 0) return;
        for (values) |v| if (std.mem.eql(u8, v.name, name)) {
            if (!validProjectLabel(v.value)) return;
            const project = (try s.projectByLabel(v.value)) orelse try s.insertProject(v.value);
            var update = try s.db.prepare("UPDATE tasks SET project_id=?1 WHERE id=?2");
            defer update.finalize();
            try update.bindI64(1, project);
            try update.bindI64(2, task);
            _ = try update.step();
            return;
        };
    }

    pub fn taskByBinding(s: *Store, instance: []const u8, ref: []const u8) Error!?i64 {
        var stmt = try s.db.prepare("SELECT task_id FROM task_bindings WHERE provider_instance=?1 AND external_ref=?2");
        defer stmt.finalize();
        try stmt.bindText(1, instance);
        try stmt.bindText(2, ref);
        if (try stmt.step() == .done) return null;
        return stmt.columnI64(0);
    }

    pub fn setField(s: *Store, task: i64, name: []const u8, value: []const u8, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        try s.putField(task, name, value);
        try tx.commit();
    }

    fn putField(s: *Store, task: i64, name: []const u8, value: []const u8) !void {
        if (value.len == 0) {
            var stmt = try s.db.prepare("DELETE FROM task_fields WHERE task_id=?1 AND name=?2");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            try stmt.bindText(2, name);
            _ = try stmt.step();
        } else {
            var stmt = try s.db.prepare("INSERT INTO task_fields(task_id,name,value) VALUES(?1,?2,?3) ON CONFLICT(task_id,name) DO UPDATE SET value=excluded.value");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            try stmt.bindText(2, name);
            try stmt.bindText(3, value);
            _ = try stmt.step();
        }
    }

    /// Same-millisecond hops are nudged at most this far forward; a bigger gap is a clock jump, not a hop.
    const max_nudge_ms: i64 = 1_000;

    /// The time an interval write lands at: never before a live interval's end and never at an open
    /// interval's start, so starting and stopping, or hopping twice, in one millisecond writes 1 ms
    /// intervals instead of zero-length or overlapping ones.
    fn intervalTime(s: *Store, now_ms: i64) !i64 {
        var stmt = try s.db.prepare("SELECT max(coalesce(end_ms,start_ms+1)) FROM intervals");
        defer stmt.finalize();
        if (try stmt.step() != .row or stmt.columnIsNull(0)) return now_ms;
        const floor = stmt.columnI64(0);
        if (floor <= now_ms or floor - now_ms > max_nudge_ms) return now_ms;
        if (floor >= max_time_ms) return error.InvalidTime;
        return floor;
    }

    fn openInterval(s: *Store, task: i64, role: Role, reason: OpenedBy, text: ?[]const u8, project: ?i64, now_ms: i64) !i64 {
        {
            // Any new activity ends a lunch break.
            var lunch_end = try s.db.prepare("UPDATE lunches SET back_ms=max(out_ms,?1) WHERE back_ms IS NULL");
            defer lunch_end.finalize();
            try lunch_end.bindI64(1, now_ms);
            _ = try lunch_end.step();
        }
        var stmt = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,opened_by,text,project_id) VALUES(?1,?2,?3,?4,?5,?6) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, sqlText(role));
        try stmt.bindI64(3, now_ms);
        try stmt.bindText(4, sqlText(reason));
        try stmt.bindOptionalText(5, text);
        if (project) |id| try stmt.bindI64(6, id) else try stmt.bindNull(6);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        return id;
    }

    fn closeFocus(s: *Store, reason: ClosedBy, now_ms: i64) !void {
        var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by=?2 WHERE end_ms IS NULL AND role='focus'");
        defer stmt.finalize();
        try stmt.bindI64(1, now_ms);
        try stmt.bindText(2, sqlText(reason));
        _ = try stmt.step();
    }

    pub fn switchTo(s: *Store, task: i64, text: ?[]const u8, now_ms: i64) Error!i64 {
        return s.switchToProject(task, text, .omitted, now_ms);
    }

    pub fn switchToProject(s: *Store, task: i64, text: ?[]const u8, choice: ProjectChoice, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const project = try s.chosenProject(task, choice);
        var split_span: ?i64 = null;
        var split_id: ?i64 = null;
        {
            var focus = try s.db.prepare("SELECT id,task_id,project_id,posting_span_id FROM intervals WHERE end_ms IS NULL AND role='focus'");
            defer focus.finalize();
            if (try focus.step() == .row and focus.columnI64(1) == task) {
                const id = focus.columnI64(0);
                const current_project: ?i64 = if (focus.columnIsNull(2)) null else focus.columnI64(2);
                if (choice == .omitted or current_project == project) {
                    try tx.commit();
                    return id;
                }
                split_span = if (focus.columnIsNull(3)) id else focus.columnI64(3);
                split_id = id;
            }
        }
        const at = try s.intervalTime(now_ms);
        try s.closeFocus(.@"switch", at);
        if (split_span) |span| {
            var mark = try s.db.prepare("UPDATE intervals SET posting_span_id=?1 WHERE id=?2");
            defer mark.finalize();
            try mark.bindI64(1, span);
            try mark.bindI64(2, split_id.?);
            _ = try mark.step();
        }
        {
            var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by='switch' WHERE end_ms IS NULL AND role='parallel' AND task_id=?2");
            defer stmt.finalize();
            try stmt.bindI64(1, at);
            try stmt.bindI64(2, task);
            _ = try stmt.step();
        }
        const id = try s.openInterval(task, .focus, .@"switch", text, project, at);
        if (split_span) |span| {
            var mark = try s.db.prepare("UPDATE intervals SET posting_span_id=?1 WHERE id=?2");
            defer mark.finalize();
            try mark.bindI64(1, span);
            try mark.bindI64(2, id);
            _ = try mark.step();
        }
        try s.db.exec("DELETE FROM saved_set");
        try s.heartbeat(at);
        try tx.commit();
        return id;
    }

    pub fn openParallel(s: *Store, task: i64, text: ?[]const u8, now_ms: i64) Error!i64 {
        return s.openParallelProject(task, text, .omitted, now_ms);
    }

    pub fn openParallelProject(s: *Store, task: i64, text: ?[]const u8, choice: ProjectChoice, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const project = try s.chosenProject(task, choice);
        {
            var stmt = try s.db.prepare("SELECT 1 FROM intervals WHERE task_id=?1 AND end_ms IS NULL");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            if (try stmt.step() == .row) return error.AlreadyOpen;
        }
        const at = try s.intervalTime(now_ms);
        const id = try s.openInterval(task, .parallel, .parallel, text, project, at);
        try s.db.exec("DELETE FROM saved_set");
        try s.heartbeat(at);
        try tx.commit();
        return id;
    }

    pub fn stop(s: *Store, task: i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const at = try s.intervalTime(now_ms);
        var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by='stop' WHERE task_id=?2 AND end_ms IS NULL");
        defer stmt.finalize();
        try stmt.bindI64(1, at);
        try stmt.bindI64(2, task);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.NoOpenInterval;
        try tx.commit();
    }

    /// Applies one event from an outside source (an agent session, a game
    /// overlay). A run that works on a task keeps that task open: the
    /// attended run may take the focus after sustained prompts; other working
    /// runs run in parallel. Returns false for an event id already applied.
    pub fn capture(s: *Store, c: Capture, now_ms: i64) Error!bool {
        return (try s.captureDetailed(c, now_ms)).applied;
    }

    pub fn captureDetailed(s: *Store, c: Capture, now_ms: i64) Error!CaptureResult {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const capture_text = try s.getSetting("capture_text");
        defer if (capture_text) |value| s.allocator.free(value);
        const time_only = if (capture_text) |value| std.mem.eql(u8, value, "time") else false;
        const at = try s.intervalTime(now_ms);
        if (c.event) |event| {
            var stmt = try s.db.prepare("INSERT OR IGNORE INTO capture_events(source,event,run,kind,at_ms) VALUES(?1,?2,?3,?4,?5)");
            defer stmt.finalize();
            try stmt.bindText(1, c.source);
            try stmt.bindText(2, event);
            try stmt.bindText(3, c.run);
            try stmt.bindText(4, @tagName(c.kind));
            try stmt.bindI64(5, at);
            _ = try stmt.step();
            if (s.db.changes() == 0) {
                const old = s.captureRun(c.source, c.run) catch null;
                try tx.commit();
                return .{ .applied = false, .project_id = if (old) |r| r.project else null, .task_id = if (old) |r| r.task else null };
            }
        }
        try s.expireRuns(at);
        {
            var stmt = try s.db.prepare("INSERT INTO capture_runs(source,run,task_id,attended,started_ms) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(source,run) DO UPDATE SET attended=excluded.attended, task_id=coalesce(task_id,excluded.task_id)");
            defer stmt.finalize();
            try stmt.bindText(1, c.source);
            try stmt.bindText(2, c.run);
            if (c.default_task) |t| try stmt.bindI64(3, t) else try stmt.bindNull(3);
            try stmt.bindI64(4, @intFromBool(c.attended));
            try stmt.bindI64(5, at);
            _ = try stmt.step();
        }
        var run = try s.captureRun(c.source, c.run);
        const saved_key = try s.savedCaptureKey(c.source, c.run);
        defer if (saved_key) |key| s.allocator.free(key);
        const key = c.project_key orelse saved_key;
        const lookup_project = try s.resolveCaptureProject(c.source, key, c.project_hint, run.task);
        if (c.project_key != null) try s.setRunProjectKey(c, c.project_key);
        var target_task = run.task;
        if (c.kind == .subject) {
            try s.setProvisionalTitle(c, false);
            run.provisional_title = false;
            target_task = c.task orelse if (c.subject) |subject| try s.resolveCaptureTask(subject, lookup_project, at) else return error.UnknownTask;
        } else if (c.task != null or c.subject != null) {
            try s.setProvisionalTitle(c, false);
            run.provisional_title = false;
            // A subject sent with any event names the run's task before the event applies;
            // a prompt or busy then engages it in its own role.
            const task = c.task orelse try s.resolveCaptureTask(c.subject.?, lookup_project, at);
            if (run.task != task) {
                const moved_project = try s.resolveCaptureProject(c.source, key, c.project_hint, task);
                try s.moveRun(c, run, task, moved_project, at, c.kind != .prompt and c.kind != .busy);
                run = try s.captureRun(c.source, c.run);
            }
        } else if (run.task == null) {
            if (c.default_subject) |subject| {
                const task = try s.resolveCaptureTask(subject, lookup_project, at);
                try s.setRun(c, task, run.working, run.role, run.lease_until);
                run.task = task;
            } else if (c.kind == .prompt and c.default_task == null) {
                const title = try s.sessionTitle(if (time_only) null else c.first_prompt);
                defer s.allocator.free(title);
                const task = try s.insertTask(title, .{ .selected = lookup_project }, at);
                try s.setRun(c, task, run.working, run.role, run.lease_until);
                run.task = task;
                if (!time_only and (c.first_prompt == null or weakSessionSeed(c.first_prompt.?))) {
                    try s.setProvisionalTitle(c, true);
                    run.provisional_title = true;
                }
            }
        }
        if (c.kind == .prompt and !time_only and run.provisional_title and c.task == null and c.subject == null) {
            if (c.first_prompt) |seed| {
                if (!weakSessionSeed(seed)) if (run.task) |task| {
                    const title = try s.sessionTitle(seed);
                    defer s.allocator.free(title);
                    var rename = try s.db.prepare("UPDATE tasks SET title=?1 WHERE id=?2");
                    defer rename.finalize();
                    try rename.bindText(1, title);
                    try rename.bindI64(2, task);
                    _ = try rename.step();
                    try s.setProvisionalTitle(c, false);
                };
            }
        }
        if (c.kind != .subject) target_task = run.task;
        const project = try s.resolveCaptureProject(c.source, key, c.project_hint, target_task);
        try s.setRunProject(c, project);
        const holding = try s.isHoldingSource(c.source);
        switch (c.kind) {
            .start => if (holding and run.task != null) {
                try s.setRun(c, run.task, true, .focus, at + capture_lease_ms);
                try s.setRole(c, try s.engage(c, run.task, .focus, project, at));
            },
            .subject => {
                const task = target_task.?;
                if (run.task != task) {
                    try s.moveRun(c, run, task, project, at, true);
                    if (holding and !run.working and run.idle == null) {
                        try s.setRun(c, task, true, .focus, at + capture_lease_ms);
                        try s.setRole(c, try s.engage(c, task, .focus, project, at));
                    }
                } else if (run.working) {
                    try s.setRole(c, try s.engage(c, task, if (holding) .focus else run.role orelse .parallel, project, at));
                } else if (holding and run.idle == null) {
                    try s.setRun(c, task, true, .focus, at + capture_lease_ms);
                    try s.setRole(c, try s.engage(c, task, .focus, project, at));
                }
            },
            .prompt => {
                const role: Role = if (holding or c.attended) .focus else .parallel;
                try s.setRun(c, run.task, true, role, at + capture_lease_ms);
                try s.setRole(c, try s.engage(c, run.task, role, project, at));
            },
            .busy => {
                if (run.working or run.idle != null) {
                    const role: Role = if (holding) .focus else run.role orelse .parallel;
                    try s.setRun(c, run.task, true, role, at + capture_lease_ms);
                    try s.setRole(c, try s.engage(c, run.task, role, project, at));
                } else {
                    const role: Role = if (holding) .focus else .parallel;
                    try s.setRun(c, run.task, true, role, at + capture_lease_ms);
                    try s.setRole(c, try s.engage(c, run.task, role, project, at));
                }
            },
            .stop => if (run.working) {
                // Kept open for a short grace: a prompt soon after carries on.
                try s.setRun(c, run.task, false, run.role, at + capture_idle_ms);
                try s.setIdle(c, at);
            },
            .end => {
                try s.setRun(c, run.task, false, null, null);
                if (run.working or run.idle != null) try s.releaseTask(c, run.task, run.idle orelse at, .stop);
                {
                    var stmt = try s.db.prepare("UPDATE capture_runs SET ended_ms=?3 WHERE source=?1 AND run=?2");
                    defer stmt.finalize();
                    try stmt.bindText(1, c.source);
                    try stmt.bindText(2, c.run);
                    try stmt.bindI64(3, at);
                    _ = try stmt.step();
                }
            },
        }
        if (!time_only) if (c.note) |text| if (c.kind != .start and c.kind != .end) try s.captureNote(c, at, text);
        try s.heartbeat(at);
        const final = try s.captureRun(c.source, c.run);
        try tx.commit();
        return .{ .applied = true, .project_id = final.project, .task_id = final.task };
    }

    /// Called by the history subject resolver while the batch transaction is open.
    pub fn createHistoryTask(s: *Store, title: []const u8, now_ms: i64) !i64 {
        var stmt = try s.db.prepare("INSERT INTO tasks(title,created_ms) VALUES(?1,?2) RETURNING id");
        defer stmt.finalize();
        try stmt.bindText(1, title);
        try stmt.bindI64(2, now_ms);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        return id;
    }

    pub fn captureHistory(s: *Store, allocator: std.mem.Allocator, source: []const u8, run: []const u8, attended: bool, intervals: []const HistoryInterval, now_ms: i64, resolve: *const fn (*Store, std.mem.Allocator, []const u8, i64) anyerror!?i64) !HistoryResult {
        if (now_ms < 0 or now_ms >= max_time_ms) return error.InvalidTime;
        var tx = try s.db.transaction();
        defer tx.deinit();
        var result: HistoryResult = .{ .applied = .{ .applied = 0, .skipped = 0, .notes = 0 } };
        const capture_text = try s.getSetting("capture_text");
        defer if (capture_text) |value| s.allocator.free(value);
        const time_only = if (capture_text) |value| std.mem.eql(u8, value, "time") else false;
        for (intervals, 0..) |item, index| {
            if (try s.captureEventSeen(source, item.event)) {
                result.applied.skipped += 1;
                continue;
            }
            const task = (try resolve(s, allocator, item.subject, now_ms)) orelse return .{ .invalid_subject = index };
            const role: Role = if (attended) .focus else .parallel;
            s.checkFree(&.{}, task, role, item.start_ms, item.end_ms) catch |err| switch (err) {
                error.Overlap => return .{ .conflict = .{ .index = index, .reason = "overlap" } },
                else => return err,
            };
            if (try s.historyPosted(task, item.start_ms, item.end_ms)) return .{ .conflict = .{ .index = index, .reason = "posted" } };
            // Backfilled spans take the task's project, like live capture.
            var inserted = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by,project_id) VALUES(?1,?2,?3,?4,?5,'stop',?6) RETURNING id");
            defer inserted.finalize();
            try inserted.bindI64(1, task);
            try inserted.bindText(2, sqlText(role));
            try inserted.bindI64(3, item.start_ms);
            try inserted.bindI64(4, item.end_ms);
            try inserted.bindText(5, if (attended) "switch" else "parallel");
            if (try s.taskProject(task)) |project| try inserted.bindI64(6, project) else try inserted.bindNull(6);
            if (try inserted.step() != .row) return error.Sqlite;
            const interval_id = inserted.columnI64(0);
            if (try inserted.step() != .done) return error.Sqlite;
            result.applied.applied += 1;
            try s.historyEvent(source, run, item.event, item.start_ms);
            for (item.notes) |note| {
                if (time_only) continue;
                if (try s.captureEventSeen(source, note.event)) continue;
                var stmt = try s.db.prepare("INSERT INTO notes(interval_id,at_ms,text) VALUES(?1,?2,?3)");
                defer stmt.finalize();
                try stmt.bindI64(1, interval_id);
                try stmt.bindI64(2, note.at_ms);
                try stmt.bindText(3, note.text);
                _ = try stmt.step();
                try s.historyEvent(source, run, note.event, note.at_ms);
                result.applied.notes += 1;
            }
            try s.markEdited(item.start_ms, item.end_ms, now_ms);
        }
        try tx.commit();
        return result;
    }

    fn historyEvent(s: *Store, source: []const u8, run: []const u8, event: []const u8, at_ms: i64) !void {
        var stmt = try s.db.prepare("INSERT INTO capture_events(source,event,run,kind,at_ms) VALUES(?1,?2,?3,'history',?4)");
        defer stmt.finalize();
        try stmt.bindText(1, source);
        try stmt.bindText(2, event);
        try stmt.bindText(3, run);
        try stmt.bindI64(4, at_ms);
        _ = try stmt.step();
    }

    fn historyPosted(s: *Store, task: i64, start: i64, end: i64) !bool {
        const id = try s.reportingZone();
        defer if (id) |v| s.allocator.free(v);
        const z = try zone.Zone.load(id orelse "UTC");
        var at = start;
        var days: u32 = 0;
        while (days < 400) : (days += 1) {
            const d = z.dateOf(at) catch return error.InvalidTime;
            var buffer: [10]u8 = undefined;
            const day = try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
            var stmt = try s.db.prepare("SELECT 1 FROM postings WHERE task_id=?1 AND day=?2 AND state IN ('confirmed','sending','unknown') LIMIT 1");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            try stmt.bindText(2, day);
            if (try stmt.step() == .row) return true;
            const bounds = z.dayBounds(d.year, d.month, d.day) catch return error.InvalidTime;
            if (bounds.end_ms > end) break;
            at = bounds.end_ms;
        }
        return false;
    }

    fn captureNote(s: *Store, c: Capture, at: i64, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        const run = try s.captureRun(c.source, c.run);
        const task = run.task orelse return;
        const interval = try s.openIntervalOf(task) orelse return;
        var stmt = try s.db.prepare("INSERT INTO notes(interval_id,at_ms,text,source) VALUES(?1,max(?2,(SELECT start_ms FROM intervals WHERE id=?1)),?3,?4)");
        defer stmt.finalize();
        try stmt.bindI64(1, interval);
        try stmt.bindI64(2, at);
        try stmt.bindText(3, trimmed);
        // A report along the way (busy) is plain, as if written by hand.
        switch (c.kind) {
            .prompt => try stmt.bindText(4, "prompt"),
            .stop => try stmt.bindText(4, "outcome"),
            else => try stmt.bindNull(4),
        }
        _ = try stmt.step();
    }

    /// The run works on `task` from now on; a working run moves its time there.
    /// `engage_now` is false for a prompt, which engages in its own role next.
    fn moveRun(s: *Store, c: Capture, run: CaptureRun, task: i64, project: ?i64, at: i64, engage_now: bool) !void {
        try s.setRun(c, task, run.working, run.role, run.lease_until);
        try s.setIdle(c, run.idle);
        if (run.working or run.idle != null) {
            try s.releaseTask(c, run.task, at, .@"switch");
            if (engage_now) try s.setRole(c, try s.engage(c, task, if (try s.isHoldingSource(c.source)) .focus else run.role orelse .parallel, project, at));
        }
    }

    /// The role the run's task actually got: a prompt that could not take
    /// the focus works in parallel, and must not take it later unprompted.
    fn setRole(s: *Store, c: Capture, role: Role) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET role=?3 WHERE source=?1 AND run=?2 AND task_id IS NOT NULL");
        defer stmt.finalize();
        try stmt.bindText(1, c.source);
        try stmt.bindText(2, c.run);
        try stmt.bindText(3, @tagName(role));
        _ = try stmt.step();
    }

    /// `idle`: when the run's turn ended, while its task is kept open.
    const CaptureRun = struct { task: ?i64, working: bool, role: ?Role, lease_until: ?i64, idle: ?i64, project: ?i64, provisional_title: bool };

    /// Whether this event was applied already, so a retry changes nothing,
    /// not even by creating the task it names.
    pub fn captureEventSeen(s: *Store, source: []const u8, event: []const u8) Error!bool {
        var stmt = try s.db.prepare("SELECT 1 FROM capture_events WHERE source=?1 AND event=?2");
        defer stmt.finalize();
        try stmt.bindText(1, source);
        try stmt.bindText(2, event);
        return try stmt.step() == .row;
    }

    /// Whether a captured run already has a task, so its default is not needed.
    pub fn captureRunHasTask(s: *Store, source: []const u8, run: []const u8) Error!bool {
        const r = s.captureRun(source, run) catch |err| switch (err) {
            error.InvalidState => return false,
            else => return err,
        };
        return r.task != null;
    }

    fn captureRun(s: *Store, source: []const u8, run: []const u8) !CaptureRun {
        var stmt = try s.db.prepare("SELECT task_id,working,role,lease_until_ms,idle_since_ms,project_id,provisional_title FROM capture_runs WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, source);
        try stmt.bindText(2, run);
        if (try stmt.step() != .row) return error.InvalidState;
        return .{
            .task = if (stmt.columnIsNull(0)) null else stmt.columnI64(0),
            .working = stmt.columnI64(1) == 1,
            .role = if (stmt.columnText(2)) |r| std.meta.stringToEnum(Role, r) else null,
            .lease_until = if (stmt.columnIsNull(3)) null else stmt.columnI64(3),
            .idle = if (stmt.columnIsNull(4)) null else stmt.columnI64(4),
            .project = if (stmt.columnIsNull(5)) null else stmt.columnI64(5),
            .provisional_title = stmt.columnI64(6) != 0,
        };
    }

    fn savedCaptureKey(s: *Store, source: []const u8, run: []const u8) !?[]const u8 {
        var stmt = try s.db.prepare("SELECT project_key FROM capture_runs WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, source);
        try stmt.bindText(2, run);
        if (try stmt.step() != .row) return null;
        return if (stmt.columnText(0)) |key| try s.allocator.dupe(u8, key) else null;
    }

    fn setRunProjectKey(s: *Store, c: Capture, key: ?[]const u8) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET project_key=?3 WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, c.source);
        try stmt.bindText(2, c.run);
        try stmt.bindOptionalText(3, key);
        _ = try stmt.step();
    }

    fn setRunProject(s: *Store, c: Capture, project: ?i64) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET project_id=?3 WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, c.source);
        try stmt.bindText(2, c.run);
        if (project) |id| try stmt.bindI64(3, id) else try stmt.bindNull(3);
        _ = try stmt.step();
    }

    fn setRun(s: *Store, c: Capture, task: ?i64, working: bool, role: ?Role, lease_until: ?i64) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET provisional_title=CASE WHEN task_id IS ?3 THEN provisional_title ELSE 0 END,task_id=?3,working=?4,role=?5,lease_until_ms=?6,idle_since_ms=NULL WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, c.source);
        try stmt.bindText(2, c.run);
        if (task) |t| try stmt.bindI64(3, t) else try stmt.bindNull(3);
        try stmt.bindI64(4, @intFromBool(working));
        try stmt.bindOptionalText(5, if (role) |r| @tagName(r) else null);
        if (lease_until) |l| try stmt.bindI64(6, l) else try stmt.bindNull(6);
        _ = try stmt.step();
    }

    fn setProvisionalTitle(s: *Store, c: Capture, value: bool) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET provisional_title=?3 WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, c.source);
        try stmt.bindText(2, c.run);
        try stmt.bindI64(3, @intFromBool(value));
        _ = try stmt.step();
    }

    fn setIdle(s: *Store, c: Capture, since: ?i64) !void {
        var stmt = try s.db.prepare("UPDATE capture_runs SET idle_since_ms=?3 WHERE source=?1 AND run=?2");
        defer stmt.finalize();
        try stmt.bindText(1, c.source);
        try stmt.bindText(2, c.run);
        if (since) |v| try stmt.bindI64(3, v) else try stmt.bindNull(3);
        _ = try stmt.step();
    }

    fn isHoldingSource(s: *Store, source: []const u8) !bool {
        const list = try s.getSetting("capture_hold_sources") orelse return false;
        defer s.allocator.free(list);
        return holdsFocus(list, source);
    }

    /// Whether an active run of a holding source (capture_hold_sources)
    /// has the focus on another task, so this run's prompt leaves it there.
    fn focusHeld(s: *Store, c: Capture, task: i64) !bool {
        const list = try s.getSetting("capture_hold_sources") orelse return false;
        defer s.allocator.free(list);
        if (holdsFocus(list, c.source)) return false;
        var stmt = try s.db.prepare("SELECT r.source FROM capture_runs r JOIN intervals i ON i.task_id=r.task_id AND i.end_ms IS NULL AND i.role='focus' WHERE (r.working=1 OR r.idle_since_ms IS NOT NULL) AND r.task_id<>?1");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        while (try stmt.step() == .row) if (holdsFocus(list, stmt.columnText(0).?)) return true;
        return false;
    }

    fn holdsFocus(list: []const u8, source: []const u8) bool {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |item| if (std.mem.eql(u8, std.mem.trim(u8, item, " "), source)) return true;
        return false;
    }

    fn openIntervalOf(s: *Store, task: i64) !?i64 {
        var stmt = try s.db.prepare("SELECT id FROM intervals WHERE task_id=?1 AND end_ms IS NULL");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        return if (try stmt.step() == .row) stmt.columnI64(0) else null;
    }

    /// Opens the task in this role. Taking the focus moves the task that
    /// had it to parallel when another run still works on it.
    fn engage(s: *Store, c: Capture, task: ?i64, role: Role, project: ?i64, at: i64) !Role {
        const t = task orelse return role;
        const holding = try s.isHoldingSource(c.source);
        var open_role: ?Role = null;
        var open_id: ?i64 = null;
        var open_project: ?i64 = null;
        var open_captured = false;
        {
            var stmt = try s.db.prepare("SELECT id,role,project_id,captured FROM intervals WHERE task_id=?1 AND end_ms IS NULL");
            defer stmt.finalize();
            try stmt.bindI64(1, t);
            if (try stmt.step() == .row) {
                open_id = stmt.columnI64(0);
                open_role = std.meta.stringToEnum(Role, stmt.columnText(1).?);
                open_project = if (stmt.columnIsNull(2)) null else stmt.columnI64(2);
                open_captured = stmt.columnI64(3) != 0;
            }
        }
        if (holding and open_role == .parallel) {
            try s.promoteFocusInterval(open_id.?, at);
            if (open_captured and open_project != project)
                try s.splitCapturedProject(open_id.?, t, .focus, project, at);
            return .focus;
        }
        var focus_task: ?i64 = null;
        var focus_start: i64 = 0;
        {
            var stmt = try s.db.prepare("SELECT task_id,start_ms FROM intervals WHERE end_ms IS NULL AND role='focus'");
            defer stmt.finalize();
            if (try stmt.step() == .row) {
                focus_task = stmt.columnI64(0);
                focus_start = stmt.columnI64(1);
            }
        }
        if (!holding and role == .focus and focus_task == null and open_role == .parallel) {
            // The former focus may have closed when its stopped run's grace
            // expired. Its prompts still delimit a stretch already in progress.
            var stmt = try s.db.prepare("SELECT task_id,start_ms FROM intervals WHERE role='focus' AND task_id<>?1 AND end_ms IS NOT NULL AND end_ms<=?2 ORDER BY end_ms DESC,id DESC LIMIT 1");
            defer stmt.finalize();
            try stmt.bindI64(1, t);
            try stmt.bindI64(2, at);
            if (try stmt.step() == .row)
                if (try s.sustainFocus(t, stmt.columnI64(0), stmt.columnI64(1), at)) return .focus;
        }
        const held = if (holding) false else try s.focusHeld(c, t);
        if (!holding and (role == .parallel or held or (focus_task != null and focus_task.? != t))) {
            if (open_role == null) try s.continueOrOpen(t, .parallel, project, at)
            else if (open_role == .parallel and open_captured and open_project != project)
                try s.splitCapturedProject(open_id.?, t, .parallel, project, at);
            if (role == .focus and !held and focus_task != null and focus_task.? != t)
                if (try s.sustainFocus(t, focus_task.?, focus_start, at)) return .focus;
            return .parallel;
        }
        if (open_role == .focus) {
            if (open_captured and open_project != project)
                try s.splitCapturedProject(open_id.?, t, .focus, project, at);
            return .focus;
        }
        var previous: ?i64 = null;
        var previous_project: ?i64 = null;
        {
            var stmt = try s.db.prepare("SELECT task_id,project_id FROM intervals WHERE end_ms IS NULL AND role='focus'");
            defer stmt.finalize();
            if (try stmt.step() == .row) {
                previous = stmt.columnI64(0);
                previous_project = if (stmt.columnIsNull(1)) null else stmt.columnI64(1);
            }
        }
        // A captured focus whose runs all sit in their grace ends where the
        // last turn ended: the grace is not attention once another task takes over.
        if (previous) |p| if (!try s.otherRunWorking(c, p)) {
            var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,(SELECT max(idle_since_ms) FROM capture_runs WHERE task_id=?1),coalesce((SELECT max(r.ended_ms) FROM capture_runs r WHERE r.task_id=?1 AND r.ended_ms>=intervals.start_ms),0)),closed_by='switch' WHERE task_id=?1 AND end_ms IS NULL AND role='focus' AND captured=1 AND EXISTS (SELECT 1 FROM capture_runs WHERE task_id=?1 AND idle_since_ms IS NOT NULL)");
            defer stmt.finalize();
            try stmt.bindI64(1, p);
            _ = try stmt.step();
        };
        try s.closeFocus(.@"switch", at);
        if (open_role == .parallel) {
            const own = (try s.openIntervalOf(t)).?;
            var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by='switch' WHERE id=?2");
            defer stmt.finalize();
            try stmt.bindI64(1, at);
            try stmt.bindI64(2, own);
            _ = try stmt.step();
        }
        try s.continueOrOpen(t, .focus, if (open_role != null and !open_captured) open_project else project, at);
        try s.db.exec("DELETE FROM saved_set");
        if (previous) |p| if (try s.otherRunWorks(c, p)) {
            if (try s.otherRunWorking(c, p)) try s.continueOrOpen(p, .parallel, previous_project, at);
            var stmt = try s.db.prepare("UPDATE capture_runs SET role='parallel' WHERE (working=1 OR idle_since_ms IS NOT NULL) AND task_id=?1");
            defer stmt.finalize();
            try stmt.bindI64(1, p);
            _ = try stmt.step();
        };
        return .focus;
    }

    /// Promote the current parallel stretch once its attended prompts span
    /// ten minutes without a prompt to the task holding focus.
    fn sustainFocus(s: *Store, task: i64, focused: i64, focus_start: i64, at: i64) !bool {
        var latest_focus_prompt: ?i64 = null;
        {
            var stmt = try s.db.prepare("SELECT max(e.at_ms) FROM capture_events e JOIN capture_runs r ON r.source=e.source AND r.run=e.run JOIN intervals i ON i.task_id=r.task_id AND e.at_ms>=i.start_ms AND e.at_ms<coalesce(i.end_ms,?3+1) WHERE e.kind='prompt' AND r.attended=1 AND r.task_id=?1 AND e.at_ms>=?2 AND e.at_ms<=?3");
            defer stmt.finalize();
            try stmt.bindI64(1, focused);
            try stmt.bindI64(2, focus_start);
            try stmt.bindI64(3, at);
            if (try stmt.step() == .row and !stmt.columnIsNull(0)) latest_focus_prompt = stmt.columnI64(0);
        }
        var latest_hold_event: ?i64 = null;
        if (try s.getSetting("capture_hold_sources")) |list| {
            defer s.allocator.free(list);
            var stmt = try s.db.prepare("SELECT e.at_ms,r.source FROM capture_events e JOIN capture_runs r ON r.source=e.source AND r.run=e.run JOIN intervals i ON i.task_id=r.task_id AND e.at_ms>=i.start_ms AND e.at_ms<=coalesce(i.end_ms,?3) WHERE r.task_id=?1 AND e.at_ms>=?2 AND e.at_ms<=?3 ORDER BY e.at_ms DESC");
            defer stmt.finalize();
            try stmt.bindI64(1, focused);
            try stmt.bindI64(2, focus_start);
            try stmt.bindI64(3, at);
            while (try stmt.step() == .row) {
                if (holdsFocus(list, stmt.columnText(1).?)) {
                    latest_hold_event = stmt.columnI64(0);
                    break;
                }
            }
        }
        var stretch: i64 = undefined;
        {
            var stmt = try s.db.prepare("SELECT min(e.at_ms) FROM capture_events e JOIN capture_runs r ON r.source=e.source AND r.run=e.run JOIN intervals i ON i.task_id=r.task_id AND e.at_ms>=i.start_ms AND e.at_ms<coalesce(i.end_ms,?5+1) WHERE e.kind='prompt' AND r.attended=1 AND r.task_id=?1 AND e.at_ms>=?2 AND (?3 IS NULL OR e.at_ms>?3) AND (?4 IS NULL OR e.at_ms>?4) AND e.at_ms<=?5");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            try stmt.bindI64(2, focus_start);
            if (latest_focus_prompt) |v| try stmt.bindI64(3, v) else try stmt.bindNull(3);
            if (latest_hold_event) |v| try stmt.bindI64(4, v) else try stmt.bindNull(4);
            try stmt.bindI64(5, at);
            if (try stmt.step() != .row or stmt.columnIsNull(0)) return false;
            stretch = stmt.columnI64(0);
        }
        if (at - stretch < focus_sustain_ms) return false;
        var pieces: std.ArrayList(i64) = .empty;
        defer pieces.deinit(s.allocator);
        {
            var stmt = try s.db.prepare("SELECT id FROM intervals WHERE task_id=?1 AND role='parallel' AND start_ms<=?2 AND coalesce(end_ms,?3)>?4 AND coalesce(end_ms,?3)>start_ms ORDER BY start_ms,id");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            try stmt.bindI64(2, at);
            try stmt.bindI64(3, at + 1);
            try stmt.bindI64(4, stretch);
            while (try stmt.step() == .row) try pieces.append(s.allocator, stmt.columnI64(0));
        }
        if (pieces.items.len == 0) return false;
        // Check every row before splitting any of them. Project splits share
        // a span id even before posting; a lone marker remains protected.
        for (pieces.items) |id| {
            const row = try s.intervalRow(id);
            defer s.freeRow(row);
            if (try s.isPostedInterval(id, row, at)) return false;
            var overlaps = try s.db.prepare("SELECT id FROM intervals WHERE role='focus' AND start_ms<?1 AND coalesce(end_ms,?3)>?2");
            defer overlaps.finalize();
            try overlaps.bindI64(1, row.end_ms orelse at + 1);
            try overlaps.bindI64(2, @max(stretch, row.start_ms));
            try overlaps.bindI64(3, at + 1);
            while (try overlaps.step() == .row) {
                const other_id = overlaps.columnI64(0);
                const other = try s.intervalRow(other_id);
                defer s.freeRow(other);
                if (try s.isPostedInterval(other_id, other, at)) return false;
            }
        }
        for (pieces.items, 0..) |id, index| {
            var promote_id = id;
            if (index == 0) {
                const row = try s.intervalRow(id);
                defer s.freeRow(row);
                if (row.start_ms < stretch) {
                    var close = try s.db.prepare("UPDATE intervals SET end_ms=?1,closed_by='switch' WHERE id=?2");
                    defer close.finalize();
                    try close.bindI64(1, stretch);
                    try close.bindI64(2, id);
                    _ = try close.step();
                    promote_id = try s.insertPiece(task, .parallel, stretch, row.end_ms, row.closed_by orelse "switch", row.project, row.posting_span, row.captured);
                    try s.moveNotes(id, promote_id, stretch, null);
                }
            }
            try s.promoteFocusInterval(promote_id, at);
        }
        return true;
    }

    fn isPostedInterval(s: *Store, id: i64, row: Row, at: i64) !bool {
        var stmt = try s.db.prepare("SELECT 1 FROM postings WHERE task_id=?1 AND state!='cancelled' AND (covered_start_ms IS NULL OR (covered_start_ms<?2 AND covered_end_ms>?3)) LIMIT 1");
        defer stmt.finalize();
        try stmt.bindI64(1, row.task);
        try stmt.bindI64(2, row.end_ms orelse at + 1);
        try stmt.bindI64(3, row.start_ms);
        if (try stmt.step() == .row) return true;
        const span = row.posting_span orelse return false;
        var siblings = try s.db.prepare("SELECT 1 FROM intervals WHERE id<>?1 AND posting_span_id=?2 LIMIT 1");
        defer siblings.finalize();
        try siblings.bindI64(1, id);
        try siblings.bindI64(2, span);
        return try siblings.step() != .row;
    }

    fn splitCapturedProject(s: *Store, old_id: i64, task: i64, role: Role, project: ?i64, at: i64) !void {
        var old = try s.db.prepare("SELECT posting_span_id FROM intervals WHERE id=?1");
        defer old.finalize();
        try old.bindI64(1, old_id);
        if (try old.step() != .row) return error.UnknownInterval;
        const span = if (old.columnIsNull(0)) old_id else old.columnI64(0);
        var close = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by='switch',posting_span_id=?2 WHERE id=?3");
        defer close.finalize();
        try close.bindI64(1, at);
        try close.bindI64(2, span);
        try close.bindI64(3, old_id);
        _ = try close.step();
        try s.openCaptured(task, role, project, at);
        var mark = try s.db.prepare("UPDATE intervals SET posting_span_id=?1 WHERE task_id=?2 AND end_ms IS NULL");
        defer mark.finalize();
        try mark.bindI64(1, span);
        try mark.bindI64(2, task);
        _ = try mark.step();
    }

    /// Carries on the task's last interval in this role when it ended
    /// within the grace (a turn's end, a daemon restart, a short focus
    /// handoff), so a conversation stays one row. Opens a new one when the
    /// task ran since, a lunch began in the gap, or, for the focus, another
    /// focus took the gap.
    fn continueOrOpen(s: *Store, task: i64, role: Role, project: ?i64, at: i64) !void {
        var id: i64 = 0;
        var end: i64 = 0;
        var old_project: ?i64 = null;
        var span: ?i64 = null;
        {
            var stmt = try s.db.prepare("SELECT id,end_ms,project_id,posting_span_id FROM intervals WHERE task_id=?1 AND role=?2 AND captured=1 AND end_ms IS NOT NULL AND end_ms<=?3 AND end_ms>=?4 ORDER BY end_ms DESC LIMIT 1");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            try stmt.bindText(2, @tagName(role));
            try stmt.bindI64(3, at);
            try stmt.bindI64(4, at - capture_idle_ms);
            if (try stmt.step() != .row) return s.openCaptured(task, role, project, at);
            old_project = if (stmt.columnIsNull(2)) null else stmt.columnI64(2);
            id = stmt.columnI64(0);
            end = stmt.columnI64(1);
            span = if (stmt.columnIsNull(3)) id else stmt.columnI64(3);
        }
        var stmt = try s.db.prepare("SELECT 1 FROM intervals WHERE id<>?1 AND ((task_id=?2 AND coalesce(end_ms,?4)>?3) OR (?5='focus' AND role='focus' AND start_ms<?4 AND coalesce(end_ms,?4)>?3)) UNION ALL SELECT 1 FROM lunches WHERE out_ms>=?3 AND out_ms<=?4");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        try stmt.bindI64(2, task);
        try stmt.bindI64(3, end);
        try stmt.bindI64(4, at);
        try stmt.bindText(5, @tagName(role));
        if (try stmt.step() == .row) return s.openCaptured(task, role, project, at);
        if (old_project != project) {
            var extend = try s.db.prepare("UPDATE intervals SET end_ms=?1,posting_span_id=?2 WHERE id=?3");
            defer extend.finalize();
            try extend.bindI64(1, at);
            try extend.bindI64(2, span.?);
            try extend.bindI64(3, id);
            _ = try extend.step();
            try s.openCaptured(task, role, project, at);
            var mark = try s.db.prepare("UPDATE intervals SET posting_span_id=?1 WHERE task_id=?2 AND end_ms IS NULL");
            defer mark.finalize();
            try mark.bindI64(1, span.?);
            try mark.bindI64(2, task);
            _ = try mark.step();
            return;
        }
        var reopen = try s.db.prepare("UPDATE intervals SET end_ms=NULL,closed_by=NULL WHERE id=?1");
        defer reopen.finalize();
        try reopen.bindI64(1, id);
        _ = try reopen.step();
    }

    fn openCaptured(s: *Store, task: i64, role: Role, project: ?i64, at: i64) !void {
        const id = try s.openInterval(task, role, if (role == .focus) .@"switch" else .parallel, null, project, at);
        var stmt = try s.db.prepare("UPDATE intervals SET captured=1 WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        _ = try stmt.step();
    }

    fn otherRunWorks(s: *Store, c: Capture, task: i64) !bool {
        var stmt = try s.db.prepare("SELECT 1 FROM capture_runs WHERE (working=1 OR idle_since_ms IS NOT NULL) AND task_id=?1 AND NOT (source=?2 AND run=?3)");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, c.source);
        try stmt.bindText(3, c.run);
        return try stmt.step() == .row;
    }

    /// Whether another run is mid-turn on the task (not just in its grace).
    fn otherRunWorking(s: *Store, c: Capture, task: i64) !bool {
        var stmt = try s.db.prepare("SELECT 1 FROM capture_runs WHERE working=1 AND task_id=?1 AND NOT (source=?2 AND run=?3)");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, c.source);
        try stmt.bindText(3, c.run);
        return try stmt.step() == .row;
    }

    /// Closes the task's captured interval unless another run still works on
    /// it, at the latest point any run left it: the run that leaves last never
    /// cuts off time an earlier one worked. An interval opened by hand is the
    /// user's to close.
    fn releaseTask(s: *Store, c: Capture, task: ?i64, at: i64, reason: ClosedBy) !void {
        const t = task orelse return;
        if (try s.otherRunWorks(c, t)) return;
        var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1,coalesce((SELECT max(r.ended_ms) FROM capture_runs r WHERE r.task_id=intervals.task_id AND r.ended_ms>=intervals.start_ms),0)),closed_by=?2 WHERE task_id=?3 AND end_ms IS NULL AND captured=1");
        defer stmt.finalize();
        try stmt.bindI64(1, at);
        try stmt.bindText(2, sqlText(reason));
        try stmt.bindI64(3, t);
        _ = try stmt.step();
    }

    /// A working run that sent nothing for a lease stops where its lease
    /// ran out: a session that crashed or lost its end event. An idle run
    /// whose grace ran out stops where its turn ended.
    fn expireRuns(s: *Store, at: i64) !void {
        var source_buf: [256]u8 = undefined;
        var run_buf: [256]u8 = undefined;
        while (true) {
            var c: Capture = .{ .source = "", .run = "", .kind = .stop };
            var task: ?i64 = null;
            var until: i64 = 0;
            var idle = false;
            {
                var stmt = try s.db.prepare("SELECT source,run,task_id,lease_until_ms,idle_since_ms FROM capture_runs WHERE (working=1 OR idle_since_ms IS NOT NULL) AND lease_until_ms<?1 LIMIT 1");
                defer stmt.finalize();
                try stmt.bindI64(1, at);
                if (try stmt.step() != .row) return;
                const source = stmt.columnText(0).?;
                const run = stmt.columnText(1).?;
                if (source.len > source_buf.len or run.len > run_buf.len) return error.TooLarge;
                @memcpy(source_buf[0..source.len], source);
                @memcpy(run_buf[0..run.len], run);
                c.source = source_buf[0..source.len];
                c.run = run_buf[0..run.len];
                task = if (stmt.columnIsNull(2)) null else stmt.columnI64(2);
                idle = !stmt.columnIsNull(4);
                until = if (idle) stmt.columnI64(4) else stmt.columnI64(3);
            }
            try s.setRun(c, task, false, null, null);
            {
                var stmt = try s.db.prepare("UPDATE capture_runs SET ended_ms=?3 WHERE source=?1 AND run=?2");
                defer stmt.finalize();
                try stmt.bindText(1, c.source);
                try stmt.bindText(2, c.run);
                try stmt.bindI64(3, until);
                _ = try stmt.step();
            }
            try s.releaseTask(c, task, until, if (idle) .stop else .recovered);
        }
    }

    pub fn pause(s: *Store, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (try s.hasOpen()) _ = try s.pauseOpen(now_ms);
        try tx.commit();
    }

    /// Caller owns the transaction and checked that something is open.
    fn pauseOpen(s: *Store, now_ms: i64) !i64 {
        const at = try s.intervalTime(now_ms);
        try s.db.exec("DELETE FROM saved_set");
        try s.db.exec("INSERT INTO saved_set(task_id,role,project_id) SELECT task_id,role,project_id FROM intervals WHERE end_ms IS NULL");
        var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by='pause' WHERE end_ms IS NULL");
        defer stmt.finalize();
        try stmt.bindI64(1, at);
        _ = try stmt.step();
        return at;
    }

    pub fn @"resume"(s: *Store, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (try s.hasOpen()) return error.SomethingOpen;
        const at = try s.intervalTime(now_ms);
        var saved = try s.db.prepare("SELECT task_id,role,project_id FROM saved_set ORDER BY task_id");
        defer saved.finalize();
        var opened = false;
        while (try saved.step() == .row) {
            const role = std.meta.stringToEnum(Role, saved.columnText(1).?) orelse return error.InvalidState;
            _ = try s.openInterval(saved.columnI64(0), role, .@"resume", null, if (saved.columnIsNull(2)) null else saved.columnI64(2), at);
            opened = true;
        }
        if (opened) {
            try s.db.exec("DELETE FROM saved_set");
            try s.heartbeat(at);
        }
        try tx.commit();
    }

    pub fn addNote(s: *Store, target: ?i64, text: []const u8, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (text.len == 0) return error.EmptyText;
        const interval_id = blk: {
            const sql = if (target == null) "SELECT id FROM intervals WHERE end_ms IS NULL AND role='focus'" else "SELECT id FROM intervals WHERE end_ms IS NULL AND task_id=?1";
            var stmt = try s.db.prepare(sql);
            defer stmt.finalize();
            if (target) |task| try stmt.bindI64(1, task);
            if (try stmt.step() == .done) return if (target == null) error.NoFocus else error.NoOpenInterval;
            break :blk stmt.columnI64(0);
        };
        var stmt = try s.db.prepare("INSERT INTO notes(interval_id,at_ms,text) VALUES(?1,?2,?3) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, interval_id);
        try stmt.bindI64(2, now_ms);
        try stmt.bindText(3, text);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        try tx.commit();
        return id;
    }

    pub fn setIntervalText(s: *Store, interval: i64, text: ?[]const u8, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        var stmt = try s.db.prepare("UPDATE intervals SET text=?1 WHERE id=?2");
        defer stmt.finalize();
        try stmt.bindOptionalText(1, text);
        try stmt.bindI64(2, interval);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.NoOpenInterval;
        try tx.commit();
    }

    pub fn isBlocked(s: *Store, day: []const u8, instance: []const u8, ref: []const u8) Error!bool {
        var stmt = try s.db.prepare("SELECT 1 FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state IN ('sending','unknown') LIMIT 1");
        defer stmt.finalize();
        try stmt.bindText(1, day);
        try stmt.bindText(2, instance);
        try stmt.bindText(3, ref);
        return try stmt.step() == .row;
    }

    pub fn startPosting(s: *Store, day: []const u8, task: i64, instance: []const u8, ref: []const u8, amount_text: []const u8, amount_micro: i64, now_ms: i64, covered: ?@import("sessions.zig").Span) Error!i64 {
        return s.startPostingChecked(day, task, instance, ref, amount_text, amount_micro, now_ms, covered, null);
    }

    pub fn startPostingChecked(s: *Store, day: []const u8, task: i64, instance: []const u8, ref: []const u8, amount_text: []const u8, amount_micro: i64, now_ms: i64, covered: ?@import("sessions.zig").Span, fingerprint: ?[]const u8) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (try s.isBlocked(day, instance, ref)) return error.PostingBlocked;
        if (fingerprint) |expected| {
            var check_fingerprint = try s.db.prepare("SELECT coalesce(sum(CASE WHEN state='confirmed' THEN 1 ELSE 0 END),0),coalesce(sum(CASE WHEN state='confirmed' THEN amount_micro ELSE 0 END),0),coalesce(max(CASE WHEN state='confirmed' THEN id END),0) FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state IN ('confirmed','sending','unknown')");
            defer check_fingerprint.finalize();
            try check_fingerprint.bindText(1, day);
            try check_fingerprint.bindText(2, instance);
            try check_fingerprint.bindText(3, ref);
            if (try check_fingerprint.step() != .row) return error.Sqlite;
            var buffer: [96]u8 = undefined;
            const current = std.fmt.bufPrint(&buffer, "{d}:{d}:{d}", .{ check_fingerprint.columnI64(0), check_fingerprint.columnI64(1), check_fingerprint.columnI64(2) }) catch return error.PostingBlocked;
            if (!std.mem.eql(u8, current, expected)) return error.PostingBlocked;
        }
        if (covered) |span| {
            if (span.start_ms >= span.end_ms) return error.PostingBlocked;
            var check = try s.db.prepare("SELECT 1 FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state!='cancelled' AND (covered_start_ms IS NULL OR (covered_start_ms<?5 AND covered_end_ms>?4)) LIMIT 1");
            defer check.finalize();
            try check.bindText(1, day);
            try check.bindText(2, instance);
            try check.bindText(3, ref);
            try check.bindI64(4, span.start_ms);
            try check.bindI64(5, span.end_ms);
            if (try check.step() == .row) return error.PostingBlocked;
        }
        var stmt = try s.db.prepare("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms,covered_start_ms,covered_end_ms) VALUES(?1,?2,?3,?4,'sending',?5,?6,?7,?8,?9) RETURNING id");
        defer stmt.finalize();
        try stmt.bindText(1, day);
        try stmt.bindI64(2, task);
        try stmt.bindText(3, instance);
        try stmt.bindText(4, ref);
        try stmt.bindText(5, amount_text);
        try stmt.bindI64(6, amount_micro);
        try stmt.bindI64(7, now_ms);
        if (covered) |span| {
            try stmt.bindI64(8, span.start_ms);
            try stmt.bindI64(9, span.end_ms);
        } else {
            try stmt.bindNull(8);
            try stmt.bindNull(9);
        }
        if ((stmt.step() catch |err| {
            if (s.db.isConstraint()) return error.PostingBlocked;
            return err;
        }) != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        try tx.commit();
        return id;
    }

    pub fn confirmPosting(s: *Store, id: i64, accepted_text: ?[]const u8, accepted_micro: ?i64, provider_data: ?[]const u8, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        var stmt = try s.db.prepare("UPDATE postings SET state='confirmed',amount_text=COALESCE(?1,amount_text),amount_micro=COALESCE(?2,amount_micro),provider_data=?3,confirmed_ms=?4 WHERE id=?5 AND state IN ('sending','unknown')");
        defer stmt.finalize();
        try stmt.bindOptionalText(1, accepted_text);
        if (accepted_micro) |micro| try stmt.bindI64(2, micro) else try stmt.bindNull(2);
        try stmt.bindOptionalText(3, provider_data);
        try stmt.bindI64(4, now_ms);
        try stmt.bindI64(5, id);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.InvalidState;
        try tx.commit();
    }

    /// A send that failed with a known outcome applied nothing: it is cancelled.
    pub fn postingFailed(s: *Store, id: i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        var stmt = try s.db.prepare("UPDATE postings SET state='cancelled' WHERE id=?1 AND state='sending'");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.InvalidState;
        try tx.commit();
    }

    pub fn markUnknown(s: *Store, id: i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        var stmt = try s.db.prepare("UPDATE postings SET state='unknown' WHERE id=?1 AND state='sending'");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.InvalidState;
        try tx.commit();
    }

    pub fn resolveUnknown(s: *Store, id: i64, posted: bool, provider_data: ?[]const u8, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        var stmt = try s.db.prepare("UPDATE postings SET state=?1,provider_data=?2,confirmed_ms=?3 WHERE id=?4 AND state='unknown'");
        defer stmt.finalize();
        try stmt.bindText(1, sqlText(@as(PostingState, if (posted) .confirmed else .cancelled)));
        try stmt.bindOptionalText(2, provider_data);
        if (posted) try stmt.bindI64(3, now_ms) else try stmt.bindNull(3);
        try stmt.bindI64(4, id);
        _ = try stmt.step();
        if (s.db.changes() == 0) return error.InvalidState;
        try tx.commit();
    }

    // ------------------------------------------------------------ history

    pub const Span = struct { start_ms: i64, end_ms: ?i64 };

    const Row = struct { task: i64, role: Role, start_ms: i64, end_ms: ?i64, text: ?[]u8, closed_by: ?[]u8, project: ?i64, posting_span: ?i64, captured: bool };

    fn intervalRow(s: *Store, id: i64) !Row {
        var stmt = try s.db.prepare("SELECT task_id,role,start_ms,end_ms,text,closed_by,project_id,posting_span_id,captured FROM intervals WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        if (try stmt.step() == .done) return error.UnknownInterval;
        const text = if (stmt.columnText(4)) |t| try s.allocator.dupe(u8, t) else null;
        errdefer if (text) |t| s.allocator.free(t);
        return .{
            .task = stmt.columnI64(0),
            .role = std.meta.stringToEnum(Role, stmt.columnText(1).?) orelse return error.InvalidState,
            .start_ms = stmt.columnI64(2),
            .end_ms = if (stmt.columnIsNull(3)) null else stmt.columnI64(3),
            .text = text,
            .closed_by = if (stmt.columnText(5)) |c| try s.allocator.dupe(u8, c) else null,
            .project = if (stmt.columnIsNull(6)) null else stmt.columnI64(6),
            .posting_span = if (stmt.columnIsNull(7)) null else stmt.columnI64(7),
            .captured = stmt.columnI64(8) != 0,
        };
    }

    fn freeRow(s: *Store, row: Row) void {
        if (row.text) |t| s.allocator.free(t);
        if (row.closed_by) |c| s.allocator.free(c);
    }

    fn checkSeen(row: Row, seen: Span) !void {
        if (row.start_ms != seen.start_ms or !std.meta.eql(row.end_ms, seen.end_ms)) return error.Stale;
    }

    /// Refuses [start, end) when it overlaps another focus interval (for a
    /// focus span) or any other interval of the same task. Open intervals,
    /// and an open `end`, reach to the end of time; zero-length ones take no room.
    fn checkFree(s: *Store, ignore: []const i64, task: i64, role: Role, start: i64, end: ?i64) !void {
        var stmt = try s.db.prepare("SELECT 1 FROM intervals WHERE id NOT IN (?1,?2) AND (task_id=?3 OR (?4='focus' AND role='focus')) AND start_ms<?5 AND coalesce(end_ms,?6)>?7 AND coalesce(end_ms,?6)>start_ms LIMIT 1");
        defer stmt.finalize();
        try stmt.bindI64(1, if (ignore.len > 0) ignore[0] else -1);
        try stmt.bindI64(2, if (ignore.len > 1) ignore[1] else -1);
        try stmt.bindI64(3, task);
        try stmt.bindText(4, sqlText(role));
        try stmt.bindI64(5, end orelse max_time_ms);
        try stmt.bindI64(6, max_time_ms);
        try stmt.bindI64(7, start);
        if (try stmt.step() == .row) return error.Overlap;
    }

    fn checkNotesInside(s: *Store, interval: i64, start: i64, end: i64) !void {
        var stmt = try s.db.prepare("SELECT 1 FROM notes WHERE interval_id=?1 AND (at_ms<?2 OR at_ms>?3) LIMIT 1");
        defer stmt.finalize();
        try stmt.bindI64(1, interval);
        try stmt.bindI64(2, start);
        try stmt.bindI64(3, end);
        if (try stmt.step() == .row) return error.NoteOutside;
    }

    /// Stamps every reporting day that [start, end] touches as edited now.
    fn markEdited(s: *Store, start: i64, end: i64, now_ms: i64) !void {
        const z = try s.loadZone();
        var at = start;
        const last = @max(start, end);
        var days: u32 = 0;
        while (days < 400) : (days += 1) {
            const d = z.dateOf(at) catch return error.InvalidTime;
            var buffer: [10]u8 = undefined;
            const day = try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
            var stmt = try s.db.prepare("INSERT INTO day_edits(day,edited_ms) VALUES(?1,?2) ON CONFLICT(day) DO UPDATE SET edited_ms=excluded.edited_ms");
            defer stmt.finalize();
            try stmt.bindText(1, day);
            try stmt.bindI64(2, now_ms);
            _ = try stmt.step();
            const bounds = z.dayBounds(d.year, d.month, d.day) catch return error.InvalidTime;
            if (bounds.end_ms > last) break;
            at = bounds.end_ms;
        }
    }

    fn validSpan(start: i64, end: ?i64, now_ms: i64) !void {
        if (start < 0 or start > now_ms) return error.InvalidRange;
        if (end) |e| if (e <= start or e > now_ms) return error.InvalidRange;
    }

    /// Moves an interval's start and end. `seen` is the span the caller read;
    /// an open interval keeps its open end.
    pub fn editInterval(s: *Store, id: i64, seen: Span, start: i64, end: ?i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const row = try s.intervalRow(id);
        defer s.freeRow(row);
        try checkSeen(row, seen);
        if ((row.end_ms == null) != (end == null)) return error.OpenEnd;
        try validSpan(start, end, now_ms);
        try s.checkFree(&.{id}, row.task, row.role, start, end);
        try s.checkNotesInside(id, start, end orelse now_ms);
        var stmt = try s.db.prepare("UPDATE intervals SET start_ms=?1,end_ms=?2 WHERE id=?3");
        defer stmt.finalize();
        try stmt.bindI64(1, start);
        if (end) |e| try stmt.bindI64(2, e) else try stmt.bindNull(2);
        try stmt.bindI64(3, id);
        _ = try stmt.step();
        try s.markEdited(@min(row.start_ms, start), @max(row.end_ms orelse now_ms, end orelse now_ms), now_ms);
        try tx.commit();
    }

    pub fn endAtLastActivity(s: *Store, id: i64, seen: Span, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const row = try s.intervalRow(id);
        defer s.freeRow(row);
        try checkSeen(row, seen);
        if (row.end_ms != null or !row.captured or row.posting_span != null) return error.InvalidState;
        var latest = try s.db.prepare("SELECT max(?2,coalesce((SELECT max(at_ms) FROM notes WHERE interval_id=?1 AND source IN ('prompt','outcome') AND at_ms>=?2 AND at_ms<=?3),?2),coalesce((SELECT max(e.at_ms) FROM capture_events e JOIN capture_runs r ON r.source=e.source AND r.run=e.run WHERE r.task_id=?4 AND e.at_ms>=?2 AND e.at_ms<=?3),?2))");
        defer latest.finalize();
        try latest.bindI64(1, id);
        try latest.bindI64(2, row.start_ms);
        try latest.bindI64(3, now_ms);
        try latest.bindI64(4, row.task);
        _ = try latest.step();
        const end = @max(row.start_ms, if (latest.columnIsNull(0)) row.start_ms else latest.columnI64(0));
        var close = try s.db.prepare("UPDATE intervals SET end_ms=?1,closed_by='stop' WHERE id=?2");
        defer close.finalize();
        try close.bindI64(1, end);
        try close.bindI64(2, id);
        _ = try close.step();
        var runs = try s.db.prepare("UPDATE capture_runs SET working=0,idle_since_ms=NULL,lease_until_ms=NULL WHERE task_id=?1 AND (working=1 OR idle_since_ms IS NOT NULL)");
        defer runs.finalize();
        try runs.bindI64(1, row.task);
        _ = try runs.step();
        try s.markEdited(row.start_ms, now_ms, now_ms);
        try tx.commit();
    }

    pub fn takeFocus(s: *Store, id: i64, seen: Span, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const chosen = try s.intervalRow(id);
        defer s.freeRow(chosen);
        try checkSeen(chosen, seen);
        if (chosen.role != .parallel or chosen.posting_span != null) return error.InvalidState;
        if (chosen.end_ms) |end| if (end <= chosen.start_ms) return error.InvalidState;
        try s.promoteFocusInterval(id, now_ms);
        try tx.commit();
    }

    fn promoteFocusInterval(s: *Store, id: i64, now_ms: i64) !void {
        const chosen = try s.intervalRow(id);
        defer s.freeRow(chosen);
        const finish = chosen.end_ms orelse max_time_ms;
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(s.allocator);
        {
            var find = try s.db.prepare("SELECT id FROM intervals WHERE role='focus' AND start_ms<?1 AND coalesce(end_ms,?2)>?3 AND coalesce(end_ms,?2)>start_ms ORDER BY start_ms,id");
            defer find.finalize();
            try find.bindI64(1, finish);
            try find.bindI64(2, max_time_ms);
            try find.bindI64(3, chosen.start_ms);
            while (try find.step() == .row) try ids.append(s.allocator, find.columnI64(0));
        }
        for (ids.items) |other_id| {
            const row = try s.intervalRow(other_id);
            defer s.freeRow(row);
            if (try s.isPostedInterval(other_id, row, now_ms)) return error.InvalidState;
            const overlap_start = @max(row.start_ms, chosen.start_ms);
            const overlap_end = @min(row.end_ms orelse max_time_ms, finish);
            const before = overlap_start > row.start_ms;
            const after = overlap_end < (row.end_ms orelse max_time_ms);
            var update = try s.db.prepare("UPDATE intervals SET role='parallel',start_ms=?1,end_ms=?2,closed_by=?3 WHERE id=?4");
            defer update.finalize();
            try update.bindI64(1, overlap_start);
            if (row.end_ms == null and chosen.end_ms == null) try update.bindNull(2) else try update.bindI64(2, overlap_end);
            if (after) try update.bindText(3, "switch") else if (row.closed_by) |reason| try update.bindText(3, reason) else try update.bindNull(3);
            try update.bindI64(4, other_id);
            _ = try update.step();
            if (before) {
                const piece = try s.insertPiece(row.task, .focus, row.start_ms, overlap_start, "switch", row.project, row.posting_span, row.captured);
                try s.moveNotes(other_id, piece, row.start_ms, overlap_start);
            }
            if (after) {
                const tail = try s.insertPiece(row.task, .focus, overlap_end, row.end_ms, row.closed_by orelse "switch", row.project, row.posting_span, row.captured);
                try s.moveNotes(other_id, tail, overlap_end, null);
            }
        }
        var promote = try s.db.prepare("UPDATE intervals SET role='focus' WHERE id=?1");
        defer promote.finalize();
        try promote.bindI64(1, id);
        _ = try promote.step();
        // A run's next busy re-engages its task in its stored role: keep those roles in step.
        try s.db.exec("UPDATE capture_runs SET role=(SELECT i.role FROM intervals i WHERE i.task_id=capture_runs.task_id AND i.end_ms IS NULL) WHERE ended_ms IS NULL AND EXISTS (SELECT 1 FROM intervals i WHERE i.task_id=capture_runs.task_id AND i.end_ms IS NULL AND i.role<>coalesce(capture_runs.role,''))");
        try s.markEdited(chosen.start_ms, chosen.end_ms orelse now_ms, now_ms);
    }

    /// Joins `second` into `first`: same task and role, `first` closed and
    /// ending at or before `second` starts. The gap between them becomes
    /// tracked time, so it must be free. `second`'s session text becomes a
    /// note at its start; notes keep their times.
    pub fn mergeIntervals(s: *Store, first: i64, first_seen: Span, second: i64, second_seen: Span, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const a = try s.intervalRow(first);
        defer s.freeRow(a);
        const b = try s.intervalRow(second);
        defer s.freeRow(b);
        try checkSeen(a, first_seen);
        try checkSeen(b, second_seen);
        if (first == second or a.task != b.task or a.role != b.role or a.project != b.project) return error.NotMergeable;
        const a_end = a.end_ms orelse return error.NotMergeable;
        if (a_end > b.start_ms) return error.NotMergeable;
        try s.checkFree(&.{ first, second }, a.task, a.role, a_end, b.start_ms);
        if (b.text) |text| if (text.len > 0) {
            var note = try s.db.prepare("INSERT INTO notes(interval_id,at_ms,text) VALUES(?1,?2,?3)");
            defer note.finalize();
            try note.bindI64(1, first);
            try note.bindI64(2, b.start_ms);
            try note.bindText(3, text);
            _ = try note.step();
        };
        {
            var move = try s.db.prepare("UPDATE notes SET interval_id=?1 WHERE interval_id=?2");
            defer move.finalize();
            try move.bindI64(1, first);
            try move.bindI64(2, second);
            _ = try move.step();
        }
        {
            // Deleted first: the open-interval indexes allow one open row per task.
            var del = try s.db.prepare("DELETE FROM intervals WHERE id=?1");
            defer del.finalize();
            try del.bindI64(1, second);
            _ = try del.step();
        }
        var stmt = try s.db.prepare("UPDATE intervals SET end_ms=?1,closed_by=?2 WHERE id=?3");
        defer stmt.finalize();
        if (b.end_ms) |e| try stmt.bindI64(1, e) else try stmt.bindNull(1);
        try stmt.bindOptionalText(2, b.closed_by);
        try stmt.bindI64(3, first);
        _ = try stmt.step();
        try s.markEdited(a.start_ms, b.end_ms orelse now_ms, now_ms);
        try tx.commit();
    }

    /// Records a finished past interval.
    pub fn addInterval(s: *Store, task: i64, role: Role, start: i64, end: i64, now_ms: i64) Error!i64 {
        return s.addIntervalProject(task, role, start, end, .omitted, now_ms);
    }

    pub fn addIntervalProject(s: *Store, task: i64, role: Role, start: i64, end: i64, choice: ProjectChoice, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const project = try s.chosenProject(task, choice);
        try validSpan(start, end, now_ms);
        try s.checkFree(&.{}, task, role, start, end);
        var stmt = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by,project_id) VALUES(?1,?2,?3,?4,?5,'stop',?6) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, sqlText(role));
        try stmt.bindI64(3, start);
        try stmt.bindI64(4, end);
        try stmt.bindText(5, if (role == .focus) "switch" else "parallel");
        if (project) |p| try stmt.bindI64(6, p) else try stmt.bindNull(6);
        if ((stmt.step() catch |err| {
            if (s.db.isConstraint()) return error.UnknownTask;
            return err;
        }) != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        try s.markEdited(start, end, now_ms);
        try tx.commit();
        return id;
    }

    /// A stretch of an interval: [from, to).
    pub const Part = struct { from: i64, to: i64 };

    /// Gives a closed interval, or the `part` of it, to another task, with
    /// the notes in that stretch. Moving a part cuts the interval into up to
    /// three pieces (before, moved, after) that keep their times; the other
    /// task must have the moved stretch free. Returns the moved interval.
    pub fn moveInterval(s: *Store, id: i64, seen: Span, to_task: i64, part: ?Part, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const row = try s.intervalRow(id);
        defer s.freeRow(row);
        try checkSeen(row, seen);
        const end = row.end_ms orelse return error.OpenEnd;
        var exists = try s.db.prepare("SELECT 1 FROM tasks WHERE id=?1");
        defer exists.finalize();
        try exists.bindI64(1, to_task);
        if (try exists.step() == .done) return error.UnknownTask;
        const from = if (part) |p| @max(row.start_ms, p.from) else row.start_ms;
        const to = if (part) |p| @min(end, p.to) else end;
        if (from >= to) return error.InvalidRange;
        if (to_task == row.task) return id;
        try s.checkFree(&.{id}, to_task, row.role, from, to);
        const last_closed_by = row.closed_by orelse "stop";
        // The original row becomes the first piece; the others are new rows.
        const moved = if (from == row.start_ms) blk: {
            try s.reshape(id, to_task, to, if (to == end) last_closed_by else "switch");
            break :blk id;
        } else blk: {
            try s.reshape(id, row.task, from, "switch");
            break :blk try s.insertPiece(to_task, row.role, from, to, if (to == end) last_closed_by else "switch", row.project, row.posting_span, row.captured);
        };
        const tail: ?i64 = if (to < end) try s.insertPiece(row.task, row.role, to, end, last_closed_by, row.project, row.posting_span, row.captured) else null;
        // Notes follow their time: before `from` stays, past `to` goes to the tail.
        if (moved != id) try s.moveNotes(id, moved, from, null);
        if (tail) |t| try s.moveNotes(moved, t, to, null);
        try s.markEdited(from, to, now_ms);
        try tx.commit();
        return moved;
    }

    fn reshape(s: *Store, id: i64, task: i64, end: i64, closed_by: []const u8) !void {
        var stmt = try s.db.prepare("UPDATE intervals SET task_id=?1,end_ms=?2,closed_by=?3 WHERE id=?4");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindI64(2, end);
        try stmt.bindText(3, closed_by);
        try stmt.bindI64(4, id);
        _ = try stmt.step();
    }

    fn insertPiece(s: *Store, task: i64, role: Role, start: i64, end: ?i64, closed_by: []const u8, project: ?i64, posting_span: ?i64, captured: bool) !i64 {
        var stmt = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by,project_id,posting_span_id,captured) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, sqlText(role));
        try stmt.bindI64(3, start);
        if (end) |value| try stmt.bindI64(4, value) else try stmt.bindNull(4);
        try stmt.bindText(5, if (role == .focus) "switch" else "parallel");
        if (end == null) try stmt.bindNull(6) else try stmt.bindText(6, closed_by);
        if (project) |p| try stmt.bindI64(7, p) else try stmt.bindNull(7);
        if (posting_span) |span| try stmt.bindI64(8, span) else try stmt.bindNull(8);
        try stmt.bindI64(9, @intFromBool(captured));
        if (try stmt.step() != .row) return error.Sqlite;
        const new_id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        return new_id;
    }

    /// Moves the notes of interval `from_id` at or after `at` (and before
    /// `before`, when given) to interval `to_id`.
    fn moveNotes(s: *Store, from_id: i64, to_id: i64, at: i64, before: ?i64) !void {
        var stmt = try s.db.prepare("UPDATE notes SET interval_id=?1 WHERE interval_id=?2 AND at_ms>=?3 AND at_ms<?4");
        defer stmt.finalize();
        try stmt.bindI64(1, to_id);
        try stmt.bindI64(2, from_id);
        try stmt.bindI64(3, at);
        try stmt.bindI64(4, before orelse max_time_ms);
        _ = try stmt.step();
    }

    /// Deletes a closed interval and its notes.
    pub fn deleteInterval(s: *Store, id: i64, seen: Span, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        const row = try s.intervalRow(id);
        defer s.freeRow(row);
        try checkSeen(row, seen);
        const end = row.end_ms orelse return error.OpenEnd;
        var stmt = try s.db.prepare("DELETE FROM intervals WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, id);
        _ = try stmt.step();
        try s.markEdited(row.start_ms, end, now_ms);
        try tx.commit();
    }

    /// Deletes a task with its intervals, notes, binding and fields. A task
    /// that was ever posted, or has an open interval, is refused; it also
    /// leaves the paused set, so a resume does not bring it back.
    pub fn deleteTask(s: *Store, task: i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        var check = try s.db.prepare("SELECT (SELECT count(*) FROM tasks WHERE id=?1),(SELECT count(*) FROM postings WHERE task_id=?1),(SELECT count(*) FROM intervals WHERE task_id=?1 AND end_ms IS NULL)");
        defer check.finalize();
        try check.bindI64(1, task);
        _ = try check.step();
        if (check.columnI64(0) == 0) return error.UnknownTask;
        if (check.columnI64(1) > 0) return error.TaskHasPostings;
        if (check.columnI64(2) > 0) return error.TaskOpen;
        var spans = try s.db.prepare("SELECT start_ms,end_ms FROM intervals WHERE task_id=?1");
        defer spans.finalize();
        try spans.bindI64(1, task);
        while (try spans.step() == .row) try s.markEdited(spans.columnI64(0), spans.columnI64(1), now_ms);
        for ([_][]const u8{
            "DELETE FROM intervals WHERE task_id=?1",
            "DELETE FROM saved_set WHERE task_id=?1",
            "DELETE FROM tasks WHERE id=?1",
        }) |sql| {
            var stmt = try s.db.prepare(sql);
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            _ = try stmt.step();
        }
        try tx.commit();
    }

    fn noteFits(s: *Store, interval: i64, at_ms: i64, now_ms: i64) !void {
        var stmt = try s.db.prepare("SELECT start_ms,end_ms FROM intervals WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, interval);
        if (try stmt.step() == .done) return error.UnknownInterval;
        const end = if (stmt.columnIsNull(1)) now_ms else stmt.columnI64(1);
        if (at_ms < stmt.columnI64(0) or at_ms > end) return error.NoteOutside;
    }

    /// A note at any time inside an interval, open or closed.
    pub fn addNoteAt(s: *Store, interval: i64, at_ms: i64, text: []const u8, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (text.len == 0) return error.EmptyText;
        try s.noteFits(interval, at_ms, now_ms);
        var stmt = try s.db.prepare("INSERT INTO notes(interval_id,at_ms,text) VALUES(?1,?2,?3) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, interval);
        try stmt.bindI64(2, at_ms);
        try stmt.bindText(3, text);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        try tx.commit();
        return id;
    }

    fn noteInterval(s: *Store, note: i64) !i64 {
        var stmt = try s.db.prepare("SELECT interval_id FROM notes WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, note);
        if (try stmt.step() == .done) return error.UnknownNote;
        return stmt.columnI64(0);
    }

    pub fn editNote(s: *Store, note: i64, text: []const u8, at_ms: ?i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (text.len == 0) return error.EmptyText;
        const interval = try s.noteInterval(note);
        if (at_ms) |at| try s.noteFits(interval, at, now_ms);
        var stmt = try s.db.prepare("UPDATE notes SET text=?1,at_ms=coalesce(?2,at_ms) WHERE id=?3");
        defer stmt.finalize();
        try stmt.bindText(1, text);
        if (at_ms) |at| try stmt.bindI64(2, at) else try stmt.bindNull(2);
        try stmt.bindI64(3, note);
        _ = try stmt.step();
        try tx.commit();
    }

    pub fn deleteNote(s: *Store, note: i64, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        _ = try s.noteInterval(note);
        var stmt = try s.db.prepare("DELETE FROM notes WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindI64(1, note);
        _ = try stmt.step();
        try tx.commit();
    }

    pub fn removeCapturedText(s: *Store, from_ms: i64, to_ms: i64, apply: bool, now_ms: i64) Error!i64 {
        if (apply) {
            var tx = try s.begin(now_ms, false);
            defer tx.deinit();
            var stmt = try s.db.prepare("DELETE FROM notes WHERE source IN ('prompt','outcome') AND at_ms>=?1 AND at_ms<?2");
            defer stmt.finalize();
            try stmt.bindI64(1, from_ms);
            try stmt.bindI64(2, to_ms);
            _ = try stmt.step();
            const count = s.db.changes();
            try tx.commit();
            return count;
        }
        var stmt = try s.db.prepare("SELECT count(*) FROM notes WHERE source IN ('prompt','outcome') AND at_ms>=?1 AND at_ms<?2");
        defer stmt.finalize();
        try stmt.bindI64(1, from_ms);
        try stmt.bindI64(2, to_ms);
        _ = try stmt.step();
        return stmt.columnI64(0);
    }

    pub fn getSetting(s: *Store, key: []const u8) Error!?[]u8 {
        var stmt = try s.db.prepare("SELECT value FROM settings WHERE key=?1");
        defer stmt.finalize();
        try stmt.bindText(1, key);
        if (try stmt.step() == .done) return null;
        return try s.allocator.dupe(u8, stmt.columnText(0).?);
    }

    pub const SettingChange = struct { key: []const u8, value: ?[]const u8 };

    pub fn validateSetting(_: *Store, key: []const u8, value: ?[]const u8) !void {
        const val = value orelse return;
        if (std.mem.eql(u8, key, "reporting_zone")) {
            if (val.len == 0) return error.InvalidSetting;
            _ = try zone.Zone.load(val);
        } else if (std.mem.eql(u8, key, "day_start")) {
            _ = parseDayStart(val) catch return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "daily_work_minutes")) {
            const n = std.fmt.parseInt(u16, val, 10) catch return error.InvalidSetting;
            if (n < 1 or n > 1440) return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "lunch_minutes")) {
            const n = std.fmt.parseInt(u16, val, 10) catch return error.InvalidSetting;
            if (n > 600) return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "http_port")) {
            const n = std.fmt.parseInt(u16, val, 10) catch return error.InvalidSetting;
            if (n < 1024) return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "lock_pause")) {
            if (lockWindowsContain(val, 0) == null) return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "project_provider_field")) {
            if (val.len > 200) return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "capture_hold_sources")) {
            if (val.len > 1000) return error.InvalidSetting;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |item| if (std.mem.trim(u8, item, " ").len > 200) return error.InvalidSetting;
        }
    }

    pub fn setSetting(s: *Store, key: []const u8, value: ?[]const u8, now_ms: i64) Error!void {
        return s.setSettings(&.{.{ .key = key, .value = value }}, now_ms);
    }

    /// Applies every change or none.
    pub fn setSettings(s: *Store, batch: []const SettingChange, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        for (batch) |c| try s.validateSetting(c.key, c.value);
        for (batch) |c| {
            if (c.value) |v| {
                var stmt = try s.db.prepare("INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
                defer stmt.finalize();
                try stmt.bindText(1, c.key);
                try stmt.bindText(2, v);
                _ = try stmt.step();
            } else {
                var stmt = try s.db.prepare("DELETE FROM settings WHERE key=?1");
                defer stmt.finalize();
                try stmt.bindText(1, c.key);
                _ = try stmt.step();
            }
        }
        try tx.commit();
    }

    pub fn reportingZone(s: *Store) Error!?[]u8 {
        return s.getSetting("reporting_zone");
    }

    pub fn loadZone(s: *Store) !zone.Zone {
        const id = try s.reportingZone();
        defer if (id) |v| s.allocator.free(v);
        const name = id orelse "UTC";
        var cached: ?zone.Zone = if (s.zone_cache) |c| (if (std.mem.eql(u8, c.id[0..c.len], name)) c.zone else null) else null;
        if (cached == null) {
            const found = try zone.Zone.load(name);
            if (name.len <= 128) {
                s.zone_cache = .{ .id = undefined, .len = name.len, .zone = found };
                @memcpy(s.zone_cache.?.id[0..name.len], name);
            }
            cached = found;
        }
        var z = cached.?;
        const setting = try s.getSetting("day_start");
        defer if (setting) |v| s.allocator.free(v);
        if (setting) |v| z.day_start_min = try parseDayStart(v);
        return z;
    }

    fn minuteSetting(s: *Store, key: []const u8, default: u16) !u16 {
        const value = try s.getSetting(key);
        defer if (value) |v| s.allocator.free(v);
        if (value) |v| return try std.fmt.parseInt(u16, v, 10);
        return default;
    }

    pub fn dailyWorkMinutes(s: *Store) Error!u16 {
        return s.minuteSetting("daily_work_minutes", 510);
    }

    pub fn lunchMinutes(s: *Store) Error!u16 {
        return s.minuteSetting("lunch_minutes", 60);
    }

    pub fn setDaySummary(s: *Store, day: []const u8, text: []const u8, now_ms: i64) Error!void {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (text.len == 0) {
            var stmt = try s.db.prepare("DELETE FROM day_summaries WHERE day=?1");
            defer stmt.finalize();
            try stmt.bindText(1, day);
            _ = try stmt.step();
        } else {
            var stmt = try s.db.prepare("INSERT INTO day_summaries(day,text) VALUES(?1,?2) ON CONFLICT(day) DO UPDATE SET text=excluded.text");
            defer stmt.finalize();
            try stmt.bindText(1, day);
            try stmt.bindText(2, text);
            _ = try stmt.step();
        }
        try tx.commit();
    }

    pub fn daySummary(s: *Store, day: []const u8) Error!?[]u8 {
        var stmt = try s.db.prepare("SELECT text FROM day_summaries WHERE day=?1");
        defer stmt.finalize();
        try stmt.bindText(1, day);
        if (try stmt.step() == .done) return null;
        return try s.allocator.dupe(u8, stmt.columnText(0).?);
    }
};

/// Whether minute-of-day `minute` falls in one of the windows of a
/// `lock_pause` value; null when the value is malformed. "" has none.
pub fn lockWindowsContain(text: []const u8, minute: u16) ?bool {
    var found = false;
    var count: usize = 0;
    var items = std.mem.tokenizeScalar(u8, text, ',');
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        const dash = std.mem.indexOfScalar(u8, item, '-') orelse return null;
        const from = clockMinute(item[0..dash], false) orelse return null;
        const to = clockMinute(item[dash + 1 ..], true) orelse return null;
        count += 1;
        if (from == to or count > 8) return null;
        // A window that ends before it starts runs past midnight.
        if (if (from < to) minute >= from and minute < to else minute >= from or minute < to) found = true;
    }
    return found;
}

fn clockMinute(text: []const u8, allow_24: bool) ?u16 {
    if (text.len != 5 or text[2] != ':') return null;
    const h = std.fmt.parseInt(u16, text[0..2], 10) catch return null;
    const m = std.fmt.parseInt(u16, text[3..5], 10) catch return null;
    if (m > 59 or h > 24 or (h == 24 and (!allow_24 or m != 0))) return null;
    return h * 60 + m;
}

fn testScalar(db: *sqlite.Db, sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try std.testing.expectEqual(sqlite.Statement.Step.row, try stmt.step());
    return stmt.columnI64(0);
}

fn testText(db: *sqlite.Db, sql: []const u8, expected: []const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try std.testing.expectEqual(sqlite.Statement.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected, stmt.columnText(0).?);
}

fn expectRecoveredFocus(db: *sqlite.Db) !void {
    try std.testing.expectEqual(@as(i64, 1), try testScalar(db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='focus' AND end_ms=0"));
    try testText(db, "SELECT closed_by FROM intervals WHERE task_id=1", "recovered");
    try std.testing.expectEqual(@as(i64, 1), try testScalar(db, "SELECT count(*) FROM saved_set WHERE task_id=1 AND role='focus'"));
}

test "mutations refuse times outside the supported range" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    try std.testing.expectError(error.InvalidTime, s.onStart(-1));
    try std.testing.expectError(error.InvalidTime, s.onHeartbeat(max_time_ms));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM meta"));
}

test "store refuses a future schema version" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("PRAGMA user_version=13");
    try std.testing.expectError(error.SchemaVersion, Store.init(&db, std.testing.allocator));
}

test "switches preserve other parallels and titles are data" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("focus", 1);
    const b = try s.createTask("parallel", 2);
    const c = try s.createTask("all", 3);
    const d = try s.createTask("switch", 4);
    const first = try s.switchTo(a, "first", 100);
    const parallel = try s.openParallel(b, null, 110);
    _ = try s.openParallel(c, null, 115);
    const second = try s.switchTo(b, "second", 120);
    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(i64, 120), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=1"));
    try testText(&db, "SELECT closed_by FROM intervals WHERE id=1", "switch");
    try std.testing.expectEqual(@as(i64, 120), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=2"));
    try testText(&db, "SELECT closed_by FROM intervals WHERE id=2", "switch");
    try std.testing.expectEqual(parallel, @as(i64, 2));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=3 AND end_ms IS NULL AND role='parallel'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(second, try s.switchTo(b, "ignored", 130));
    try std.testing.expectEqual(@as(i64, 4), try testScalar(&db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 120), try testScalar(&db, "SELECT value FROM meta WHERE key='last_heartbeat_ms'"));
    try s.setIntervalText(first, "edited", 131);
    try testText(&db, "SELECT text FROM intervals WHERE id=1", "edited");
    try s.setIntervalText(first, null, 132);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE id=1 AND text IS NULL"));
    _ = try s.switchTo(d, null, 140);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=4 AND end_ms IS NULL"));
}

test "same-millisecond hops write no zero-length or overlapping interval" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, null, 100);
    try s.stop(a, 100);
    _ = try s.switchTo(a, null, 200);
    _ = try s.switchTo(b, null, 300);
    _ = try s.switchTo(a, null, 300);
    _ = try s.openParallel(b, null, 300);
    try s.pause(300);
    try s.@"resume"(300);
    try s.stop(b, 300);
    try s.pause(5_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms<=start_ms"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals x JOIN intervals y ON x.id<y.id AND (x.task_id=y.task_id OR (x.role='focus' AND y.role='focus')) AND x.start_ms<y.end_ms AND y.start_ms<x.end_ms"));
    try std.testing.expectEqual(@as(i64, 101), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=1"));
    try std.testing.expectEqual(@as(i64, 301), try testScalar(&db, "SELECT end_ms FROM intervals WHERE task_id=2 AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 5_000), try testScalar(&db, "SELECT max(end_ms) FROM intervals"));
    // A real clock jump back is not a hop: it is not nudged forward.
    _ = try s.switchTo(a, null, 1_000);
    try std.testing.expectEqual(@as(i64, 1_000), try testScalar(&db, "SELECT start_ms FROM intervals WHERE end_ms IS NULL"));
}

test "pause resume saved set and note routing" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    const c = try s.createTask("C", 3);
    const focus = try s.switchTo(a, null, 100);
    const parallel = try s.openParallel(b, null, 110);
    const note_focus = try s.addNote(null, "focus note", 120);
    const note_parallel = try s.addNote(b, "parallel note", 121);
    try std.testing.expectEqual(focus, try testScalar(&db, "SELECT interval_id FROM notes WHERE id=1"));
    try std.testing.expectEqual(parallel, try testScalar(&db, "SELECT interval_id FROM notes WHERE id=2"));
    try std.testing.expect(note_parallel > note_focus);
    try std.testing.expectError(error.NoOpenInterval, s.addNote(c, "no", 122));
    try std.testing.expectError(error.EmptyText, s.addNote(null, "", 122));
    try s.pause(130);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL"));
    try std.testing.expectError(error.NoFocus, s.addNote(null, "no", 131));
    try s.pause(132);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try s.@"resume"(140);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND role='focus' AND task_id=1 AND opened_by='resume'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND role='parallel' AND task_id=2 AND opened_by='resume'"));
    try std.testing.expectError(error.SomethingOpen, s.@"resume"(141));
    try s.pause(150);
    _ = try s.switchTo(c, null, 160);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try s.pause(170);
    _ = try s.openParallel(a, null, 180);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try s.stop(a, 190);
    try std.testing.expectError(error.NoOpenInterval, s.stop(a, 191));
}

test "stop closes focus and removes implicit note target" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("A", 1);
    _ = try s.switchTo(task, null, 100);
    try s.stop(task, 200);
    try std.testing.expectEqual(@as(i64, 200), try testScalar(&db, "SELECT end_ms FROM intervals WHERE task_id=1 AND role='focus'"));
    try testText(&db, "SELECT closed_by FROM intervals WHERE task_id=1 AND role='focus'", "stop");
    try std.testing.expectError(error.NoFocus, s.addNote(null, "later", 201));
}

test "failed switch and resume roll back all writes" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, null, 100);
    try db.exec("INSERT INTO saved_set(task_id,role) VALUES(2,'parallel')");
    try std.testing.expectError(error.UnknownTask, s.switchTo(999, null, 120));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND task_id=1"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try std.testing.expectEqual(@as(i64, 100), try testScalar(&db, "SELECT value FROM meta WHERE key='last_heartbeat_ms'"));
    try s.pause(130);
    try db.exec("PRAGMA foreign_keys=OFF");
    try db.exec("INSERT INTO saved_set(task_id,role) VALUES(999,'parallel')");
    try db.exec("PRAGMA foreign_keys=ON");
    const before = try testScalar(&db, "SELECT count(*) FROM intervals");
    try std.testing.expectError(error.Sqlite, s.@"resume"(140));
    try std.testing.expectEqual(before, try testScalar(&db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try std.testing.expectEqual(@as(i64, 100), try testScalar(&db, "SELECT value FROM meta WHERE key='last_heartbeat_ms'"));
    _ = b;
}

test "recovery from lifecycle events and guarded mutation" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, null, 100);
    try s.onHeartbeat(180_100);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL"));
    try s.onHeartbeat(360_101);
    try std.testing.expectEqual(@as(i64, 180_100), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=1"));
    try testText(&db, "SELECT closed_by FROM intervals WHERE id=1", "recovered");
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try s.@"resume"(400_000);
    _ = try s.openParallel(b, null, 400_100);
    _ = try s.startPosting("2026-03-10", a, "fake", "T-1", "1", 1_000_000, 400_101, null);
    try s.onStart(400_200);
    try std.testing.expectEqual(@as(i64, 400_100), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=3"));
    try std.testing.expectEqual(@as(i64, 400_100), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=2"));
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try testText(&db, "SELECT state FROM postings WHERE id=1", "unknown");
    try s.@"resume"(400_300);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL"));
    try s.onResume(400_400);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try std.testing.expectEqual(@as(i64, 400_300), try testScalar(&db, "SELECT min(end_ms) FROM intervals WHERE opened_by='resume' AND start_ms=400300"));
    try s.@"resume"(500_000);
    try std.testing.expectError(error.NoFocus, s.addNote(null, "late", 1_100_001));
}

test "a recovered interval resumes in its project" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const project = try s.createProject("Client work", 0);
    const a = try s.createTask("A", 0);
    _ = try s.switchToProject(a, null, .{ .selected = project }, 0);
    try s.onStart(400_000);
    try std.testing.expectEqual(project, try testScalar(&db, "SELECT project_id FROM saved_set WHERE task_id=1"));
    try s.@"resume"(400_100);
    try std.testing.expectEqual(project, try testScalar(&db, "SELECT project_id FROM intervals WHERE end_ms IS NULL AND opened_by='resume'"));
}

test "guard recovery survives NoFocus" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 0);
    _ = try s.switchTo(a, null, 0);
    try std.testing.expectError(error.NoFocus, s.addNote(null, "x", 180_001));
    try expectRecoveredFocus(&db);
}

test "guard recovery saves focus and parallel roles" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const focus = try s.createTask("A", 0);
    const parallel = try s.createTask("B", 0);
    _ = try s.switchTo(focus, null, 0);
    _ = try s.openParallel(parallel, null, 1);
    try s.setTitle(focus, "after gap", 181_001);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms=1 AND closed_by='recovered'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM saved_set WHERE task_id=1 AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM saved_set WHERE task_id=2 AND role='parallel'"));
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "after gap");
}

test "guard recovery survives EmptyText" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 0);
    _ = try s.switchTo(a, null, 0);
    try std.testing.expectError(error.EmptyText, s.addNote(null, "", 180_001));
    try expectRecoveredFocus(&db);
}

test "guard recovery survives failed switch FK" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 0);
    _ = try s.switchTo(a, null, 0);
    try std.testing.expectError(error.UnknownTask, s.switchTo(999, null, 180_001));
    try expectRecoveredFocus(&db);
}

test "guard recovery starts after the exact gap threshold" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 0);
    _ = try s.switchTo(a, null, 0);
    _ = try s.addNote(null, "at threshold", 180_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND end_ms IS NULL"));
    try std.testing.expectError(error.NoFocus, s.addNote(null, "past threshold", 180_001));
    try expectRecoveredFocus(&db);
}

test "recovery clamps to interval start without a fresh heartbeat" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    _ = try s.createTask("A", 1);
    _ = try s.createTask("B", 2);
    try db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(1,'focus',200,'switch'),(2,'parallel',400,'parallel')");
    try db.exec("INSERT INTO meta(key,value) VALUES('last_heartbeat_ms','300')");
    try s.onStart(1_000);
    try std.testing.expectEqual(@as(i64, 300), try testScalar(&db, "SELECT end_ms FROM intervals WHERE task_id=1"));
    try std.testing.expectEqual(@as(i64, 400), try testScalar(&db, "SELECT end_ms FROM intervals WHERE task_id=2"));
    try db.exec("DELETE FROM meta WHERE key='last_heartbeat_ms'");
    try s.@"resume"(2_000);
    try db.exec("DELETE FROM meta WHERE key='last_heartbeat_ms'");
    try s.onStart(3_000);
    try std.testing.expectEqual(@as(i64, 2_000), try testScalar(&db, "SELECT min(end_ms) FROM intervals WHERE opened_by='resume'"));
}

test "startup recovers an abruptly closed file database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/crash.db", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    {
        var db: sqlite.Db = .{};
        try db.open(path);
        defer db.close();
        var s = try Store.init(&db, std.testing.allocator);
        const task = try s.createTask("A", 1);
        _ = try s.switchTo(task, null, 100);
    }
    var db: sqlite.Db = .{};
    try db.open(path);
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    try s.onStart(1_000_000);
    try std.testing.expectEqual(@as(i64, 100), try testScalar(&db, "SELECT end_ms FROM intervals"));
    try testText(&db, "SELECT closed_by FROM intervals", "recovered");
}

test "posting ledger states and blocking" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("A", 1);
    const p = try s.startPosting("2026-03-10", task, "fake", "T-1", "1.25", 1_250_000, 10, null);
    try std.testing.expectError(error.InvalidState, s.resolveUnknown(p, true, null, 11));
    try std.testing.expect(try s.isBlocked("2026-03-10", "fake", "T-1"));
    try std.testing.expectError(error.PostingBlocked, s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1, 13, null));
    const independent = try s.startPosting("2026-03-10", task, "fake", "T-2", "1", 1, 13, null);
    try s.postingFailed(independent, 13);
    try s.markUnknown(p, 14);
    try std.testing.expectError(error.PostingBlocked, s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1, 15, null));
    try std.testing.expectError(error.InvalidState, s.markUnknown(p, 15));
    try s.resolveUnknown(p, false, null, 16);
    try std.testing.expect(!(try s.isBlocked("2026-03-10", "fake", "T-1")));
    const p2 = try s.startPosting("2026-03-10", task, "fake", "T-1", "2", 2_000_000, 17, null);
    try s.confirmPosting(p2, "1.75", 1_750_000, "receipt", 19);
    try testText(&db, "SELECT provider_data FROM postings WHERE id=3", "receipt");
    try testText(&db, "SELECT amount_text FROM postings WHERE id=3", "1.75");
    try std.testing.expectEqual(@as(i64, 1_750_000), try testScalar(&db, "SELECT amount_micro FROM postings WHERE id=3"));
    try std.testing.expectError(error.InvalidState, s.confirmPosting(p2, null, null, null, 20));
    const p3 = try s.startPosting("2026-03-10", task, "fake", "T-1", "3", 3, 20, null);
    try s.postingFailed(p3, 22);
    try std.testing.expectError(error.InvalidState, s.postingFailed(p3, 23));
    const p4 = try s.startPosting("2026-03-12", task, "fake", "T-1", "4", 4, 24, null);
    try s.markUnknown(p4, 26);
    try s.resolveUnknown(p4, true, "late receipt", 27);
    try testText(&db, "SELECT state FROM postings WHERE id=5", "confirmed");
    try std.testing.expectEqual(@as(i64, 27), try testScalar(&db, "SELECT confirmed_ms FROM postings WHERE id=5"));
}

test "session coverage refuses intersection and total mixing" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("A", 1);
    const first = try s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1_000_000, 10, .{ .start_ms = 100, .end_ms = 200 });
    try s.confirmPosting(first, null, null, null, 11);
    try std.testing.expectError(error.PostingBlocked, s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1_000_000, 12, .{ .start_ms = 199, .end_ms = 250 }));
    _ = try s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1_000_000, 13, .{ .start_ms = 200, .end_ms = 250 });
}

test "late posting success confirms unknown state" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("A", 0);
    const posting = try s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1_000_000, 1, null);
    try s.markUnknown(posting, 3);
    try s.confirmPosting(posting, null, null, "late receipt", 4);
    try testText(&db, "SELECT state FROM postings WHERE id=1", "confirmed");
    try testText(&db, "SELECT provider_data FROM postings WHERE id=1", "late receipt");
    try std.testing.expectEqual(@as(i64, 4), try testScalar(&db, "SELECT confirmed_ms FROM postings WHERE id=1"));
}

test "in-flight posting blocks the same ref but not another ref" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("A", 1);
    _ = try s.startPosting("2026-03-10", task, "fake", "T-1", "1", 1, 2, null);
    try std.testing.expectError(error.PostingBlocked, s.startPosting("2026-03-10", task, "fake", "T-1", "2", 2, 3, null));
    _ = try s.startPosting("2026-03-10", task, "fake", "T-2", "2", 2, 3, null);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM postings WHERE state='sending'"));
}

test "settings bindings summaries and switch over" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    try s.bind(a, "acme", "T-1", 3);
    try std.testing.expectEqual(a, (try s.taskByBinding("acme", "T-1")).?);
    try std.testing.expectEqual(@as(?i64, null), try s.taskByBinding("acme", "T-2"));
    try std.testing.expectError(error.BindingConflict, s.bind(b, "acme", "T-1", 4));
    try s.setTitle(a, "Changed", 5);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "Changed");
    try std.testing.expectError(error.EmptyText, s.setTitle(a, "", 6));
    try s.setField(a, "color", "blue", 7);
    try testText(&db, "SELECT value FROM task_fields WHERE task_id=1", "blue");
    try s.setField(a, "color", "", 8);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM task_fields"));
    try std.testing.expectEqual(@as(u16, 510), try s.dailyWorkMinutes());
    try std.testing.expectEqual(@as(u16, 60), try s.lunchMinutes());
    try std.testing.expect((try s.reportingZone()) == null);
    try std.testing.expectError(error.InvalidSetting, s.setSetting("daily_work_minutes", "0", 9));
    try std.testing.expectError(error.InvalidSetting, s.setSetting("lunch_minutes", "601", 9));
    try s.setSetting("daily_work_minutes", "480", 13);
    try std.testing.expectEqual(@as(u16, 480), try s.dailyWorkMinutes());
    try s.setSetting("reporting_zone", "UTC", 15);
    const reporting = (try s.reportingZone()).?;
    defer std.testing.allocator.free(reporting);
    try std.testing.expectEqualStrings("UTC", reporting);
    try s.setSetting("custom", "value", 16);
    const custom = (try s.getSetting("custom")).?;
    defer std.testing.allocator.free(custom);
    try std.testing.expectEqualStrings("value", custom);
    try s.setDaySummary("2026-03-10", "worked", 17);
    const summary = (try s.daySummary("2026-03-10")).?;
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("worked", summary);
    try s.setDaySummary("2026-03-10", "", 18);
    try std.testing.expect((try s.daySummary("2026-03-10")) == null);
}

test "screen lock pauses only inside a lock window" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const minute: i64 = 60_000;
    const noon: i64 = 20_000 * 24 * 60 * minute + 12 * 60 * minute; // UTC noon
    const a = try s.createTask("A", noon);
    _ = try s.switchTo(a, null, noon);
    try std.testing.expect(!(try s.onLock(noon + 1000))); // no windows
    try std.testing.expectError(error.InvalidSetting, s.setSetting("lock_pause", "17:00", noon + 2000));
    try std.testing.expectError(error.InvalidSetting, s.setSetting("lock_pause", "17:00-17:00", noon + 2000));
    try s.setSetting("lock_pause", "11:30-12:30,22:00-06:00", noon + 3000);
    try std.testing.expect(!(try s.onLock(noon + 4000))); // no reporting zone
    try s.setSetting("reporting_zone", "UTC", noon + 5000);
    try std.testing.expect(try s.onLock(noon + 6000)); // 12:00, in the first window
    try testText(&db, "SELECT closed_by FROM intervals", "pause");
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM lunches"));
    try std.testing.expect(!(try s.onLock(noon + 7000))); // nothing open
    _ = try s.switchTo(a, null, noon + 30 * minute);
    try std.testing.expect(!(try s.onLock(noon + 30 * minute + 1000))); // 12:30: the end is exclusive
    _ = try s.switchTo(a, null, noon + 11 * 60 * minute);
    try std.testing.expect(try s.onLock(noon + 11 * 60 * minute + 1000)); // 23:00, a window crossing midnight
    try std.testing.expectEqual(true, lockWindowsContain("22:00-06:00", 5 * 60).?);
    try std.testing.expectEqual(false, lockWindowsContain("22:00-06:00", 6 * 60).?);
    try std.testing.expectEqual(true, lockWindowsContain("08:00-09:00, 17:00-24:00", 23 * 60 + 59).?);
    try std.testing.expectEqual(false, lockWindowsContain("", 0).?);
}

test "history edits refuse stale, overlapping and note-orphaning changes" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    const c = try s.createTask("C", 3);
    _ = try s.switchTo(a, null, 1_000);
    _ = try s.switchTo(b, null, 5_000);
    try s.stop(b, 9_000);
    _ = try s.addNoteAt(1, 2_000, "inside", 9_100);
    try std.testing.expectError(error.NoteOutside, s.addNoteAt(1, 5_001, "after", 9_100));

    try s.editInterval(1, .{ .start_ms = 1_000, .end_ms = 5_000 }, 1_500, 4_000, 10_000);
    try std.testing.expectEqual(@as(i64, 4_000), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=1"));
    try std.testing.expectEqual(@as(i64, 10_000), try testScalar(&db, "SELECT edited_ms FROM day_edits WHERE day='1970-01-01'"));
    try std.testing.expectError(error.Stale, s.editInterval(1, .{ .start_ms = 1_000, .end_ms = 5_000 }, 1_500, 4_500, 10_000));
    try std.testing.expectError(error.Overlap, s.editInterval(1, .{ .start_ms = 1_500, .end_ms = 4_000 }, 1_500, 6_000, 10_000));
    try std.testing.expectError(error.NoteOutside, s.editInterval(1, .{ .start_ms = 1_500, .end_ms = 4_000 }, 2_500, 4_000, 10_000));
    try std.testing.expectError(error.InvalidRange, s.editInterval(1, .{ .start_ms = 1_500, .end_ms = 4_000 }, 3_000, 3_000, 10_000));

    _ = try s.switchTo(a, null, 10_000);
    try std.testing.expectError(error.OpenEnd, s.editInterval(3, .{ .start_ms = 10_000, .end_ms = null }, 9_500, 12_000, 13_000));
    try std.testing.expectError(error.Overlap, s.editInterval(3, .{ .start_ms = 10_000, .end_ms = null }, 8_000, null, 13_000));
    try s.editInterval(3, .{ .start_ms = 10_000, .end_ms = null }, 9_500, null, 13_000);
    // A closed interval cannot grow into the open one.
    try std.testing.expectError(error.Overlap, s.editInterval(2, .{ .start_ms = 5_000, .end_ms = 9_000 }, 5_000, 9_600, 13_000));

    // Parallel time may sit under focus; focus may not.
    _ = try s.addInterval(c, .parallel, 2_000, 3_000, 13_000);
    try std.testing.expectError(error.Overlap, s.addInterval(c, .focus, 2_000, 3_000, 13_000));
    try std.testing.expectError(error.Overlap, s.addInterval(c, .parallel, 2_500, 3_500, 13_000));
    const added = try s.addInterval(c, .focus, 9_000, 9_500, 13_000);
    try testText(&db, "SELECT opened_by FROM intervals WHERE id=5", "switch");
    try std.testing.expectError(error.InvalidRange, s.addInterval(c, .focus, 100, 50, 13_000));
    try std.testing.expectError(error.InvalidRange, s.addInterval(c, .focus, 12_000, 14_000, 13_000));
    try std.testing.expectError(error.UnknownTask, s.addInterval(99, .focus, 0, 100, 13_000));

    try std.testing.expectError(error.OpenEnd, s.deleteInterval(3, .{ .start_ms = 9_500, .end_ms = null }, 13_000));
    try s.deleteInterval(added, .{ .start_ms = 9_000, .end_ms = 9_500 }, 13_000);
    try s.deleteInterval(1, .{ .start_ms = 1_500, .end_ms = 4_000 }, 13_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM notes"));
    try std.testing.expectError(error.UnknownInterval, s.deleteInterval(1, .{ .start_ms = 1_500, .end_ms = 4_000 }, 13_000));
}

test "an interval moves to another task with its notes, unless that task is busy then" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, null, 1_000);
    _ = try s.addNoteAt(1, 2_000, "note", 2_500);
    try std.testing.expectError(error.OpenEnd, s.moveInterval(1, .{ .start_ms = 1_000, .end_ms = null }, b, null, 3_000));
    _ = try s.switchTo(b, null, 5_000);
    try s.pause(6_000);
    // B already holds 5_000..6_000; A's 1_000..5_000 fits beside it.
    try std.testing.expectError(error.Stale, s.moveInterval(1, .{ .start_ms = 1_000, .end_ms = 4_000 }, b, null, 7_000));
    try std.testing.expectError(error.UnknownTask, s.moveInterval(1, .{ .start_ms = 1_000, .end_ms = 5_000 }, 99, null, 7_000));
    _ = try s.moveInterval(1, .{ .start_ms = 1_000, .end_ms = 5_000 }, b, null, 7_000);
    try std.testing.expectEqual(b, try testScalar(&db, "SELECT task_id FROM intervals WHERE id=1"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM notes WHERE interval_id=1"));
    try std.testing.expectEqual(@as(i64, 7_000), try testScalar(&db, "SELECT edited_ms FROM day_edits WHERE day='1970-01-01'"));
    // A parallel interval of A over B's time cannot move to B.
    const par = try s.addInterval(a, .parallel, 5_200, 5_800, 8_000);
    try std.testing.expectError(error.Overlap, s.moveInterval(par, .{ .start_ms = 5_200, .end_ms = 5_800 }, b, null, 9_000));
}

test "a part of an interval moves to another task, cutting it into pieces" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    const h: i64 = 3_600_000;
    const o: i64 = 10 * h; // A works o..o+4h; notes at +0:30, +1:30 and +3:30.
    var buf: [64]u8 = undefined;
    _ = try s.addInterval(a, .focus, o, o + 4 * h, o + 4 * h);
    _ = try s.addNoteAt(1, o + h / 2, "early", o + 5 * h);
    _ = try s.addNoteAt(1, o + h + h / 2, "middle", o + 5 * h);
    _ = try s.addNoteAt(1, o + 3 * h + h / 2, "late", o + 5 * h);
    const seen: Store.Span = .{ .start_ms = o, .end_ms = o + 4 * h };
    try std.testing.expectError(error.InvalidRange, s.moveInterval(1, seen, b, .{ .from = o + 5 * h, .to = o + 6 * h }, o + 5 * h));
    // Move +1h..+2h to B: A keeps o..+1h and +2h..+4h.
    const moved = try s.moveInterval(1, seen, b, .{ .from = o + h, .to = o + 2 * h }, o + 5 * h);
    try std.testing.expectEqual(@as(i64, 3), try testScalar(&db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(b, try testScalar(&db, try std.fmt.bufPrint(&buf, "SELECT task_id FROM intervals WHERE id={d}", .{moved})));
    try std.testing.expectEqual(3 * h, try testScalar(&db, "SELECT sum(end_ms-start_ms) FROM intervals WHERE task_id=1"));
    try std.testing.expectEqual(h, try testScalar(&db, "SELECT sum(end_ms-start_ms) FROM intervals WHERE task_id=2"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=2 AND n.text='middle'"));
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=1"));
    try std.testing.expectEqual(o + 2 * h, try testScalar(&db, "SELECT i.start_ms FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE n.text='late'"));
    // Moving the start of a piece keeps the row id for the moved part.
    try std.testing.expectEqual(@as(i64, 1), try s.moveInterval(1, .{ .start_ms = o, .end_ms = o + h }, b, .{ .from = o, .to = o + h / 4 }, o + 6 * h));
    try std.testing.expectEqual(b, try testScalar(&db, "SELECT task_id FROM intervals WHERE id=1"));
}

test "a task is deleted with its time, unless it is open or was posted" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    const c = try s.createTask("C", 3);
    _ = try s.switchTo(a, null, 1_000);
    _ = try s.addNoteAt(1, 2_000, "note", 2_500);
    try s.bindWithFields(a, "fake", "T-1", &.{.{ .name = "client", .value = "X" }}, 2_600);
    try std.testing.expectError(error.TaskOpen, s.deleteTask(a, 3_000));
    _ = try s.switchTo(b, null, 5_000);
    try s.pause(6_000);
    try s.deleteTask(a, 7_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM notes"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM task_bindings"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM task_fields"));
    try std.testing.expectEqual(@as(i64, 7_000), try testScalar(&db, "SELECT edited_ms FROM day_edits WHERE day='1970-01-01'"));
    // B is in the paused set; deleting it takes it out of the next resume.
    try s.deleteTask(b, 8_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM saved_set"));
    try std.testing.expectError(error.UnknownTask, s.deleteTask(b, 8_000));
    _ = try s.startPosting("2026-03-10", c, "fake", "T-3", "1", 1_000_000, 9_000, null);
    try std.testing.expectError(error.TaskHasPostings, s.deleteTask(c, 9_500));
}

test "end at last activity uses capture evidence and refuses other spans" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task_id = try s.createTask("Captured", 1);
    _ = try s.switchTo(task_id, null, 1000);
    try std.testing.expectError(error.InvalidState, s.endAtLastActivity(1, .{ .start_ms = 1000, .end_ms = null }, 5000));
    try db.exec("UPDATE intervals SET captured=1 WHERE id=1");
    try db.exec("INSERT INTO capture_runs(source,run,task_id,attended,working,lease_until_ms,started_ms) VALUES('test','one',1,1,1,999999,1000)");
    try db.exec("INSERT INTO capture_events(source,event,run,kind,at_ms) VALUES('test','a','one','prompt',2000),('test','b','one','busy',3500)");
    try db.exec("INSERT INTO notes(interval_id,at_ms,text,source) VALUES(1,3000,'prompt','prompt'),(1,4000,'outcome','outcome')");
    try std.testing.expectError(error.Stale, s.endAtLastActivity(1, .{ .start_ms = 999, .end_ms = null }, 5000));
    try s.endAtLastActivity(1, .{ .start_ms = 1000, .end_ms = null }, 5000);
    try std.testing.expectEqual(@as(i64, 4000), try testScalar(&db, "SELECT end_ms FROM intervals WHERE id=1"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT working FROM capture_runs WHERE run='one'"));
    try std.testing.expectError(error.InvalidState, s.endAtLastActivity(1, .{ .start_ms = 1000, .end_ms = 4000 }, 6000));
}

test "take focus splits a longer focus and moves its notes" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.addInterval(a, .focus, 1000, 5000, 5000);
    _ = try s.addInterval(b, .parallel, 2000, 4000, 5000);
    _ = try s.addNoteAt(1, 1500, "before", 5500);
    _ = try s.addNoteAt(1, 3000, "middle", 5500);
    _ = try s.addNoteAt(1, 4500, "after", 5500);
    try s.takeFocus(2, .{ .start_ms = 2000, .end_ms = 4000 }, 6000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='focus' AND start_ms=1000 AND end_ms=2000"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='parallel' AND start_ms=2000 AND end_ms=4000"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='focus' AND start_ms=4000 AND end_ms=5000"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE id=2 AND role='focus'"));
    try testText(&db, "SELECT group_concat(role||':'||text,',') FROM (SELECT i.role,n.text FROM notes n JOIN intervals i ON i.id=n.interval_id ORDER BY n.at_ms)", "focus:before,parallel:middle,focus:after");
    try std.testing.expectError(error.InvalidState, s.takeFocus(2, .{ .start_ms = 2000, .end_ms = 4000 }, 7000));
}

test "take focus accepts an open parallel interval and refuses posted overlap" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, null, 1000);
    _ = try s.openParallel(b, null, 2000);
    try db.exec("UPDATE intervals SET posting_span_id=1 WHERE id=1");
    try std.testing.expectError(error.InvalidState, s.takeFocus(2, .{ .start_ms = 2000, .end_ms = null }, 3000));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE id=1 AND role='focus' AND end_ms IS NULL"));
    try db.exec("UPDATE intervals SET posting_span_id=NULL WHERE id=1");
    try s.takeFocus(2, .{ .start_ms = 2000, .end_ms = null }, 3000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE id=2 AND role='focus' AND end_ms IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE id=1 AND role='parallel' AND start_ms=2000 AND end_ms IS NULL"));
}

test "merge joins one task's intervals and keeps every note's time" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, "one", 1_000);
    _ = try s.addNote(null, "early", 1_500);
    try s.pause(2_000);
    _ = try s.switchTo(a, "two", 3_000);
    try std.testing.expectError(error.Stale, s.mergeIntervals(1, .{ .start_ms = 1_000, .end_ms = 2_500 }, 2, .{ .start_ms = 3_000, .end_ms = null }, 4_000));
    try std.testing.expectError(error.NotMergeable, s.mergeIntervals(2, .{ .start_ms = 3_000, .end_ms = null }, 1, .{ .start_ms = 1_000, .end_ms = 2_000 }, 4_000));
    try s.mergeIntervals(1, .{ .start_ms = 1_000, .end_ms = 2_000 }, 2, .{ .start_ms = 3_000, .end_ms = null }, 4_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE id=1 AND end_ms IS NULL AND closed_by IS NULL"));
    try testText(&db, "SELECT group_concat(at_ms||':'||text,',') FROM (SELECT at_ms,text FROM notes WHERE interval_id=1 ORDER BY at_ms)", "1500:early,3000:two");

    _ = try s.switchTo(b, null, 5_000);
    _ = try s.switchTo(a, null, 6_000);
    try std.testing.expectError(error.NotMergeable, s.mergeIntervals(1, .{ .start_ms = 1_000, .end_ms = 5_000 }, 2, .{ .start_ms = 5_000, .end_ms = 6_000 }, 7_000));
    // The gap holds B's focus, so A cannot take it.
    try std.testing.expectError(error.Overlap, s.mergeIntervals(1, .{ .start_ms = 1_000, .end_ms = 5_000 }, 3, .{ .start_ms = 6_000, .end_ms = null }, 7_000));
}

test "notes at a time can be moved, edited and deleted inside their interval" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    _ = try s.switchTo(a, null, 1_000);
    const note = try s.addNoteAt(1, 1_200, "live", 2_000);
    try std.testing.expectError(error.NoteOutside, s.addNoteAt(1, 2_001, "future", 2_000));
    try std.testing.expectError(error.EmptyText, s.addNoteAt(1, 1_300, "", 2_000));
    try s.editNote(note, "changed", 1_900, 2_000);
    try testText(&db, "SELECT at_ms||text FROM notes", "1900changed");
    try s.editNote(note, "again", null, 2_000);
    try testText(&db, "SELECT at_ms||text FROM notes", "1900again");
    try std.testing.expectError(error.NoteOutside, s.editNote(note, "x", 500, 2_000));
    try s.deleteNote(note, 2_000);
    try std.testing.expectError(error.UnknownNote, s.deleteNote(note, 2_000));
    try std.testing.expectError(error.UnknownInterval, s.addNoteAt(9, 1_000, "x", 2_000));
}


test "captured runs share one focus and keep turns together" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const repo_a = try s.createTask("repo-a", 1);
    const repo_b = try s.createTask("repo-b", 2);
    const repo_c = try s.createTask("repo-c", 3);
    const issue = try s.createTask("issue", 4);
    const issue2 = try s.createTask("issue-2", 5);
    const min: i64 = 60_000;
    const Run = struct {
        s: *Store,
        base: Capture,
        last: *i64,
        /// Sends one event at minute `m`, with the daemon beating up to it.
        fn send(r: @This(), kind: CaptureKind, event: []const u8, m: f64, task: ?i64) !bool {
            const at: i64 = @intFromFloat(m * 60_000.0);
            while (r.last.* + 60_000 < at) {
                r.last.* += 60_000;
                try r.s.onHeartbeat(r.last.*);
            }
            r.last.* = at;
            var c = r.base;
            c.kind = kind;
            c.event = event;
            c.task = task;
            return r.s.capture(c, at);
        }
    };
    var last: i64 = 10;
    const A: Run = .{ .s = &s, .last = &last, .base = .{ .source = "claude", .run = "A", .kind = .start, .default_task = repo_a } };
    const B: Run = .{ .s = &s, .last = &last, .base = .{ .source = "claude", .run = "B", .kind = .start, .default_task = repo_b } };
    const C: Run = .{ .s = &s, .last = &last, .base = .{ .source = "claude", .run = "C", .kind = .start, .default_task = repo_c } };
    const D: Run = .{ .s = &s, .last = &last, .base = .{ .source = "bot", .run = "D", .kind = .start, .default_task = repo_c, .attended = false } };
    const open_focus = "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'";

    // A prompt takes the focus; a repeated event id changes nothing.
    try std.testing.expect(try A.send(.prompt, "a1", 1, null));
    try std.testing.expect(!try A.send(.prompt, "a1", 2, null));
    try std.testing.expectEqual(repo_a, try testScalar(&db, open_focus));
    // B's first prompt runs in parallel while A keeps focus.
    _ = try B.send(.prompt, "b1", 10, null);
    try std.testing.expectEqual(repo_a, try testScalar(&db, open_focus));
    try std.testing.expectEqual(repo_b, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    // A names its issue: its time moves there in its existing focus role.
    _ = try A.send(.subject, "a2", 12, issue);
    try std.testing.expectEqual(issue, try testScalar(&db, open_focus));
    try std.testing.expectEqual(repo_b, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    // B's turn ends; A's lease expires before B's next prompt, so B
    // takes the now-vacant focus and keeps its earlier parallel time.
    _ = try B.send(.stop, "b2", 20, null);
    _ = try B.send(.prompt, "b3", 23, null);
    _ = try B.send(.stop, "b4", 30, null);
    // Past the grace, B's interval ends where its last turn did.
    _ = try A.send(.busy, "a3", 36, null);
    var stmt_b = try db.prepare("SELECT count(*),max(end_ms) FROM intervals WHERE task_id=?1");
    defer stmt_b.finalize();
    try stmt_b.bindI64(1, repo_b);
    try std.testing.expectEqual(.row, try stmt_b.step());
    try std.testing.expectEqual(@as(i64, 2), stmt_b.columnI64(0));
    try std.testing.expectEqual(30 * min, stmt_b.columnI64(1));
    // A goes silent past its lease: the daemon's heartbeat alone closes it
    // where the lease ran out, with no other event arriving.
    while (last < (36 + 21) * min) {
        last += min;
        try s.onHeartbeat(last);
    }
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL"));
    _ = try C.send(.start, "c0", 36 + 22, null);
    try std.testing.expectEqual(36 * min + capture_lease_ms, try testScalar(&db, "SELECT max(end_ms) FROM intervals WHERE task_id=4"));
    // C names its issue seconds after its prompt: the short repo interval stays
    // (it is counted time); the report groups it away.
    _ = try C.send(.prompt, "c1", 60, null);
    _ = try C.send(.subject, "c2", 60.5, issue2);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=3 AND captured=1"));
    try std.testing.expectEqual(issue2, try testScalar(&db, open_focus));
    // An unattended run never takes the focus.
    _ = try D.send(.prompt, "d1", 61, null);
    try std.testing.expectEqual(issue2, try testScalar(&db, open_focus));
    try std.testing.expectEqual(repo_c, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    // A run's end closes it at once.
    _ = try C.send(.end, "c3", 70, null);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND role='focus'"));
}

fn captureWithHeartbeats(s: *Store, c: Capture, at: i64, last: *i64) !void {
    while (last.* + 60_000 < at) {
        last.* += 60_000;
        try s.onHeartbeat(last.*);
    }
    last.* = at;
    _ = try s.capture(c, at);
}

test "capture focus moves after ten minutes and splits notes at the first prompt" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 0);
    const y = try s.createTask("y", 0);
    const min: i64 = 60_000;
    var last: i64 = 0;
    const A: Capture = .{ .source = "agent", .run = "A", .kind = .prompt, .event = "a0", .default_task = x };
    var B: Capture = .{ .source = "agent", .run = "B", .kind = .prompt, .event = "b1", .default_task = y, .note = "first" };
    try captureWithHeartbeats(&s, A, 0, &last);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    for ([_]i64{ 1, 4, 8 }) |minute| {
        B.event = if (minute == 1) "b1" else if (minute == 4) "b4" else "b8";
        if (minute != 1) B.note = null;
        try captureWithHeartbeats(&s, B, minute * min, &last);
        try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
        try std.testing.expectEqual(y, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    }
    B.event = "b11";
    B.note = "latest";
    try captureWithHeartbeats(&s, B, 11 * min, &last);
    try std.testing.expectEqual(y, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='focus' AND start_ms=0 AND end_ms=60000"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='parallel' AND start_ms=60000 AND end_ms IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='focus' AND start_ms=60000 AND end_ms IS NULL"));
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=2 AND i.role='focus'"));
}

test "focus task prompt resets a competing capture stretch" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 0);
    const y = try s.createTask("y", 0);
    const min: i64 = 60_000;
    var last: i64 = 0;
    var A: Capture = .{ .source = "agent", .run = "A", .kind = .prompt, .event = "a0", .default_task = x };
    var B: Capture = .{ .source = "agent", .run = "B", .kind = .prompt, .event = "b1", .default_task = y };
    try captureWithHeartbeats(&s, A, 0, &last);
    try captureWithHeartbeats(&s, B, min, &last);
    B.event = "b4";
    try captureWithHeartbeats(&s, B, 4 * min, &last);
    A.event = "a6";
    try captureWithHeartbeats(&s, A, 6 * min, &last);
    B.event = "b8";
    try captureWithHeartbeats(&s, B, 8 * min, &last);
    B.event = "b11";
    try captureWithHeartbeats(&s, B, 11 * min, &last);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    B.event = "b18";
    try captureWithHeartbeats(&s, B, 18 * min, &last);
    try std.testing.expectEqual(y, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(8 * min, try testScalar(&db, "SELECT start_ms FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='focus'"));
}

test "manual focus changes immediately and posted overlap prevents capture promotion" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 0);
    const y = try s.createTask("y", 0);
    const min: i64 = 60_000;
    var last: i64 = 0;
    _ = try s.switchTo(x, null, 0);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try db.exec("UPDATE intervals SET posting_span_id=1 WHERE task_id=1");
    var B: Capture = .{ .source = "agent", .run = "B", .kind = .prompt, .event = "b1", .default_task = y };
    try captureWithHeartbeats(&s, B, min, &last);
    B.event = "b11";
    try captureWithHeartbeats(&s, B, 11 * min, &last);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(y, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
}

test "working holding source blocks sustained capture focus" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const game = try s.createTask("game", 0);
    const chat = try s.createTask("chat", 0);
    const min: i64 = 60_000;
    var last: i64 = 0;
    try s.setSetting("capture_hold_sources", "game", 0);
    var G: Capture = .{ .source = "game", .run = "G", .kind = .prompt, .event = "g0", .default_task = game };
    var C: Capture = .{ .source = "agent", .run = "C", .kind = .prompt, .event = "c1", .default_task = chat };
    try captureWithHeartbeats(&s, G, 0, &last);
    for ([_]i64{ 1, 11, 21, 31 }) |minute| {
        if (minute == 21 or minute == 31) {
            G.kind = .busy;
            G.event = if (minute == 21) "g19" else "g29";
            try captureWithHeartbeats(&s, G, (minute - 2) * min, &last);
        }
        C.event = if (minute == 1) "c1" else if (minute == 11) "c11" else if (minute == 21) "c21" else "c31";
        try captureWithHeartbeats(&s, C, minute * min, &last);
        try std.testing.expectEqual(game, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    }
}

test "capture prompts before naming a task do not sustain that task" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 0);
    const z = try s.createTask("z", 0);
    const y = try s.createTask("y", 0);
    _ = try s.switchTo(x, null, 0);
    var last: i64 = 0;
    var B: Capture = .{ .source = "agent", .run = "B", .kind = .prompt, .event = "b1", .default_task = z };
    try captureWithHeartbeats(&s, B, 60_000, &last);
    B.kind = .subject;
    B.event = "b2";
    B.task = y;
    try captureWithHeartbeats(&s, B, 2 * 60_000, &last);
    B.kind = .prompt;
    B.event = "b11";
    B.task = null;
    try captureWithHeartbeats(&s, B, 11 * 60_000, &last);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
}

test "capture promotes every project piece in a sustained stretch" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 0);
    const y = try s.createTask("y", 0);
    _ = try s.switchTo(x, null, 0);
    var last: i64 = 0;
    var B: Capture = .{ .source = "agent", .run = "B", .kind = .prompt, .event = "b1", .default_task = y, .project_key = "P", .project_hint = "P" };
    try captureWithHeartbeats(&s, B, 60_000, &last);
    B.event = "b4";
    B.project_key = "Q";
    B.project_hint = "Q";
    try captureWithHeartbeats(&s, B, 4 * 60_000, &last);
    B.event = "b11";
    try captureWithHeartbeats(&s, B, 11 * 60_000, &last);
    try std.testing.expectEqual(@as(i64, 2), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='focus' AND start_ms>=60000"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='parallel' AND start_ms>=60000"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='focus' AND start_ms=60000 AND end_ms=240000"));
}

test "holding source events reset a later sustained stretch" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const game = try s.createTask("game", 0);
    const chat = try s.createTask("chat", 0);
    try s.setSetting("capture_hold_sources", "game", 0);
    var last: i64 = 0;
    var G: Capture = .{ .source = "game", .run = "G", .kind = .prompt, .event = "g0", .default_task = game };
    var C: Capture = .{ .source = "agent", .run = "C", .kind = .prompt, .event = "c1", .default_task = chat };
    try captureWithHeartbeats(&s, G, 0, &last);
    try captureWithHeartbeats(&s, C, 60_000, &last);
    C.event = "c11";
    try captureWithHeartbeats(&s, C, 11 * 60_000, &last);
    G.kind = .stop;
    G.event = "g12";
    try captureWithHeartbeats(&s, G, 12 * 60_000, &last);
    C.event = "c13";
    try captureWithHeartbeats(&s, C, 13 * 60_000, &last);
    try std.testing.expectEqual(game, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    C.event = "c24";
    try captureWithHeartbeats(&s, C, 24 * 60_000, &last);
    try std.testing.expectEqual(chat, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(13 * 60_000, try testScalar(&db, "SELECT start_ms FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='focus'"));
}

test "first competing prompt at focus start counts without a focus prompt" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 0);
    const y = try s.createTask("y", 0);
    _ = try s.switchTo(x, null, 0);
    var last: i64 = 0;
    var B: Capture = .{ .source = "agent", .run = "B", .kind = .prompt, .event = "b0", .default_task = y };
    try captureWithHeartbeats(&s, B, 0, &last);
    // intervalTime nudges simultaneous writes by 1 ms; represent the exact
    // tie in the stored history before the second prompt arrives.
    try db.exec("UPDATE capture_events SET at_ms=0 WHERE event='b0'; UPDATE intervals SET start_ms=0 WHERE task_id=2");
    B.event = "b10";
    try captureWithHeartbeats(&s, B, 10 * 60_000, &last);
    try std.testing.expectEqual(y, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT start_ms FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='focus'"));
}

test "captured runs carry on across a restart and a short handoff" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("a", 1);
    const b = try s.createTask("b", 2);
    const min: i64 = 60_000;
    var A: Capture = .{ .source = "claude", .run = "A", .kind = .prompt, .default_task = a };
    var B: Capture = .{ .source = "claude", .run = "B", .kind = .prompt, .default_task = b };
    _ = try s.capture(A, 1 * min);
    try s.onHeartbeat(2 * min);
    // A daemon restart pauses everything; A's next tool use carries on.
    try s.pause(3 * min);
    A.kind = .busy;
    _ = try s.capture(A, 4 * min);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND end_ms IS NULL"));
    // B's short turn stays parallel; A's next prompt keeps its original focus.
    _ = try s.capture(B, 5 * min);
    B.kind = .stop;
    _ = try s.capture(B, 7 * min);
    A.kind = .prompt;
    _ = try s.capture(A, 8 * min);
    try std.testing.expectEqual(a, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=1 AND role='focus'"));
}

test "a holding source keeps the focus while its run works" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const game = try s.createTask("game", 1);
    const chat = try s.createTask("chat", 2);
    const min: i64 = 60_000;
    try s.setSetting("capture_hold_sources", "agent, game", 3);
    const focused = "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'";
    var G: Capture = .{ .source = "game", .run = "G", .kind = .prompt, .event = "g1", .default_task = game };
    _ = try s.capture(G, 1 * min);
    // Talking to an agent meanwhile runs in parallel.
    var C: Capture = .{ .source = "claude", .run = "C", .kind = .prompt, .event = "c1", .default_task = chat };
    _ = try s.capture(C, 2 * min);
    try std.testing.expectEqual(game, try testScalar(&db, focused));
    try std.testing.expectEqual(chat, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    // Once the game's run stops working, chat can build a sustained stretch.
    G.kind = .stop;
    G.event = "g2";
    _ = try s.capture(G, 3 * min);
    C.event = "c2";
    _ = try s.capture(C, 4 * min);
    try std.testing.expectEqual(game, try testScalar(&db, focused));
    // Without the setting, a later game prompt resets chat's stretch.
    try s.setSetting("capture_hold_sources", null, 5 * min);
    G.kind = .prompt;
    G.event = "g3";
    _ = try s.capture(G, 6 * min);
    C.event = "c3";
    _ = try s.capture(C, 7 * min);
    try std.testing.expectEqual(game, try testScalar(&db, focused));
    C.event = "c4";
    var last: i64 = 7 * min;
    try captureWithHeartbeats(&s, C, 17 * min, &last);
    try std.testing.expectEqual(chat, try testScalar(&db, focused));
}

test "captured prompts and outcomes become notes; manual focus outranks capture" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("a", 1);
    const manual = try s.createTask("manual", 2);
    const min: i64 = 60_000;
    var A: Capture = .{ .source = "claude", .run = "A", .kind = .prompt, .event = "p1", .default_task = a, .note = "  fix the login page\n" };
    _ = try s.capture(A, 1 * min);
    // A source may report along the way, as a game overlay does.
    A.kind = .busy;
    A.event = "b1";
    A.note = "tests pass";
    _ = try s.capture(A, 1 * min + 30_000);
    A.kind = .stop;
    A.event = "s1";
    A.note = "The login page is fixed.";
    _ = try s.capture(A, 2 * min);
    // A repeated event writes no second note.
    _ = try s.capture(A, 2 * min + 1000);
    try std.testing.expectEqual(@as(i64, 3), try testScalar(&db, "SELECT count(*) FROM notes"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM notes WHERE source='prompt' AND text='fix the login page'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM notes WHERE source='outcome'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM notes WHERE source IS NULL AND text='tests pass'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT captured FROM intervals WHERE task_id=1"));
    // The user switches by hand; a later prompt leaves that focus alone.
    _ = try s.switchTo(manual, null, 3 * min);
    A.kind = .prompt;
    A.event = "p2";
    A.note = null;
    _ = try s.capture(A, 4 * min);
    try std.testing.expectEqual(manual, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(a, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
}

test "time-only capture keeps intervals and uses a generic task title" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    try s.setSetting("capture_text", "time", 1);
    var c: Capture = .{ .source = "agent", .run = "r", .kind = .prompt, .first_prompt = "private text", .note = "prompt" };
    _ = try s.capture(c, 60_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    c.kind = .busy;
    c.note = "report";
    _ = try s.capture(c, 90_000);
    c.kind = .stop;
    c.note = "outcome";
    _ = try s.capture(c, 120_000);
    c.kind = .prompt;
    c.first_prompt = "Build the updated account page";
    _ = try s.capture(c, 150_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM notes"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM tasks WHERE title='Session'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE captured=1"));
}

test "session titles end at sentences or whole words" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const sentence = try s.sessionTitle("Review the account page. Then update the long explanation that follows the first sentence.");
    defer s.allocator.free(sentence);
    try std.testing.expectEqualStrings("Review the account page", sentence);
    const words = try s.sessionTitle("Review the account page and write a detailed explanation covering every case in the new flow");
    defer s.allocator.free(words);
    try std.testing.expectEqualStrings("Review the account page and write a detailed explanation...", words);
    const exact = try s.sessionTitle("A abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdef next");
    defer s.allocator.free(exact);
    try std.testing.expectEqualStrings("A abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdef...", exact);
    const long_word = try s.sessionTitle("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");
    defer s.allocator.free(long_word);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefgh...", long_word);
}

test "weak captured titles stay provisional until a useful prompt" {
    const weak = [_]struct { seed: []const u8, title: []const u8 }{
        .{ .seed = "two words", .title = "two words" },
        .{ .seed = "315", .title = "315" },
        .{ .seed = "#315", .title = "#315" },
        .{ .seed = "GO AHEAD!", .title = "GO AHEAD" },
        .{ .seed = "MANDA VER.", .title = "MANDA VER" },
    };
    for (weak) |case| {
        var db: sqlite.Db = .{};
        try db.open(":memory:");
        defer db.close();
        var s = try Store.init(&db, std.testing.allocator);
        var c: Capture = .{ .source = "agent", .run = "r", .kind = .start };
        _ = try s.capture(c, 1);
        c.kind = .prompt;
        c.first_prompt = case.seed;
        _ = try s.capture(c, 60_000);
        try testText(&db, "SELECT title FROM tasks WHERE id=1", case.title);
        try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
        c.first_prompt = "Build the updated account page";
        _ = try s.capture(c, 120_000);
        try testText(&db, "SELECT title FROM tasks WHERE id=1", "Build the updated account page");
        try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    }
}

test "captured title follows the first useful prompt but respects manual naming" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    var c: Capture = .{ .source = "agent", .run = "r", .kind = .start };
    _ = try s.capture(c, 1);
    c.kind = .prompt;
    _ = try s.capture(c, 60_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "Session");
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    c.first_prompt = "Build the updated account page";
    _ = try s.capture(c, 120_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "Build the updated account page");
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    c.first_prompt = "Review the account page changes";
    _ = try s.capture(c, 180_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "Build the updated account page");
}

test "manual task renames clear a provisional captured title" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    var c: Capture = .{ .source = "agent", .run = "r", .kind = .start };
    _ = try s.capture(c, 1);
    c.kind = .prompt;
    c.first_prompt = "yes";
    _ = try s.capture(c, 60_000);
    try s.updateTask(1, "Doctor", .omitted, 90_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    c.first_prompt = "Review the account page changes";
    _ = try s.capture(c, 120_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "Doctor");

    c = .{ .source = "agent", .run = "other", .kind = .prompt, .first_prompt = "ok" };
    _ = try s.capture(c, 180_000);
    try s.setTitle(2, "Nurse", 200_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='other'"));
    c.first_prompt = "Build the updated account page";
    _ = try s.capture(c, 240_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=2", "Nurse");
}

test "a subject moves a run away from its provisional title" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const chosen = try s.createTask("Doctor", 1);
    var c: Capture = .{ .source = "agent", .run = "r", .kind = .start };
    _ = try s.capture(c, 2);
    c.kind = .prompt;
    c.first_prompt = "yes";
    _ = try s.capture(c, 60_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    c.kind = .subject;
    c.task = chosen;
    _ = try s.capture(c, 90_000);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT provisional_title FROM capture_runs WHERE run='r'"));
    c.kind = .prompt;
    c.task = null;
    c.first_prompt = "Build the updated account page";
    _ = try s.capture(c, 120_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "Doctor");
    try testText(&db, "SELECT title FROM tasks WHERE id=2", "yes");
}

test "an existing subject task keeps its title on later prompts" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("yes", 1);
    var c: Capture = .{ .source = "agent", .run = "r", .kind = .subject, .task = task };
    _ = try s.capture(c, 60_000);
    c.kind = .prompt;
    c.task = null;
    c.first_prompt = "Build the updated account page";
    _ = try s.capture(c, 120_000);
    try testText(&db, "SELECT title FROM tasks WHERE id=1", "yes");
}

test "removing captured text preserves plain notes and intervals" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("work", 1);
    var c: Capture = .{ .source = "agent", .run = "r", .kind = .prompt, .default_task = task, .note = "prompt" };
    _ = try s.capture(c, 60_000);
    c.kind = .busy;
    c.note = "plain";
    _ = try s.capture(c, 90_000);
    c.kind = .stop;
    c.note = "outcome";
    _ = try s.capture(c, 120_000);
    try std.testing.expectEqual(@as(i64, 1), try s.removeCapturedText(0, 120_000, false, 130_000));
    try std.testing.expectEqual(@as(i64, 3), try testScalar(&db, "SELECT count(*) FROM notes"));
    try std.testing.expectEqual(@as(i64, 1), try s.removeCapturedText(0, 120_000, true, 130_000));
    try std.testing.expectEqual(@as(i64, 1), try s.removeCapturedText(120_000, 180_000, true, 140_000));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM notes WHERE source IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE captured=1"));
}


test "capture closes shared work at the last leave and leaves manual intervals alone" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 1);
    const m = try s.createTask("manual", 2);
    const min: i64 = 60_000;
    // A stops at 3, B ends at 5, A's grace runs out later: the work ends at 5.
    var A: Capture = .{ .source = "claude", .run = "A", .kind = .prompt, .event = "a1", .default_task = x };
    var B: Capture = .{ .source = "claude", .run = "B", .kind = .prompt, .event = "b1", .default_task = x };
    _ = try s.capture(A, 1 * min);
    _ = try s.capture(B, 2 * min);
    A.kind = .stop;
    A.event = "a2";
    _ = try s.capture(A, 3 * min);
    B.kind = .end;
    B.event = "b2";
    _ = try s.capture(B, 5 * min);
    try s.onHeartbeat(9 * min);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL"));
    try std.testing.expectEqual(5 * min, try testScalar(&db, "SELECT max(end_ms) FROM intervals WHERE task_id=1"));
    // A run on a task tracked by hand neither closes nor carries on the user's interval.
    _ = try s.switchTo(m, null, 10 * min);
    var C: Capture = .{ .source = "claude", .run = "C", .kind = .prompt, .event = "c1", .default_task = m };
    _ = try s.capture(C, 11 * min);
    C.kind = .end;
    C.event = "c2";
    _ = try s.capture(C, 12 * min);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND end_ms IS NULL AND captured=0"));
    try s.stop(m, 13 * min);
    const D: Capture = .{ .source = "claude", .run = "D", .kind = .prompt, .event = "d1", .default_task = m };
    _ = try s.capture(D, 14 * min);
    try std.testing.expectEqual(13 * min, try testScalar(&db, "SELECT end_ms FROM intervals WHERE task_id=2 AND captured=0"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND end_ms IS NULL AND captured=1"));
}

test "capture: subjects on any event, roles that stick, and grace that ends at the turn" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 1);
    const y = try s.createTask("y", 2);
    const z = try s.createTask("z", 3);
    const min: i64 = 60_000;
    const open_focus = "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'";
    // A subject sent with a prompt records time on that task.
    var R: Capture = .{ .source = "claude", .run = "R", .kind = .prompt, .event = "r1", .task = y };
    _ = try s.capture(R, 1 * min);
    try std.testing.expectEqual(y, try testScalar(&db, open_focus));
    R.kind = .end;
    R.event = "r2";
    R.task = null;
    _ = try s.capture(R, 2 * min);
    // A prompt held back by a holding source stays parallel after the holder leaves.
    try s.setSetting("capture_hold_sources", "game", 3 * min);
    var G: Capture = .{ .source = "game", .run = "G", .kind = .prompt, .event = "g1", .default_task = x };
    _ = try s.capture(G, 3 * min);
    var A: Capture = .{ .source = "claude", .run = "A", .kind = .prompt, .event = "a1", .default_task = y };
    _ = try s.capture(A, 4 * min);
    try std.testing.expectEqual(x, try testScalar(&db, open_focus));
    G.kind = .end;
    G.event = "g2";
    _ = try s.capture(G, 5 * min);
    var B: Capture = .{ .source = "claude", .run = "B", .kind = .prompt, .event = "b1", .default_task = z };
    _ = try s.capture(B, 6 * min);
    A.kind = .busy;
    A.event = "a2";
    _ = try s.capture(A, 7 * min);
    try std.testing.expectEqual(z, try testScalar(&db, open_focus));
    // B's turn ends at 8; A's prompt at 10 is still parallel.
    B.kind = .stop;
    B.event = "b2";
    _ = try s.capture(B, 8 * min);
    A.kind = .prompt;
    A.event = "a3";
    _ = try s.capture(A, 10 * min);
    try std.testing.expectEqual(z, try testScalar(&db, open_focus));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=3 AND end_ms IS NULL"));
}

test "capture: a grace handoff keeps a later end, and an unattended prompt naming a task stays parallel" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const x = try s.createTask("x", 1);
    const y = try s.createTask("y", 2);
    const min: i64 = 60_000;
    // A stops on x at 3, B ends on x at 5, C's short prompt stays parallel.
    var A: Capture = .{ .source = "claude", .run = "A", .kind = .prompt, .event = "a1", .default_task = x };
    var B: Capture = .{ .source = "claude", .run = "B", .kind = .prompt, .event = "b1", .default_task = x };
    _ = try s.capture(A, 1 * min);
    _ = try s.capture(B, 2 * min);
    A.kind = .stop;
    A.event = "a2";
    _ = try s.capture(A, 3 * min);
    B.kind = .end;
    B.event = "b2";
    _ = try s.capture(B, 5 * min);
    const C: Capture = .{ .source = "claude", .run = "C", .kind = .prompt, .event = "c1", .default_task = y };
    _ = try s.capture(C, 6 * min);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    // A focused run whose unattended prompt names a new task works there in parallel.
    const z = try s.createTask("z", 3);
    var R: Capture = .{ .source = "claude", .run = "R", .kind = .prompt, .event = "r1", .default_task = x };
    _ = try s.capture(R, 7 * min);
    try std.testing.expectEqual(x, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    R.event = "r2";
    R.task = z;
    R.attended = false;
    _ = try s.capture(R, 8 * min);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=3 AND end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=3 AND end_ms IS NULL AND role='parallel'"));
}

test "take focus keeps capture roles in step" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const a = try s.createTask("A", 1);
    const b = try s.createTask("B", 2);
    _ = try s.switchTo(a, null, 1000);
    _ = try s.openParallel(b, null, 2000);
    try db.exec("INSERT INTO capture_runs(source,run,task_id,attended,working,role,lease_until_ms,started_ms) VALUES('t','ra',1,1,1,'focus',999999,1000),('t','rb',2,1,1,'parallel',999999,2000)");
    try s.takeFocus(2, .{ .start_ms = 2000, .end_ms = null }, 3000);
    try testText(&db, "SELECT group_concat(run||':'||role,',') FROM (SELECT run,role FROM capture_runs ORDER BY run)", "ra:parallel,rb:focus");
}

test "take focus refuses an empty span and keeps the demoted part's end reason" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const c = try s.createTask("C", 3);
    const d = try s.createTask("D", 4);
    _ = try s.addInterval(c, .focus, 10_000, 15_000, 16_000);
    try db.exec("UPDATE intervals SET closed_by='stop' WHERE task_id=1");
    _ = try s.addInterval(d, .parallel, 12_000, 13_000, 16_000);
    try db.exec("UPDATE intervals SET end_ms=12000 WHERE task_id=2");
    try std.testing.expectError(error.InvalidState, s.takeFocus(try testScalar(&db, "SELECT id FROM intervals WHERE task_id=2"), .{ .start_ms = 12_000, .end_ms = 12_000 }, 17_000));
    try db.exec("UPDATE intervals SET end_ms=16000 WHERE task_id=2");
    try s.takeFocus(try testScalar(&db, "SELECT id FROM intervals WHERE task_id=2"), .{ .start_ms = 12_000, .end_ms = 16_000 }, 17_000);
    try testText(&db, "SELECT closed_by FROM intervals WHERE task_id=1 AND role='parallel'", "stop");
}

test "holding source start takes focus over a working run" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const background = try s.createTask("background", 0);
    const held = try s.createTask("held", 0);
    try s.setSetting("capture_hold_sources", "overlay", 0);
    const agent: Capture = .{ .source = "agent", .run = "a", .kind = .prompt, .default_task = background };
    _ = try s.capture(agent, 1_000);
    const holder: Capture = .{ .source = "overlay", .run = "h", .kind = .start, .default_task = held, .attended = false };
    _ = try s.capture(holder, 2_000);
    try std.testing.expectEqual(held, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(background, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    var pulse = agent;
    pulse.kind = .busy;
    _ = try s.capture(pulse, 3_000);
    try std.testing.expectEqual(held, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
}

test "holding source keeps focus through subject and busy" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const first = try s.createTask("first", 0);
    const second = try s.createTask("second", 0);
    try s.setSetting("capture_hold_sources", "overlay", 0);
    var holder: Capture = .{ .source = "overlay", .run = "h", .kind = .prompt, .default_task = first, .attended = false };
    _ = try s.capture(holder, 1_000);
    holder.kind = .subject;
    holder.task = second;
    _ = try s.capture(holder, 2_000);
    try std.testing.expectEqual(second, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    holder.kind = .busy;
    holder.task = null;
    _ = try s.capture(holder, 3_000);
    _ = try s.capture(holder, 4_000);
    try std.testing.expectEqual(second, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='parallel'"));
}

test "holding source promotes its open parallel interval" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const background = try s.createTask("background", 0);
    const held = try s.createTask("held", 0);
    const agent: Capture = .{ .source = "agent", .run = "a", .kind = .prompt, .default_task = background };
    _ = try s.capture(agent, 1_000);
    var holder: Capture = .{ .source = "overlay", .run = "h", .kind = .prompt, .default_task = held, .attended = false };
    _ = try s.capture(holder, 2_000);
    const id = try testScalar(&db, "SELECT id FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='parallel'");
    try s.setSetting("capture_hold_sources", "overlay", 3_000);
    holder.kind = .busy;
    _ = try s.capture(holder, 4_000);
    try std.testing.expectEqual(id, try testScalar(&db, "SELECT id FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='parallel'"));
    try std.testing.expectEqual(background, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
}

test "holding promotion splits a simultaneous project change" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const background = try s.createTask("background", 0);
    const held = try s.createTask("held", 0);
    const agent: Capture = .{ .source = "agent", .run = "a", .kind = .prompt, .default_task = background };
    _ = try s.capture(agent, 1_000);
    var holder: Capture = .{ .source = "overlay", .run = "h", .kind = .prompt, .default_task = held, .attended = false, .project_key = "P", .project_hint = "P" };
    _ = try s.capture(holder, 2_000);
    const first_id = try testScalar(&db, "SELECT id FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='parallel'");
    const first_project = try testScalar(&db, "SELECT project_id FROM intervals WHERE task_id=2 AND end_ms IS NULL");
    try s.setSetting("capture_hold_sources", "overlay", 3_000);
    holder.kind = .busy;
    holder.project_key = "Q";
    holder.project_hint = "Q";
    _ = try s.capture(holder, 4_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='focus' AND start_ms=2000 AND end_ms=4000"));
    try std.testing.expectEqual(first_project, try testScalar(&db, "SELECT project_id FROM intervals WHERE task_id=2 AND end_ms=4000"));
    const second_id = try testScalar(&db, "SELECT id FROM intervals WHERE task_id=2 AND end_ms IS NULL AND role='focus'");
    try std.testing.expect(second_id != first_id);
    try std.testing.expectEqual(@as(i64, 4_000), try testScalar(&db, "SELECT start_ms FROM intervals WHERE task_id=2 AND end_ms IS NULL"));
    try std.testing.expect(first_project != try testScalar(&db, "SELECT project_id FROM intervals WHERE task_id=2 AND end_ms IS NULL"));
    try std.testing.expectEqual(first_id, try testScalar(&db, "SELECT posting_span_id FROM intervals WHERE task_id=2 AND end_ms IS NULL"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT count(*) FROM intervals WHERE task_id=2 AND role='parallel'"));
}

test "holding subject defers a project change during idle grace" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("held", 0);
    var holder: Capture = .{ .source = "overlay", .run = "h", .kind = .prompt, .default_task = task, .attended = false, .project_key = "P", .project_hint = "P" };
    _ = try s.capture(holder, 1_000);
    const first_id = try testScalar(&db, "SELECT id FROM intervals WHERE end_ms IS NULL AND role='parallel'");
    const first_project = try testScalar(&db, "SELECT project_id FROM intervals WHERE end_ms IS NULL");
    holder.kind = .stop;
    _ = try s.capture(holder, 2_000);
    try s.setSetting("capture_hold_sources", "overlay", 2_000);
    holder.kind = .subject;
    holder.task = task;
    holder.project_key = "Q";
    holder.project_hint = "Q";
    _ = try s.capture(holder, 3_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals"));
    try std.testing.expectEqual(first_project, try testScalar(&db, "SELECT project_id FROM intervals WHERE end_ms IS NULL"));
    holder.kind = .busy;
    holder.task = null;
    holder.project_key = null;
    holder.project_hint = null;
    _ = try s.capture(holder, 4_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT count(*) FROM intervals WHERE role='focus' AND end_ms=4000"));
    try std.testing.expectEqual(first_project, try testScalar(&db, "SELECT project_id FROM intervals WHERE end_ms=4000"));
    try std.testing.expectEqual(@as(i64, 4_000), try testScalar(&db, "SELECT start_ms FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expect(first_project != try testScalar(&db, "SELECT project_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
    try std.testing.expectEqual(first_id, try testScalar(&db, "SELECT posting_span_id FROM intervals WHERE end_ms IS NULL AND role='focus'"));
}

test "inactive nonholding busy ignores a stored focus role" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var s = try Store.init(&db, std.testing.allocator);
    const task = try s.createTask("task", 0);
    var run: Capture = .{ .source = "agent", .run = "a", .kind = .start, .default_task = task };
    _ = try s.capture(run, 1_000);
    try db.exec("UPDATE capture_runs SET role='focus' WHERE source='agent' AND run='a'");
    run.kind = .busy;
    _ = try s.capture(run, 2_000);
    try std.testing.expectEqual(task, try testScalar(&db, "SELECT task_id FROM intervals WHERE end_ms IS NULL AND role='parallel'"));
    try testText(&db, "SELECT role FROM capture_runs WHERE source='agent' AND run='a'", "parallel");
}
