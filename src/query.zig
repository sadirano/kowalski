//! Read-only views over the store for the API. Mutations stay in store.zig.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

pub const Task = struct {
    id: i64,
    title: []const u8,
    ref: ?[]const u8 = null,
    project_id: ?i64 = null,
    project_label: ?[]const u8 = null,
};

fn dupeOpt(a: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try a.dupe(u8, v) else null;
}

const task_columns = "t.id,t.title,(SELECT external_ref FROM task_bindings b WHERE b.task_id=t.id),t.project_id,(SELECT label FROM projects p WHERE p.id=t.project_id)";

fn readTask(a: std.mem.Allocator, stmt: *sqlite.Statement, first: c_int) !Task {
    return .{
        .id = stmt.columnI64(first),
        .title = try a.dupe(u8, stmt.columnText(first + 1).?),
        .ref = try dupeOpt(a, stmt.columnText(first + 2)),
        .project_id = if (stmt.columnIsNull(first + 3)) null else stmt.columnI64(first + 3),
        .project_label = try dupeOpt(a, stmt.columnText(first + 4)),
    };
}

pub fn task(store: *Store, a: std.mem.Allocator, id: i64) !?Task {
    var stmt = try store.db.prepare("SELECT " ++ task_columns ++ " FROM tasks t WHERE t.id=?1");
    defer stmt.finalize();
    try stmt.bindI64(1, id);
    if (try stmt.step() == .done) return null;
    return try readTask(a, &stmt, 0);
}

pub const CaptureTask = struct { id: i64, title: []const u8, ref: ?[]const u8 };
pub const CaptureRun = struct { source: []const u8, run: []const u8, task: ?CaptureTask, state: []const u8, last_ms: i64 };

pub fn captureRuns(store: *Store, a: std.mem.Allocator, now_ms: i64) ![]CaptureRun {
    var stmt = try store.db.prepare("SELECT source,run,task_id,working,idle_since_ms,(SELECT max(at_ms) FROM capture_events e WHERE e.source=r.source AND e.run=r.run) FROM capture_runs r WHERE ended_ms IS NULL AND lease_until_ms>=?1 AND (working=1 OR idle_since_ms IS NOT NULL) ORDER BY started_ms,source,run");
    defer stmt.finalize();
    try stmt.bindI64(1, now_ms);
    var rows: std.ArrayList(CaptureRun) = .empty;
    while (try stmt.step() == .row) {
        const last = if (stmt.columnIsNull(5)) 0 else stmt.columnI64(5);
        const found = if (stmt.columnIsNull(2)) null else try task(store, a, stmt.columnI64(2));
        try rows.append(a, .{
            .source = try a.dupe(u8, stmt.columnText(0).?),
            .run = try a.dupe(u8, stmt.columnText(1).?),
            .task = if (found) |t| .{ .id = t.id, .title = t.title, .ref = t.ref } else null,
            .state = if (stmt.columnI64(3) != 0) (if (last < now_ms - 5 * 60 * 1000) "quiet" else "working") else "idle",
            .last_ms = last,
        });
    }
    return rows.items;
}

pub const Project = struct { id: i64, label: []const u8, archived: bool };

fn readProject(a: std.mem.Allocator, stmt: *sqlite.Statement) !Project {
    return .{ .id = stmt.columnI64(0), .label = try a.dupe(u8, stmt.columnText(1).?), .archived = stmt.columnI64(2) != 0 };
}

pub fn project(store: *Store, a: std.mem.Allocator, id: i64) !?Project {
    var stmt = try store.db.prepare("SELECT id,label,archived FROM projects WHERE id=?1");
    defer stmt.finalize();
    try stmt.bindI64(1, id);
    return if (try stmt.step() == .row) try readProject(a, &stmt) else null;
}

pub fn projects(store: *Store, a: std.mem.Allocator, include_archived: bool) ![]Project {
    var stmt = try store.db.prepare("SELECT id,label,archived FROM projects WHERE ?1=1 OR archived=0 ORDER BY archived,label COLLATE NOCASE,id");
    defer stmt.finalize();
    try stmt.bindI64(1, @intFromBool(include_archived));
    var rows: std.ArrayList(Project) = .empty;
    while (try stmt.step() == .row) try rows.append(a, try readProject(a, &stmt));
    return rows.items;
}

pub const CaptureProjectKey = struct { source: []const u8, project_key: []const u8, project_hint: []const u8, project_id: i64 };

