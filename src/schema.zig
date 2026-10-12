const std = @import("std");
const sqlite = @import("sqlite.zig");

pub fn ensure(db: *sqlite.Db) !void {
    const version = blk: {
        var stmt = try db.prepare("PRAGMA user_version");
        defer stmt.finalize();
        if (try stmt.step() != .row) return error.Sqlite;
        break :blk stmt.columnI64(0);
    };
    if (version == current) return;
    if (version > current) return error.SchemaVersion;

    var tx = try db.transaction();
    defer tx.deinit();
    if (version == 0) try db.exec(
        "CREATE TABLE imports(id INTEGER PRIMARY KEY, at_ms INTEGER NOT NULL, source TEXT NOT NULL, report TEXT NOT NULL, events TEXT NOT NULL);" ++
            "CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL CHECK(length(title)>0), created_ms INTEGER NOT NULL, import_id INTEGER REFERENCES imports(id));" ++
            "CREATE TABLE task_bindings(task_id INTEGER PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE, provider_instance TEXT NOT NULL, external_ref TEXT NOT NULL, UNIQUE(provider_instance,external_ref));" ++
            "CREATE TABLE task_fields(task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, name TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(task_id,name));" ++
            "CREATE TABLE intervals(id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES tasks(id), role TEXT NOT NULL CHECK(role IN ('focus','parallel')), start_ms INTEGER NOT NULL, end_ms INTEGER CHECK(end_ms IS NULL OR end_ms>=start_ms), opened_by TEXT NOT NULL CHECK(opened_by IN ('switch','parallel','resume','import')), closed_by TEXT CHECK(closed_by IN ('switch','pause','stop','recovered','import')), text TEXT, import_id INTEGER REFERENCES imports(id), CHECK((end_ms IS NULL)=(closed_by IS NULL)));" ++
            "CREATE UNIQUE INDEX one_open_interval_per_task ON intervals(task_id) WHERE end_ms IS NULL;" ++
            "CREATE UNIQUE INDEX one_open_focus ON intervals(role) WHERE end_ms IS NULL AND role='focus';" ++
            "CREATE INDEX intervals_start ON intervals(start_ms);" ++
            "CREATE TABLE notes(id INTEGER PRIMARY KEY, interval_id INTEGER NOT NULL REFERENCES intervals(id) ON DELETE CASCADE, at_ms INTEGER NOT NULL, text TEXT NOT NULL CHECK(length(text)>0), import_id INTEGER REFERENCES imports(id));" ++
            "CREATE TABLE saved_set(task_id INTEGER PRIMARY KEY REFERENCES tasks(id), role TEXT NOT NULL CHECK(role IN ('focus','parallel')));" ++
            "CREATE UNIQUE INDEX one_saved_focus ON saved_set(role) WHERE role='focus';" ++
            "CREATE TABLE day_summaries(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), text TEXT NOT NULL, import_id INTEGER REFERENCES imports(id));" ++
            "CREATE TABLE postings(id INTEGER PRIMARY KEY, day TEXT NOT NULL CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), task_id INTEGER NOT NULL REFERENCES tasks(id), provider_instance TEXT NOT NULL, external_ref TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('sending','confirmed','unknown','cancelled')), amount_text TEXT NOT NULL, amount_micro INTEGER NOT NULL CHECK(amount_micro>=0), provider_data TEXT, created_ms INTEGER NOT NULL, confirmed_ms INTEGER, import_id INTEGER REFERENCES imports(id));" ++
            "CREATE UNIQUE INDEX one_inflight_posting ON postings(day,provider_instance,external_ref) WHERE state IN ('sending','unknown');" ++
            "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);" ++
            "CREATE TABLE import_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);" ++
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    );
    // 2: lunch breaks as recorded, and when each day's history was last edited.
    if (version < 2) try db.exec(
        "CREATE TABLE lunches(id INTEGER PRIMARY KEY, out_ms INTEGER NOT NULL, back_ms INTEGER CHECK(back_ms IS NULL OR back_ms>=out_ms));" ++
            "CREATE UNIQUE INDEX one_open_lunch ON lunches(back_ms IS NULL) WHERE back_ms IS NULL;" ++
            "CREATE TABLE day_edits(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), edited_ms INTEGER NOT NULL);" ++
            "PRAGMA user_version=2;",
    );
    // 3: the span of focus time a posting booked with its own start and end;
    // null for a posting of a day's total.
    if (version < 3) try db.exec(
        "ALTER TABLE postings ADD COLUMN covered_start_ms INTEGER;" ++
            "ALTER TABLE postings ADD COLUMN covered_end_ms INTEGER CHECK(covered_end_ms IS NULL OR covered_end_ms>covered_start_ms);" ++
            "PRAGMA user_version=3;",
    );
    if (version < 4) try db.exec(
        "CREATE TABLE provider_trust(id INTEGER PRIMARY KEY CHECK(id=1), sha256 TEXT NOT NULL, how TEXT NOT NULL CHECK(how IN ('compared','accepted')), approved_ms INTEGER NOT NULL, last_good TEXT, loading TEXT);" ++
            "PRAGMA user_version=4;",
    );
    try tx.commit();
}

