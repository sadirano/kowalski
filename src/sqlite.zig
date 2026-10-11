const std = @import("std");
const c = @import("sqlite_c");

/// A SQLite failure is `error.Sqlite`; `message()` contains the SQLite text.
/// The caller serializes access to a Db and its statements.
pub const Db = struct {
    handle: ?*c.sqlite3 = null,
    last_message: [512]u8 = undefined,
    last_message_len: usize = 0,
    /// The error code captured with `last_message`; later calls do not change it.
    last_code: c_int = c.SQLITE_OK,

    pub fn open(db: *Db, path: []const u8) !void {
        const z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(z);
        const rc = c.sqlite3_open_v2(z.ptr, &db.handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK) {
            db.capture();
            db.close();
            return error.Sqlite;
        }
        errdefer db.close();
        try db.check(c.sqlite3_busy_timeout(db.handle, 5000));
        {
            var stmt = try db.prepare("PRAGMA journal_mode=WAL");
            defer stmt.finalize();
            if (try stmt.step() != .row) return error.NotWal;
            const mode = stmt.columnText(0) orelse return error.NotWal;
            const expected: []const u8 = if (std.mem.eql(u8, path, ":memory:")) "memory" else "wal";
            if (!std.ascii.eqlIgnoreCase(mode, expected)) return error.NotWal;
        }
        try db.exec("PRAGMA foreign_keys=ON");
    }

    /// Open a live source without creating files or changing its journal mode.
    pub fn openReadOnly(db: *Db, path: []const u8) !void {
        const z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(z);
        const rc = c.sqlite3_open_v2(z.ptr, &db.handle, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK) {
            db.capture();
            db.close();
            return error.Sqlite;
        }
        errdefer db.close();
        try db.check(c.sqlite3_busy_timeout(db.handle, 5000));
    }

    pub fn close(db: *Db) void {
        if (db.handle) |handle| {
            _ = c.sqlite3_close_v2(handle);
            db.handle = null;
        }
    }

    pub fn message(db: *const Db) []const u8 {
        return db.last_message[0..db.last_message_len];
    }

    fn capture(db: *Db) void {
        const msg = if (db.handle) |handle| std.mem.span(c.sqlite3_errmsg(handle)) else "sqlite open failed";
        db.last_code = if (db.handle) |handle| c.sqlite3_errcode(handle) else c.SQLITE_CANTOPEN;
        db.last_message_len = @min(msg.len, db.last_message.len);
        @memcpy(db.last_message[0..db.last_message_len], msg[0..db.last_message_len]);
    }

    fn check(db: *Db, rc: c_int) error{Sqlite}!void {
        if (rc == c.SQLITE_OK) return;
        db.capture();
        return error.Sqlite;
    }

    /// Short SQL (BEGIN, COMMIT, ROLLBACK) is terminated on the stack, so it
    /// cannot fail for lack of memory.
    pub fn exec(db: *Db, sql: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (sql.len < buf.len) {
            @memcpy(buf[0..sql.len], sql);
            buf[sql.len] = 0;
            return db.check(c.sqlite3_exec(db.handle, &buf, null, null, null));
        }
        const z = try std.heap.page_allocator.dupeSentinel(u8, sql, 0);
        defer std.heap.page_allocator.free(z);
        try db.check(c.sqlite3_exec(db.handle, z.ptr, null, null, null));
    }

    pub fn prepare(db: *Db, sql: []const u8) !Statement {
        if (sql.len > std.math.maxInt(c_int)) return error.TooLarge;
        var stmt: ?*c.sqlite3_stmt = null;
        try db.check(c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null));
        return .{ .db = db, .handle = stmt orelse return error.EmptyStatement };
    }

    pub fn lastInsertRowid(db: *Db) i64 {
        return c.sqlite3_last_insert_rowid(db.handle);
    }

    pub fn changes(db: *Db) i64 {
        return c.sqlite3_changes64(db.handle);
    }

    /// Whether the last captured failure was a constraint violation.
    pub fn isConstraint(db: *const Db) bool {
        return db.last_code == c.SQLITE_CONSTRAINT;
    }

    pub fn transaction(db: *Db) !Transaction {
        try db.exec("BEGIN IMMEDIATE");
        return .{ .db = db };
    }
};