pub fn captureProjectKeys(store: *Store, a: std.mem.Allocator) ![]CaptureProjectKey {
    var stmt = try store.db.prepare("SELECT source,project_key,project_hint,project_id FROM capture_project_keys ORDER BY source,project_key");
    defer stmt.finalize();
    var rows: std.ArrayList(CaptureProjectKey) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .source = try a.dupe(u8, stmt.columnText(0).?), .project_key = try a.dupe(u8, stmt.columnText(1).?), .project_hint = try a.dupe(u8, stmt.columnText(2).?), .project_id = stmt.columnI64(3) });
    return rows.items;
}

fn wholeToken(text: []const u8, label: []const u8) bool {
    if (label.len == 0 or text.len < label.len) return false;
    for (0..text.len - label.len + 1) |i| {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + label.len], label)) continue;
        const before = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
        const after = i + label.len == text.len or !std.ascii.isAlphanumeric(text[i + label.len]);
        if (before and after) return true;
    }
    return false;
}

pub fn projectAssignmentPreview(store: *Store, a: std.mem.Allocator, scope: store_mod.AssignmentScope, target: ?i64) !store_mod.AssignmentPreview {
    var target_label: ?[]const u8 = null;
    if (target) |id| target_label = (try project(store, a, id) orelse return error.UnknownProject).label;
    const zone_setting = try store.getSetting("reporting_zone");
    defer if (zone_setting) |name| store.allocator.free(name);
    const zone_name = try a.dupe(u8, zone_setting orelse "UTC");
    const provider_setting = try store.getSetting("project_provider_field");
    defer if (provider_setting) |name| store.allocator.free(name);
    var stmt = try store.db.prepare("SELECT i.id,i.task_id,i.project_id,i.role,i.start_ms,i.end_ms,t.title FROM intervals i JOIN tasks t ON t.id=i.task_id ORDER BY i.id");
    defer stmt.finalize();
    var rows: std.ArrayList(store_mod.AssignmentRow) = .empty;
    var skipped: std.ArrayList(store_mod.AssignmentRow) = .empty;
    var selected_count: usize = 0;
    while (try stmt.step() == .row) {
        const id = stmt.columnI64(0);
        const task_id = stmt.columnI64(1);
        const old_project: ?i64 = if (stmt.columnIsNull(2)) null else stmt.columnI64(2);
        var reason: []const u8 = "selected";
        switch (scope) {
            .task_id => |want| {
                if (want != task_id) continue;
                reason = "task";
            },
            .interval_ids => |ids| {
                var chosen = false;
                for (ids) |want| if (want == id) { chosen = true; break; };
                if (!chosen) continue;
                selected_count += 1;
            },
            .unassigned_suggestions => {
                if (old_project != null or target_label == null) continue;
                const label = target_label.?;
                if (wholeToken(stmt.columnText(6).?, label)) {
                    reason = "title";
                } else if (provider_setting) |field| {
                    var field_stmt = try store.db.prepare("SELECT value FROM task_fields WHERE task_id=?1 AND name=?2");
                    defer field_stmt.finalize();
                    try field_stmt.bindI64(1, task_id);
                    try field_stmt.bindText(2, field);
                    if (try field_stmt.step() != .row or !wholeToken(field_stmt.columnText(0).?, label)) continue;
                    reason = "provider_field";
                } else continue;
            },
        }
        if (old_project == target) continue;
        const end_ms: ?i64 = if (stmt.columnIsNull(5)) null else stmt.columnI64(5);
        const role = try a.dupe(u8, stmt.columnText(3).?);
        const row: store_mod.AssignmentRow = .{
            .id = id, .task_id = task_id, .project_id = old_project,
            .role = role, .start_ms = stmt.columnI64(4), .end_ms = end_ms,
            .focus_ms = if (end_ms != null and std.mem.eql(u8, role, "focus")) end_ms.? - stmt.columnI64(4) else 0,
            .reason = reason,
        };
        if (end_ms == null) try skipped.append(a, row) else try rows.append(a, row);
    }
    if (scope == .interval_ids and selected_count != scope.interval_ids.len) return error.UnknownInterval;
    const z = try store.loadZone();
    const totals = try store_mod.assignmentTotals(a, rows.items, z);
    return .{ .snapshot = .{ .project_id = target, .intervals = rows.items, .totals = totals, .reporting_zone = zone_name, .day_start_min = z.day_start_min }, .skipped = skipped.items };
}

pub const ProjectTotal = struct { project_id: ?i64, label: []const u8, focus_ms: i64 };