pub const current: i64 = 4;

test "schema constraints and version" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try ensure(&db);
    try ensure(&db);
    try db.exec("INSERT INTO tasks(id,title,created_ms) VALUES(1,'A',0),(2,'B',0)");
    try db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(1,'focus',10,'switch')");
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(1,'parallel',11,'parallel')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(2,'focus',11,'switch')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO intervals(task_id,role,start_ms,end_ms,opened_by,closed_by) VALUES(2,'parallel',10,9,'parallel','stop')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(2,'wrong',10,'switch')"));
    try db.exec("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms) VALUES('2026-03-10',1,'fake','T-1','sending','1',1000000,0)");
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms) VALUES('2026-03-10',1,'fake','T-1','unknown','1',1000000,0)"));
    try db.exec("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms) VALUES('2026-03-10',1,'fake','T-2','sending','1',1000000,0)");
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms) VALUES('2026-03-10',2,'fake','T-3','wrong','1',1000000,0)"));
    try db.exec("INSERT INTO lunches(out_ms) VALUES(1)");
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO lunches(out_ms) VALUES(2)"));
    try db.exec("UPDATE lunches SET back_ms=3");
    try db.exec("INSERT INTO lunches(out_ms) VALUES(4)");
    try db.exec("PRAGMA user_version=7");
    try std.testing.expectError(error.SchemaVersion, ensure(&db));
}

test "a version 1 database upgrades in place" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL); CREATE TABLE postings(id INTEGER PRIMARY KEY, amount_micro INTEGER); INSERT INTO postings VALUES(1,500000); PRAGMA user_version=1;");
    try ensure(&db);
    try db.exec("INSERT INTO day_edits(day,edited_ms) VALUES('2026-03-10',1)");
    var stmt = try db.prepare("PRAGMA user_version");
    defer stmt.finalize();
    _ = try stmt.step();
    try std.testing.expectEqual(current, stmt.columnI64(0));
}

test "a version 2 database gains posting coverage and keeps its rows" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE postings(id INTEGER PRIMARY KEY, amount_micro INTEGER); INSERT INTO postings VALUES(1,500000); PRAGMA user_version=2;");
    try ensure(&db);
    try db.exec("UPDATE postings SET covered_start_ms=10,covered_end_ms=20 WHERE id=1");
    try std.testing.expectError(error.Sqlite, db.exec("UPDATE postings SET covered_end_ms=5 WHERE id=1"));
    var stmt = try db.prepare("SELECT amount_micro FROM postings WHERE id=1");
    defer stmt.finalize();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 500000), stmt.columnI64(0));
}

test "a version 3 database gains provider trust and keeps work history" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE postings(id INTEGER PRIMARY KEY, amount_micro INTEGER); INSERT INTO postings VALUES(1,500000); PRAGMA user_version=3;");
    try ensure(&db);
    var stmt = try db.prepare("SELECT amount_micro FROM postings WHERE id=1");
    defer stmt.finalize();
    try std.testing.expectEqual(.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 500000), stmt.columnI64(0));
    try db.exec("INSERT INTO provider_trust(id,sha256,how,approved_ms) VALUES(1,'abc','compared',1)");
}