pub const Statement = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,
    /// The last step failed: reset then repeats that error without failing again.
    step_failed: bool = false,

    pub fn bindI64(s: *Statement, index: c_int, value: i64) !void {
        try s.db.check(c.sqlite3_bind_int64(s.handle, index, value));
    }

    pub fn bindText(s: *Statement, index: c_int, value: []const u8) !void {
        if (value.len > std.math.maxInt(c_int)) return error.TooLarge;
        try s.db.check(c.sqlite3_bind_text(s.handle, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT));
    }

    pub fn bindNull(s: *Statement, index: c_int) !void {
        try s.db.check(c.sqlite3_bind_null(s.handle, index));
    }

    pub fn bindOptionalText(s: *Statement, index: c_int, value: ?[]const u8) !void {
        if (value) |text| try s.bindText(index, text) else try s.bindNull(index);
    }

    pub const Step = enum { row, done };

    pub fn step(s: *Statement) error{Sqlite}!Step {
        const rc = c.sqlite3_step(s.handle);
        s.step_failed = rc != c.SQLITE_ROW and rc != c.SQLITE_DONE;
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => {
                s.db.capture();
                return error.Sqlite;
            },
        };
    }

    pub fn columnI64(s: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(s.handle, index);
    }

    pub fn columnIsNull(s: *Statement, index: c_int) bool {
        return c.sqlite3_column_type(s.handle, index) == c.SQLITE_NULL;
    }

    /// The slice is valid until the next step, reset, or finalize.
    pub fn columnText(s: *Statement, index: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(s.handle, index) orelse return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(s.handle, index));
        return ptr[0..len];
    }

    /// After a failed step, sqlite3_reset returns that step's error although the
    /// statement was reset; any other reset error (e.g. BUSY finishing a statement
    /// stopped mid-row) is a new failure and is reported.
    pub fn reset(s: *Statement) !void {
        const reset_rc = c.sqlite3_reset(s.handle);
        const repeated = s.step_failed;
        s.step_failed = false;
        if (reset_rc != c.SQLITE_OK and !repeated) {
            s.db.capture();
            return error.Sqlite;
        }
        try s.db.check(c.sqlite3_clear_bindings(s.handle));
    }

    pub fn finalize(s: *Statement) void {
        _ = c.sqlite3_finalize(s.handle);
        s.* = undefined;
    }
};

pub const Transaction = struct {
    db: *Db,
    active: bool = true,

    pub fn commit(tx: *Transaction) !void {
        try tx.db.exec("COMMIT");
        tx.active = false;
    }

    pub fn rollback(tx: *Transaction) !void {
        if (!tx.active) return;
        // A closed connection already rolled the transaction back.
        const handle = tx.db.handle orelse {
            tx.active = false;
            return;
        };
        if (c.sqlite3_get_autocommit(handle) != 0) {
            tx.active = false;
            return;
        }
        try tx.db.exec("ROLLBACK");
        tx.active = false;
    }

    pub fn deinit(tx: *Transaction) void {
        if (!tx.active) return;
        const original_code = tx.db.last_code;
        const original_message_len = tx.db.last_message_len;
        var original_message: [512]u8 = undefined;
        @memcpy(original_message[0..original_message_len], tx.db.last_message[0..original_message_len]);
        tx.rollback() catch {};
        @memcpy(tx.db.last_message[0..original_message_len], original_message[0..original_message_len]);
        tx.db.last_message_len = original_message_len;
        tx.db.last_code = original_code;
    }
};