pub fn projectTotalsBetween(store: *Store, a: std.mem.Allocator, start_ms: i64, end_ms: i64, now_ms: i64) ![]ProjectTotal {
    var stmt = try store.db.prepare("SELECT i.project_id,p.label,sum(min(coalesce(i.end_ms,?3),?2)-max(i.start_ms,?1)) FROM intervals i LEFT JOIN projects p ON p.id=i.project_id WHERE i.role='focus' AND i.start_ms<?2 AND coalesce(i.end_ms,?3)>?1 GROUP BY i.project_id ORDER BY p.label COLLATE NOCASE");
    defer stmt.finalize();
    try stmt.bindI64(1, start_ms);
    try stmt.bindI64(2, end_ms);
    try stmt.bindI64(3, now_ms);
    var rows: std.ArrayList(ProjectTotal) = .empty;
    var has_unassigned = false;
    while (try stmt.step() == .row) {
        const project_id: ?i64 = if (stmt.columnIsNull(0)) null else stmt.columnI64(0);
        if (project_id == null) has_unassigned = true;
        try rows.append(a, .{ .project_id = project_id, .label = try a.dupe(u8, stmt.columnText(1) orelse "Unassigned"), .focus_ms = stmt.columnI64(2) });
    }
    if (!has_unassigned) try rows.append(a, .{ .project_id = null, .label = "Unassigned", .focus_ms = 0 });
    return rows.items;
}

pub const Resolution = union(enum) {
    found: i64,
    none,
    ambiguous: []Task,
};

/// `#N` names a kowalski id. Other text matches an external ref exactly, then
/// a title ignoring ASCII case. Several matches at the same step are ambiguous.
pub fn resolve(store: *Store, a: std.mem.Allocator, text: []const u8, scope: ?i64) !Resolution {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return .none;
    if (trimmed[0] == '#') {
        const id = std.fmt.parseInt(i64, trimmed[1..], 10) catch return .none;
        return if (try task(store, a, id) != null) .{ .found = id } else .none;
    }
    const steps = [_][]const u8{
        "SELECT " ++ task_columns ++ " FROM tasks t JOIN task_bindings k ON k.task_id=t.id WHERE k.external_ref=?1 ORDER BY t.id LIMIT 20",
        "SELECT " ++ task_columns ++ " FROM tasks t WHERE t.title=?1 COLLATE NOCASE AND t.project_id IS ?2 ORDER BY t.id LIMIT 20",
    };
    for (steps, 0..) |sql, step| {
        var stmt = try store.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, trimmed);
        if (step == 1) {
            if (scope) |id| try stmt.bindI64(2, id) else try stmt.bindNull(2);
        }
        var found: std.ArrayList(Task) = .empty;
        while (try stmt.step() == .row) try found.append(a, try readTask(a, &stmt, 0));
        if (found.items.len == 1) return .{ .found = found.items[0].id };
        if (found.items.len > 1) return .{ .ambiguous = found.items };
    }
    return .none;
}

pub const TaskListing = struct {
    id: i64,
    title: []const u8,
    ref: ?[]const u8,
    project_id: ?i64 = null,
    project_label: ?[]const u8 = null,
    last_ms: ?i64,
};

/// Tasks by most recent activity; `q` filters title or ref by substring.
pub fn listTasks(store: *Store, a: std.mem.Allocator, q: ?[]const u8, limit: u32) ![]TaskListing {
    var stmt = try store.db.prepare(
        "SELECT " ++ task_columns ++ ",(SELECT max(start_ms) FROM intervals i WHERE i.task_id=t.id) AS last FROM tasks t " ++
            "WHERE ?1 IS NULL OR instr(lower(t.title),lower(?1))>0 OR EXISTS(SELECT 1 FROM task_bindings b WHERE b.task_id=t.id AND instr(lower(b.external_ref),lower(?1))>0) " ++
            "ORDER BY last IS NULL, last DESC, t.id DESC LIMIT ?2",
    );
    defer stmt.finalize();
    try stmt.bindOptionalText(1, q);
    try stmt.bindI64(2, limit);
    var rows: std.ArrayList(TaskListing) = .empty;
    while (try stmt.step() == .row) {
        const t = try readTask(a, &stmt, 0);
        try rows.append(a, .{ .id = t.id, .title = t.title, .ref = t.ref, .project_id = t.project_id, .project_label = t.project_label, .last_ms = if (stmt.columnIsNull(5)) null else stmt.columnI64(5) });
    }
    return rows.items;
}

pub const Field = struct { name: []const u8, value: []const u8 };

