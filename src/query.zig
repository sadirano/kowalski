//! Read-only views over the store for the API. Mutations stay in store.zig.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

pub const Task = struct {
    id: i64,
    title: []const u8,
    ref: ?[]const u8 = null,
};

fn dupeOpt(a: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try a.dupe(u8, v) else null;
}

const task_columns = "t.id,t.title,(SELECT external_ref FROM task_bindings b WHERE b.task_id=t.id)";

fn readTask(a: std.mem.Allocator, stmt: *sqlite.Statement, first: c_int) !Task {
    return .{
        .id = stmt.columnI64(first),
        .title = try a.dupe(u8, stmt.columnText(first + 1).?),
        .ref = try dupeOpt(a, stmt.columnText(first + 2)),
    };
}

pub fn task(store: *Store, a: std.mem.Allocator, id: i64) !?Task {
    var stmt = try store.db.prepare("SELECT " ++ task_columns ++ " FROM tasks t WHERE t.id=?1");
    defer stmt.finalize();
    try stmt.bindI64(1, id);
    if (try stmt.step() == .done) return null;
    return try readTask(a, &stmt, 0);
}

pub const Resolution = union(enum) {
    found: i64,
    none,
    ambiguous: []Task,
};

/// `#N` names a kowalski id. Other text matches an external ref exactly, then
/// a title ignoring ASCII case. Several matches at the same step are ambiguous.
pub fn resolve(store: *Store, a: std.mem.Allocator, text: []const u8) !Resolution {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return .none;
    if (trimmed[0] == '#') {
        const id = std.fmt.parseInt(i64, trimmed[1..], 10) catch return .none;
        return if (try task(store, a, id) != null) .{ .found = id } else .none;
    }
    const steps = [_][]const u8{
        "SELECT " ++ task_columns ++ " FROM tasks t JOIN task_bindings k ON k.task_id=t.id WHERE k.external_ref=?1 ORDER BY t.id LIMIT 20",
        "SELECT " ++ task_columns ++ " FROM tasks t WHERE t.title=?1 COLLATE NOCASE ORDER BY t.id LIMIT 20",
    };
    for (steps) |sql| {
        var stmt = try store.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, trimmed);
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
        try rows.append(a, .{ .id = t.id, .title = t.title, .ref = t.ref, .last_ms = if (stmt.columnIsNull(3)) null else stmt.columnI64(3) });
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

pub const Note = struct { id: i64, at_ms: i64, text: []const u8 };

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
};

fn notesOf(store: *Store, a: std.mem.Allocator, interval: i64) ![]Note {
    var stmt = try store.db.prepare("SELECT id,at_ms,text FROM notes WHERE interval_id=?1 ORDER BY at_ms,id");
    defer stmt.finalize();
    try stmt.bindI64(1, interval);
    var rows: std.ArrayList(Note) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .id = stmt.columnI64(0), .at_ms = stmt.columnI64(1), .text = try a.dupe(u8, stmt.columnText(2).?) });
    return rows.items;
}

const interval_select = "SELECT i.id,i.role,i.start_ms,i.end_ms,i.opened_by,i.closed_by,i.text," ++ task_columns ++ " FROM intervals i JOIN tasks t ON t.id=i.task_id ";

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
pub fn intervalsBetween(store: *Store, a: std.mem.Allocator, start_ms: i64, end_ms: i64) ![]Interval {
    var stmt = try store.db.prepare(interval_select ++ "WHERE i.start_ms<?1 AND (i.end_ms IS NULL OR i.end_ms>?2 OR i.start_ms>=?2) ORDER BY i.start_ms, i.id");
    defer stmt.finalize();
    try stmt.bindI64(1, end_ms);
    try stmt.bindI64(2, start_ms);
    return readIntervals(store, a, &stmt);
}

pub const Saved = struct { task: Task, role: []const u8 };

pub fn savedSet(store: *Store, a: std.mem.Allocator) ![]Saved {
    var stmt = try store.db.prepare("SELECT s.role," ++ task_columns ++ " FROM saved_set s JOIN tasks t ON t.id=s.task_id ORDER BY s.role='parallel', t.id");
    defer stmt.finalize();
    var rows: std.ArrayList(Saved) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .role = try a.dupe(u8, stmt.columnText(0).?), .task = try readTask(a, &stmt, 1) });
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
    imported: bool,
    confirmed_ms: i64,
};

pub fn postedOn(store: *Store, a: std.mem.Allocator, day: []const u8, instance: []const u8, ref: []const u8) ![]Posted {
    var stmt = try store.db.prepare("SELECT amount_text,amount_micro,import_id IS NOT NULL,confirmed_ms FROM postings WHERE day=?1 AND provider_instance=?2 AND external_ref=?3 AND state='confirmed' ORDER BY confirmed_ms,id");
    defer stmt.finalize();
    try stmt.bindText(1, day);
    try stmt.bindText(2, instance);
    try stmt.bindText(3, ref);
    var rows: std.ArrayList(Posted) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{
        .amount_text = try a.dupe(u8, stmt.columnText(0).?),
        .amount_micro = stmt.columnI64(1),
        .imported = stmt.columnI64(2) != 0,
        .confirmed_ms = stmt.columnI64(3),
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

pub const Span = struct { start_ms: i64, end_ms: i64 };

pub const DayFocus = struct { spans: []Span, open_session: bool };

pub fn focusOnDay(store: *Store, a: std.mem.Allocator, task_id: i64, start_ms: i64, end_ms: i64) !DayFocus {
    var stmt = try store.db.prepare("SELECT start_ms,end_ms FROM intervals WHERE task_id=?1 AND role='focus' AND start_ms<?3 AND (end_ms IS NULL OR end_ms>?2) ORDER BY start_ms");
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
        if (first < last) try spans.append(a, .{ .start_ms = first, .end_ms = last });
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

pub const Found = struct { task: Task, snippet: ?[]const u8 };

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
        "OR EXISTS(SELECT 1 FROM intervals i WHERE i.task_id=t.id AND instr(lower(i.text),lower(?1))>0) " ++
        "OR EXISTS(SELECT 1 FROM notes n JOIN intervals i ON i.id=n.interval_id WHERE i.task_id=t.id AND instr(lower(n.text),lower(?1))>0) " ++
        "ORDER BY (SELECT max(start_ms) FROM intervals i WHERE i.task_id=t.id) IS NULL, (SELECT max(start_ms) FROM intervals i WHERE i.task_id=t.id) DESC, t.id DESC LIMIT ?2");
    defer stmt.finalize();
    try stmt.bindText(1, q);
    try stmt.bindI64(2, limit);
    var rows: std.ArrayList(Found) = .empty;
    while (try stmt.step() == .row) try rows.append(a, .{ .task = try readTask(a, &stmt, 0), .snippet = try dupeOpt(a, stmt.columnText(3)) });
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
    while (try stmt.step() == .row) try rows.append(a, .{ .task = try readTask(a, &stmt, 0), .focus_ms = stmt.columnI64(3) });
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
    try std.testing.expectEqual(Resolution{ .found = three }, try resolve(&store, a, "1234"));
    try std.testing.expectEqual(Resolution{ .found = one }, try resolve(&store, a, "#1"));
    try std.testing.expectEqual(Resolution{ .found = three }, try resolve(&store, a, " billing "));
    try std.testing.expectEqual(Resolution.none, try resolve(&store, a, "#99"));
    try std.testing.expectEqual(Resolution.none, try resolve(&store, a, "nothing"));
    const amb = try resolve(&store, a, "LOGIN page");
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
