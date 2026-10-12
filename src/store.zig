const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const zone = @import("zone.zig");

pub const Error = error{
    Sqlite,
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
    EmptyText,
    InvalidState,
    PostingBlocked,
    InvalidSetting,
    InvalidTime,
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
};

/// Times outside [0, max_time_ms) (years 1970..9999) are refused.
pub const max_time_ms: i64 = 253_402_300_800_000;

pub const Role = enum { focus, parallel };
pub const OpenedBy = enum { @"switch", parallel, @"resume", import };
pub const ClosedBy = enum { @"switch", pause, stop, recovered, import };
pub const PostingState = enum { sending, confirmed, unknown, cancelled };

fn sqlText(value: anytype) []const u8 {
    return @tagName(value);
}

pub const Store = struct {
    db: *sqlite.Db,
    allocator: std.mem.Allocator,

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
        try s.db.exec("INSERT INTO saved_set(task_id,role) SELECT task_id,role FROM intervals WHERE end_ms IS NULL");
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
        const z = try zone.Zone.load(id);
        const local = z.localOf(now_ms) catch return error.InvalidTime;
        if (!(lockWindowsContain(windows, @as(u16, local.hour) * 60 + local.minute) orelse false)) return false;
        if (!try s.hasOpen()) return false;
        try s.pause(now_ms);
        return true;
    }

    pub fn createTask(s: *Store, title: []const u8, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        if (title.len == 0) return error.EmptyText;
        var stmt = try s.db.prepare("INSERT INTO tasks(title,created_ms) VALUES(?1,?2) RETURNING id");
        defer stmt.finalize();
        try stmt.bindText(1, title);
        try stmt.bindI64(2, now_ms);
        if (try stmt.step() != .row) return error.Sqlite;
        const id = stmt.columnI64(0);
        if (try stmt.step() != .done) return error.Sqlite;
        try tx.commit();
        return id;
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
        try tx.commit();
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
        try tx.commit();
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
        var stmt = try s.db.prepare("SELECT max(coalesce(end_ms,start_ms+1)) FROM intervals WHERE import_id IS NULL");
        defer stmt.finalize();
        if (try stmt.step() != .row or stmt.columnIsNull(0)) return now_ms;
        const floor = stmt.columnI64(0);
        if (floor <= now_ms or floor - now_ms > max_nudge_ms) return now_ms;
        if (floor >= max_time_ms) return error.InvalidTime;
        return floor;
    }

    fn openInterval(s: *Store, task: i64, role: Role, reason: OpenedBy, text: ?[]const u8, now_ms: i64) !i64 {
        {
            // Any new activity ends a lunch break.
            var lunch_end = try s.db.prepare("UPDATE lunches SET back_ms=max(out_ms,?1) WHERE back_ms IS NULL");
            defer lunch_end.finalize();
            try lunch_end.bindI64(1, now_ms);
            _ = try lunch_end.step();
        }
        var stmt = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,opened_by,text) VALUES(?1,?2,?3,?4,?5) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, sqlText(role));
        try stmt.bindI64(3, now_ms);
        try stmt.bindText(4, sqlText(reason));
        try stmt.bindOptionalText(5, text);
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
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        {
            var focus = try s.db.prepare("SELECT id,task_id FROM intervals WHERE end_ms IS NULL AND role='focus'");
            defer focus.finalize();
            if (try focus.step() == .row and focus.columnI64(1) == task) {
                const id = focus.columnI64(0);
                try tx.commit();
                return id;
            }
        }
        const at = try s.intervalTime(now_ms);
        try s.closeFocus(.@"switch", at);
        {
            var stmt = try s.db.prepare("UPDATE intervals SET end_ms=max(start_ms,?1),closed_by='switch' WHERE end_ms IS NULL AND role='parallel' AND task_id=?2");
            defer stmt.finalize();
            try stmt.bindI64(1, at);
            try stmt.bindI64(2, task);
            _ = try stmt.step();
        }
        const id = try s.openInterval(task, .focus, .@"switch", text, at);
        try s.db.exec("DELETE FROM saved_set");
        try s.heartbeat(at);
        try tx.commit();
        return id;
    }

    pub fn openParallel(s: *Store, task: i64, text: ?[]const u8, now_ms: i64) Error!i64 {
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        {
            var stmt = try s.db.prepare("SELECT 1 FROM intervals WHERE task_id=?1 AND end_ms IS NULL");
            defer stmt.finalize();
            try stmt.bindI64(1, task);
            if (try stmt.step() == .row) return error.AlreadyOpen;
        }
        const at = try s.intervalTime(now_ms);
        const id = try s.openInterval(task, .parallel, .parallel, text, at);
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
        try s.db.exec("INSERT INTO saved_set(task_id,role) SELECT task_id,role FROM intervals WHERE end_ms IS NULL");
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
        var saved = try s.db.prepare("SELECT task_id,role FROM saved_set ORDER BY task_id");
        defer saved.finalize();
        var opened = false;
        while (try saved.step() == .row) {
            const role = std.meta.stringToEnum(Role, saved.columnText(1).?) orelse return error.InvalidState;
            _ = try s.openInterval(saved.columnI64(0), role, .@"resume", null, at);
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

    const Row = struct { task: i64, role: Role, start_ms: i64, end_ms: ?i64, text: ?[]u8, closed_by: ?[]u8 };

    fn intervalRow(s: *Store, id: i64) !Row {
        var stmt = try s.db.prepare("SELECT task_id,role,start_ms,end_ms,text,closed_by FROM intervals WHERE id=?1");
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
        const id = try s.reportingZone();
        defer if (id) |v| s.allocator.free(v);
        const z = try zone.Zone.load(id orelse "UTC");
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
        if (first == second or a.task != b.task or a.role != b.role) return error.NotMergeable;
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
        var tx = try s.begin(now_ms, false);
        defer tx.deinit();
        try validSpan(start, end, now_ms);
        try s.checkFree(&.{}, task, role, start, end);
        var stmt = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by) VALUES(?1,?2,?3,?4,?5,'stop') RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, sqlText(role));
        try stmt.bindI64(3, start);
        try stmt.bindI64(4, end);
        try stmt.bindText(5, if (role == .focus) "switch" else "parallel");
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
            break :blk try s.insertPiece(to_task, row.role, from, to, if (to == end) last_closed_by else "switch");
        };
        const tail: ?i64 = if (to < end) try s.insertPiece(row.task, row.role, to, end, last_closed_by) else null;
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

    fn insertPiece(s: *Store, task: i64, role: Role, start: i64, end: i64, closed_by: []const u8) !i64 {
        var stmt = try s.db.prepare("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by) VALUES(?1,?2,?3,?4,?5,?6) RETURNING id");
        defer stmt.finalize();
        try stmt.bindI64(1, task);
        try stmt.bindText(2, sqlText(role));
        try stmt.bindI64(3, start);
        try stmt.bindI64(4, end);
        try stmt.bindText(5, if (role == .focus) "switch" else "parallel");
        try stmt.bindText(6, closed_by);
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
    try db.exec("PRAGMA user_version=7");
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
    try std.testing.expectError(error.Sqlite, s.switchTo(999, null, 120));
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
    try std.testing.expectError(error.Sqlite, s.switchTo(999, null, 180_001));
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
    try db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(1,'focus',200,'import'),(2,'parallel',400,'import')");
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