pub fn fields(store: *Store, a: std.mem.Allocator, task_id: i64) ![]Field {
    var stmt = try store.db.prepare("SELECT name,value FROM task_fields WHERE task_id=?1 ORDER BY name");
    defer stmt.finalize();
    try stmt.bindI64(1, task_id);
    var rows: std.ArrayList(Field) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .name = try a.dupe(u8, stmt.columnText(0).?), .value = try a.dupe(u8, stmt.columnText(1).?) });
    return rows.items;
}

/// `source`: "prompt" or "outcome" for one capture wrote from a turn; null otherwise
/// (written by hand, or a report a source sent along the way).
pub const Note = struct { id: i64, at_ms: i64, text: []const u8, source: ?[]const u8 = null };

pub const Interval = struct {
    id: i64,
    task: Task,
    role: []const u8,
    start_ms: i64,
    end_ms: ?i64,
    opened_by: []const u8,
    closed_by: ?[]const u8,
    text: ?[]const u8,
    notes: []Note,
    /// Opened by captured activity, not by hand: its focus is an estimate.
    captured: bool = false,
    project_id: ?i64 = null,
    project_label: ?[]const u8 = null,
    posting_span_id: ?i64 = null,
};

fn notesOf(store: *Store, a: std.mem.Allocator, interval: i64) ![]Note {
    var stmt = try store.db.prepare("SELECT id,at_ms,text,source FROM notes WHERE interval_id=?1 ORDER BY at_ms,id");
    defer stmt.finalize();
    try stmt.bindI64(1, interval);
    var rows: std.ArrayList(Note) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .id = stmt.columnI64(0), .at_ms = stmt.columnI64(1), .text = try a.dupe(u8, stmt.columnText(2).?), .source = try dupeOpt(a, stmt.columnText(3)) });
    return rows.items;
}

const interval_select = "SELECT i.id,i.role,i.start_ms,i.end_ms,i.opened_by,i.closed_by,i.text," ++ task_columns ++ ",i.captured,i.project_id,(SELECT label FROM projects p WHERE p.id=i.project_id),i.posting_span_id FROM intervals i JOIN tasks t ON t.id=i.task_id ";

fn readIntervals(store: *Store, a: std.mem.Allocator, stmt: *sqlite.Statement) ![]Interval {
    var rows: std.ArrayList(Interval) = .empty;
    while (try stmt.step() == .row) {
        try rows.append(a, .{
            .id = stmt.columnI64(0),
            .role = try a.dupe(u8, stmt.columnText(1).?),
            .start_ms = stmt.columnI64(2),
            .end_ms = if (stmt.columnIsNull(3)) null else stmt.columnI64(3),
            .opened_by = try a.dupe(u8, stmt.columnText(4).?),
            .closed_by = try dupeOpt(a, stmt.columnText(5)),
            .text = try dupeOpt(a, stmt.columnText(6)),
            .task = try readTask(a, stmt, 7),
            .notes = &.{},
            .captured = stmt.columnI64(12) == 1,
            .project_id = if (stmt.columnIsNull(13)) null else stmt.columnI64(13),
            .project_label = try dupeOpt(a, stmt.columnText(14)),
            .posting_span_id = if (stmt.columnIsNull(15)) null else stmt.columnI64(15),
        });
    }
    for (rows.items) |*row| row.notes = try notesOf(store, a, row.id);
    return rows.items;
}

/// Open intervals, focus first.
pub fn openIntervals(store: *Store, a: std.mem.Allocator) ![]Interval {
    var stmt = try store.db.prepare(interval_select ++ "WHERE i.end_ms IS NULL ORDER BY i.role='parallel', i.start_ms, i.id");
    defer stmt.finalize();
    return readIntervals(store, a, &stmt);
}

/// Intervals of any role that overlap [start, end), plus zero-length ones inside it.
/// The start and end of each interval overlapping [start, end), as
/// intervalsBetween orders them, without tasks or notes.
pub fn spansBetween(store: *Store, a: std.mem.Allocator, start_ms: i64, end_ms: i64) ![]OpenSpan {
    var stmt = try store.db.prepare("SELECT i.start_ms,i.end_ms FROM intervals i WHERE i.start_ms<?1 AND (i.end_ms IS NULL OR i.end_ms>?2 OR i.start_ms>=?2) ORDER BY i.start_ms, i.id");
    defer stmt.finalize();
    try stmt.bindI64(1, end_ms);
    try stmt.bindI64(2, start_ms);
    var rows: std.ArrayList(OpenSpan) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .start_ms = stmt.columnI64(0), .end_ms = if (stmt.columnIsNull(1)) null else stmt.columnI64(1) });
    return rows.items;
}