test "prepare rejects empty and comment-only SQL" {
    var db: Db = .{};
    try db.open(":memory:");
    defer db.close();
    try std.testing.expectError(error.EmptyStatement, db.prepare(""));
    try std.testing.expectError(error.EmptyStatement, db.prepare("-- x"));
}

test "prepared values and reset" {
    var db: Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER, text TEXT, optional TEXT)");
    var insert = try db.prepare("INSERT INTO t VALUES (?1, ?2, ?3)");
    defer insert.finalize();
    try insert.bindI64(1, 42);
    try insert.bindText(2, "hello");
    try insert.bindNull(3);
    try std.testing.expectEqual(Statement.Step.done, try insert.step());
    try insert.reset();
    try insert.bindI64(1, 43);
    try insert.bindText(2, "world");
    try insert.bindNull(3);
    try std.testing.expectEqual(Statement.Step.done, try insert.step());

    var select = try db.prepare("SELECT n, text, optional FROM t ORDER BY n");
    defer select.finalize();
    try std.testing.expectEqual(Statement.Step.row, try select.step());
    try std.testing.expectEqual(@as(i64, 42), select.columnI64(0));
    try std.testing.expectEqualStrings("hello", select.columnText(1).?);
    try std.testing.expect(select.columnIsNull(2));
    try std.testing.expectEqual(Statement.Step.row, try select.step());
    try std.testing.expectEqualStrings("world", select.columnText(1).?);
    try std.testing.expectEqual(Statement.Step.done, try select.step());
}

test "reset after unique violation permits rebinding" {
    var db: Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER UNIQUE)");
    try db.exec("INSERT INTO t VALUES (1)");
    var insert = try db.prepare("INSERT INTO t VALUES (?1)");
    defer insert.finalize();
    try insert.bindI64(1, 1);
    try std.testing.expectError(error.Sqlite, insert.step());
    try insert.reset();
    try insert.bindI64(1, 2);
    try std.testing.expectEqual(Statement.Step.done, try insert.step());
    var count = try db.prepare("SELECT count(*) FROM t");
    defer count.finalize();
    try std.testing.expectEqual(Statement.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 2), count.columnI64(0));
}

test "transaction rollback and SQLite message" {
    var db: Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER PRIMARY KEY)");
    {
        var tx = try db.transaction();
        defer tx.deinit();
        try db.exec("INSERT INTO t VALUES (1)");
    }
    var count = try db.prepare("SELECT count(*) FROM t");
    defer count.finalize();
    try std.testing.expectEqual(Statement.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnI64(0));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO missing VALUES (1)"));
    try std.testing.expect(std.mem.indexOf(u8, db.message(), "missing") != null);
}

test "constraint failure survives the rollback in deinit" {
    var db: Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER UNIQUE)");
    try db.exec("INSERT INTO t VALUES (1)");
    {
        var tx = try db.transaction();
        defer tx.deinit();
        try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO t VALUES (1)"));
    }
    try std.testing.expect(db.isConstraint());
    try std.testing.expect(std.mem.indexOf(u8, db.message(), "UNIQUE") != null);
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO missing VALUES (1)"));
    try std.testing.expect(!db.isConstraint());
}

test "exec runs SQL on both sides of the stack buffer" {
    var db: Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (text TEXT)");
    const padding: [300]u8 = @splat('x');
    try db.exec("INSERT INTO t VALUES ('" ++ padding ++ "')");
    var short = "INSERT INTO t VALUES ('')".*;
    try db.exec(&short);
    var count = try db.prepare("SELECT count(*), max(length(text)) FROM t");
    defer count.finalize();
    try std.testing.expectEqual(Statement.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 2), count.columnI64(0));
    try std.testing.expectEqual(@as(i64, padding.len), count.columnI64(1));
}

test "rollback on a closed connection is a no-op" {
    var db: Db = .{};
    try db.open(":memory:");
    var tx = try db.transaction();
    db.close();
    try tx.rollback();
    try std.testing.expect(!tx.active);
    tx.deinit();
}