pub fn intervalsBetween(store: *Store, a: std.mem.Allocator, start_ms: i64, end_ms: i64) ![]Interval {
    var stmt = try store.db.prepare(interval_select ++ "WHERE i.start_ms<?1 AND (i.end_ms IS NULL OR i.end_ms>?2 OR i.start_ms>=?2) ORDER BY i.start_ms, i.id");
    defer stmt.finalize();
    try stmt.bindI64(1, end_ms);
    try stmt.bindI64(2, start_ms);
    return readIntervals(store, a, &stmt);
}

pub const Saved = struct { task: Task, role: []const u8, project_id: ?i64 = null, project_label: ?[]const u8 = null };

pub fn savedSet(store: *Store, a: std.mem.Allocator) ![]Saved {
    var stmt = try store.db.prepare("SELECT s.role," ++ task_columns ++ ",s.project_id,(SELECT label FROM projects p WHERE p.id=s.project_id) FROM saved_set s JOIN tasks t ON t.id=s.task_id ORDER BY s.role='parallel', t.id");
    defer stmt.finalize();
    var rows: std.ArrayList(Saved) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .role = try a.dupe(u8, stmt.columnText(0).?), .task = try readTask(a, &stmt, 1), .project_id = if (stmt.columnIsNull(6)) null else stmt.columnI64(6), .project_label = try dupeOpt(a, stmt.columnText(7)) });
    return rows.items;
}

pub const Setting = struct { key: []const u8, value: []const u8 };

pub fn settings(store: *Store, a: std.mem.Allocator) ![]Setting {
    var stmt = try store.db.prepare("SELECT key,value FROM settings ORDER BY key");
    defer stmt.finalize();
    var rows: std.ArrayList(Setting) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .key = try a.dupe(u8, stmt.columnText(0).?), .value = try a.dupe(u8, stmt.columnText(1).?) });
    return rows.items;
}

pub const Binding = struct { instance: []const u8, ref: []const u8 };

pub fn binding(store: *Store, a: std.mem.Allocator, task_id: i64) !?Binding {
    var stmt = try store.db.prepare("SELECT provider_instance,external_ref FROM task_bindings WHERE task_id=?1");
    defer stmt.finalize();
    try stmt.bindI64(1, task_id);
    if (try stmt.step() == .done) return null;
    return .{ .instance = try a.dupe(u8, stmt.columnText(0).?), .ref = try a.dupe(u8, stmt.columnText(1).?) };
}

pub fn taskOpen(store: *Store, task_id: i64) !bool {
    var stmt = try store.db.prepare("SELECT 1 FROM intervals WHERE task_id=?1 AND end_ms IS NULL LIMIT 1");
    defer stmt.finalize();
    try stmt.bindI64(1, task_id);
    return try stmt.step() == .row;
}

pub const Posted = struct {
    amount_text: []const u8,
    amount_micro: i64,
    confirmed_ms: i64,
};

pub fn postedOn(store: *Store, a: std.mem.Allocator, day: []const u8, instance: []const u8, ref: []const u8) ![]Posted {
    var stmt = try store.db.prepare("SELECT amount_text,amount_micro,confirmed_ms FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state='confirmed' ORDER BY confirmed_ms,id");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    try stmt.bindText(2, instance);
    try stmt.bindText(3, ref);
    var rows: std.ArrayList(Posted) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{
        .amount_text = try a.dupe(u8, stmt.columnText(0).?),
        .amount_micro = stmt.columnI64(1),
        .confirmed_ms = stmt.columnI64(2),
    });
    return rows.items;
}

pub const PostedFingerprint = struct { text: []const u8, in_flight: bool };

pub fn postedFingerprint(store: *Store, a: std.mem.Allocator, day: []const u8, instance: []const u8, ref: []const u8) !PostedFingerprint {
    var stmt = try store.db.prepare("SELECT coalesce(sum(CASE WHEN state='confirmed' THEN 1 ELSE 0 END),0),coalesce(sum(CASE WHEN state='confirmed' THEN amount_micro ELSE 0 END),0),coalesce(max(CASE WHEN state='confirmed' THEN id END),0),coalesce(max(CASE WHEN state IN ('sending','unknown') THEN 1 ELSE 0 END),0) FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state IN ('confirmed','sending','unknown')");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    try stmt.bindText(2, instance);
    try stmt.bindText(3, ref);
    if (try stmt.step() != .row) return error.Sqlite;
    const value = try std.fmt.allocPrint(a, "{d}:{d}:{d}", .{ stmt.columnI64(0), stmt.columnI64(1), stmt.columnI64(2) });
    return .{ .text = value, .in_flight = stmt.columnI64(3) != 0 };
}

pub const Posting = struct {
    id: i64,
    day: []const u8,
    task: i64,
    provider_instance: []const u8,
    external_ref: []const u8,
    state: []const u8,
    amount_text: []const u8,
    amount_micro: i64,
    provider_data: ?[]const u8,
    created_ms: i64,
    confirmed_ms: ?i64,
    covered_start_ms: ?i64,
    covered_end_ms: ?i64,
};

const posting_columns = "id,day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,provider_data,created_ms,confirmed_ms,covered_start_ms,covered_end_ms";

fn readPosting(a: std.mem.Allocator, stmt: *sqlite.Statement) !Posting {
    return .{
        .id = stmt.columnI64(0),
        .day = try a.dupe(u8, stmt.columnText(1).?),
        .task = stmt.columnI64(2),
        .provider_instance = try a.dupe(u8, stmt.columnText(3).?),
        .external_ref = try a.dupe(u8, stmt.columnText(4).?),
        .state = try a.dupe(u8, stmt.columnText(5).?),
        .amount_text = try a.dupe(u8, stmt.columnText(6).?),
        .amount_micro = stmt.columnI64(7),
        .provider_data = try dupeOpt(a, stmt.columnText(8)),
        .created_ms = stmt.columnI64(9),
        .confirmed_ms = if (stmt.columnIsNull(10)) null else stmt.columnI64(10),
        .covered_start_ms = if (stmt.columnIsNull(11)) null else stmt.columnI64(11),
        .covered_end_ms = if (stmt.columnIsNull(12)) null else stmt.columnI64(12),
    };
}

pub fn posting(store: *Store, a: std.mem.Allocator, id: i64) !?Posting {
    var stmt = try store.db.prepare("SELECT " ++ posting_columns ++ " FROM postings WHERE id=?1");
    defer stmt.finalize();
    try stmt.bindI64(1, id);
    if (try stmt.step() == .done) return null;
    return try readPosting(a, &stmt);
}

/// A day's postings, oldest first; `task` narrows to one task.
pub fn postingsOn(store: *Store, a: std.mem.Allocator, day: []const u8, task_id: ?i64) ![]Posting {
    var stmt = try store.db.prepare("SELECT " ++ posting_columns ++ " FROM postings WHERE day=?1 AND (?2 IS NULL OR task_id=?2) ORDER BY id");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    if (task_id) |t| try stmt.bindI64(2, t) else try stmt.bindNull(2);
    var list: std.ArrayList(Posting) = .empty;
    while (try stmt.step() == .row) try list.append(a, try readPosting(a, &stmt));
    return list.items;
}

pub const Span = struct { start_ms: i64, end_ms: i64, posting_span_id: ?i64 = null };

pub const DayFocus = struct { spans: []Span, open_session: bool };

pub fn focusOnDay(store: *Store, a: std.mem.Allocator, task_id: i64, start_ms: i64, end_ms: i64) !DayFocus {
    var stmt = try store.db.prepare("SELECT start_ms,end_ms,posting_span_id FROM intervals WHERE task_id=?1 AND role='focus' AND start_ms<?3 AND (end_ms IS NULL OR end_ms>?2) ORDER BY start_ms");
    defer stmt.finalize();
    try stmt.bindI64(1, task_id);
    try stmt.bindI64(2, start_ms);
    try stmt.bindI64(3, end_ms);
    var spans: std.ArrayList(Span) = .empty;
    var open = false;
    while (try stmt.step() == .row) {
        if (stmt.columnIsNull(1)) { open = true; continue; }
        const first = @max(start_ms, stmt.columnI64(0));
        const last = @min(end_ms, stmt.columnI64(1));
        if (first < last) try spans.append(a, .{ .start_ms = first, .end_ms = last, .posting_span_id = if (stmt.columnIsNull(2)) null else stmt.columnI64(2) });
    }
    return .{ .spans = spans.items, .open_session = open };
}

pub fn coverageOn(store: *Store, a: std.mem.Allocator, day: []const u8, instance: []const u8, ref: []const u8) ![]Span {
    var stmt = try store.db.prepare("SELECT covered_start_ms,covered_end_ms FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state IN ('confirmed','sending','unknown') AND covered_start_ms IS NOT NULL ORDER BY covered_start_ms");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    try stmt.bindText(2, instance);
    try stmt.bindText(3, ref);
    var spans: std.ArrayList(Span) = .empty;
    while (try stmt.step() == .row) try spans.append(a, .{ .start_ms = stmt.columnI64(0), .end_ms = stmt.columnI64(1) });
    return spans.items;
}

pub fn hasTotalPosting(store: *Store, day: []const u8, instance: []const u8, ref: []const u8) !bool {
    var stmt = try store.db.prepare("SELECT 1 FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state!='cancelled' AND covered_start_ms IS NULL LIMIT 1");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    try stmt.bindText(2, instance);
    try stmt.bindText(3, ref);
    return try stmt.step() == .row;
}

/// Lunch breaks overlapping [start, end); one still running ends at `now`.
pub fn lunchesBetween(store: *Store, a: std.mem.Allocator, start_ms: i64, end_ms: i64, now_ms: i64) ![]Span {
    var stmt = try store.db.prepare("SELECT out_ms,coalesce(back_ms,max(out_ms,?3)) FROM lunches WHERE out_ms<?1 AND coalesce(back_ms,?3)>=?2 ORDER BY out_ms");
    defer stmt.finalize();
    try stmt.bindI64(1, end_ms);
    try stmt.bindI64(2, start_ms);
    try stmt.bindI64(3, now_ms);
    var rows: std.ArrayList(Span) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .start_ms = stmt.columnI64(0), .end_ms = stmt.columnI64(1) });
    return rows.items;
}

pub fn lunchOpen(store: *Store) !bool {
    var stmt = try store.db.prepare("SELECT 1 FROM lunches WHERE back_ms IS NULL");
    defer stmt.finalize();
    return try stmt.step() == .row;
}

/// True when the day's history was edited after its latest confirmed posting.
pub fn changedAfterPosting(store: *Store, day: []const u8) !bool {
    var stmt = try store.db.prepare("SELECT 1 FROM day_edits e WHERE e.day=?1 AND e.edited_ms>(SELECT max(confirmed_ms) FROM postings p WHERE p.day=?1 AND p.state='confirmed')");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    return try stmt.step() == .row;
}

/// Tasks with a posting still in effect or awaiting its outcome that day.
pub fn postedTasks(store: *Store, a: std.mem.Allocator, day: []const u8) ![]i64 {
    var stmt = try store.db.prepare("SELECT DISTINCT task_id FROM postings WHERE day=?1 AND state IN ('confirmed','sending','unknown') ORDER BY task_id");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(a);
    while (try stmt.step() == .row) try ids.append(a, stmt.columnI64(0));
    return ids.toOwnedSlice(a);
}

pub const OpenSpan = struct { start_ms: i64, end_ms: ?i64 };

/// A task's focus intervals, oldest first.
pub fn focusSpans(store: *Store, a: std.mem.Allocator, task_id: i64) ![]OpenSpan {
    var stmt = try store.db.prepare("SELECT start_ms,end_ms FROM intervals WHERE task_id=?1 AND role='focus' ORDER BY start_ms");
    defer stmt.finalize();
    try stmt.bindI64(1, task_id);
    var rows: std.ArrayList(OpenSpan) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .start_ms = stmt.columnI64(0), .end_ms = if (stmt.columnIsNull(1)) null else stmt.columnI64(1) });
    return rows.items;
}

pub const ProjectRef = struct { project_id: ?i64, label: ?[]const u8 };
pub const Found = struct { task: Task, snippet: ?[]const u8, historical_projects: []ProjectRef };

fn historicalProjects(store: *Store, a: std.mem.Allocator, task_id: i64) ![]ProjectRef {
    var stmt = try store.db.prepare("SELECT DISTINCT i.project_id,p.label FROM intervals i LEFT JOIN projects p ON p.id=i.project_id WHERE i.task_id=?1 ORDER BY i.project_id");
    defer stmt.finalize();
    try stmt.bindI64(1, task_id);
    var rows: std.ArrayList(ProjectRef) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .project_id = if (stmt.columnIsNull(0)) null else stmt.columnI64(0), .label = try dupeOpt(a, stmt.columnText(1)) });
    return rows.items;
}

/// Tasks whose title, ref, field values, session text or notes contain `q`
/// (ASCII case ignored), most recently worked first. `snippet` is the first
/// matching note or session text.
pub fn search(store: *Store, a: std.mem.Allocator, q: []const u8, limit: u32) ![]Found {
    var stmt = try store.db.prepare("SELECT " ++ task_columns ++ "," ++
        "(SELECT text FROM (SELECT n.text AS text,n.at_ms AS at FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=t.id AND instr(lower(n.text),lower(?1))>0 " ++
        "UNION ALL SELECT i.text,i.start_ms FROM intervals i WHERE i.task_id=t.id AND instr(lower(i.text),lower(?1))>0) ORDER BY at DESC LIMIT 1) " ++
        "FROM tasks t WHERE instr(lower(t.title),lower(?1))>0 " ++
        "OR EXISTS(SELECT 1 FROM task_bindings b WHERE b.task_id=t.id AND instr(lower(b.external_ref),lower(?1))>0) " ++
        "OR EXISTS(SELECT 1 FROM task_fields f WHERE f.task_id=t.id AND instr(lower(f.value),lower(?1))>0) " ++
        "OR EXISTS(SELECT 1 FROM projects p WHERE p.id=t.project_id AND instr(lower(p.label),lower(?1))>0) " ++
        "OR EXISTS(SELECT 1 FROM intervals i JOIN projects p ON p.id=i.project_id WHERE i.task_id=t.id AND instr(lower(p.label),lower(?1))>0) " ++
        "OR EXISTS(SELECT 1 FROM intervals i WHERE i.task_id=t.id AND instr(lower(i.text),lower(?1))>0) " ++
        "OR EXISTS(SELECT 1 FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=t.id AND instr(lower(n.text),lower(?1))>0) " ++
        "ORDER BY (SELECT max(start_ms) FROM intervals i WHERE i.task_id=t.id) IS NULL, (SELECT max(start_ms) FROM intervals i WHERE i.task_id=t.id) DESC, t.id DESC LIMIT ?2");
    defer stmt.finalize();
    try stmt.bindText(1, q);
    try stmt.bindI64(2, limit);
    var rows: std.ArrayList(Found) = .empty;
    while (try stmt.step() == .row) {
        const t = try readTask(a, &stmt, 0);
        try rows.append(a, .{ .task = t, .snippet = try dupeOpt(a, stmt.columnText(5)), .historical_projects = try historicalProjects(store, a, t.id) });
    }
    return rows.items;
}

pub const Frequent = struct { task: Task, focus_ms: i64 };

/// Tasks with the most focus time since `since_ms`.
pub fn frequent(store: *Store, a: std.mem.Allocator, since_ms: i64, now_ms: i64, limit: u32) ![]Frequent {
    var stmt = try store.db.prepare("SELECT " ++ task_columns ++ ",x.ms FROM (SELECT task_id,sum(min(coalesce(end_ms,?1),?1)-max(start_ms,?2)) AS ms FROM intervals WHERE role='focus' AND coalesce(end_ms,?1)>?2 GROUP BY task_id) x JOIN tasks t ON t.id=x.task_id WHERE x.ms>0 ORDER BY x.ms DESC LIMIT ?3");
    defer stmt.finalize();
    try stmt.bindI64(1, now_ms);
    try stmt.bindI64(2, since_ms);
    try stmt.bindI64(3, limit);
    var rows: std.ArrayList(Frequent) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .task = try readTask(a, &stmt, 0), .focus_ms = stmt.columnI64(5) });
    return rows.items;
}

test "resolve by id, ref and title" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try Store.init(&db, std.testing.allocator);
    const one = try store.createTask("Login page", 1);
    const two = try store.createTask("login PAGE", 2);
    const three = try store.createTask("Billing", 3);
    try store.bind(three, "p", "1234", 4);
    try std.testing.expectEqual(Resolution{ .found = three }, try resolve(&store, a, "1234", null));
    try std.testing.expectEqual(Resolution{ .found = one }, try resolve(&store, a, "#1", null));
    try std.testing.expectEqual(Resolution{ .found = three }, try resolve(&store, a, " billing ", null));
    try std.testing.expectEqual(Resolution.none, try resolve(&store, a, "#99", null));
    try std.testing.expectEqual(Resolution.none, try resolve(&store, a, "nothing", null));
    const amb = try resolve(&store, a, "LOGIN page", null);
    try std.testing.expectEqual(@as(usize, 2), amb.ambiguous.len);
    try std.testing.expectEqual(two, amb.ambiguous[1].id);
}

test "listing orders by recent activity and filters" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try Store.init(&db, std.testing.allocator);
    const one = try store.createTask("Alpha", 1);
    const two = try store.createTask("Beta", 2);
    _ = try store.createTask("Gamma", 3);
    _ = try store.switchTo(two, null, 10);
    _ = try store.switchTo(one, null, 20);
    const rows = try listTasks(&store, a, null, 10);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(one, rows[0].id);
    try std.testing.expectEqual(two, rows[1].id);
    try std.testing.expectEqual(@as(?i64, null), rows[2].last_ms);
    const filtered = try listTasks(&store, a, "ET", 10);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    const open = try openIntervals(&store, a);
    try std.testing.expectEqual(@as(usize, 1), open.len);
    try std.testing.expectEqualStrings("Alpha", open[0].task.title);
}
