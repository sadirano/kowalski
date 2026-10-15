const std = @import("std");
const sqlite = @import("sqlite.zig");
const clock = @import("clock.zig");

pub fn ensure(db: *sqlite.Db) !void {
    const version = blk: {
        var stmt = try db.prepare("PRAGMA user_version");
        defer stmt.finalize();
        if (try stmt.step() != .row) return error.Sqlite;
        break :blk stmt.columnI64(0);
    };
    if (version == current) return;
    if (version > current) return error.SchemaVersion;

    if (version > 0) try backup(db, version);
    try db.exec("PRAGMA foreign_keys=OFF");
    defer db.exec("PRAGMA foreign_keys=ON") catch {};

    var tx = try db.transaction();
    defer tx.deinit();
    if (version == 0) try db.exec(
        "CREATE TABLE tasks(id INTEGER PRIMARY KEY, title TEXT NOT NULL CHECK(length(title)>0), created_ms INTEGER NOT NULL);" ++
            "CREATE TABLE task_bindings(task_id INTEGER PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE, provider_instance TEXT NOT NULL, external_ref TEXT NOT NULL, UNIQUE(provider_instance,external_ref));" ++
            "CREATE TABLE task_fields(task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, name TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(task_id,name));" ++
            "CREATE TABLE intervals(id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES tasks(id), role TEXT NOT NULL CHECK(role IN ('focus','parallel')), start_ms INTEGER NOT NULL, end_ms INTEGER CHECK(end_ms IS NULL OR end_ms>=start_ms), opened_by TEXT NOT NULL CHECK(opened_by IN ('switch','parallel','resume')), closed_by TEXT CHECK(closed_by IN ('switch','pause','stop','recovered')), text TEXT, CHECK((end_ms IS NULL)=(closed_by IS NULL)));" ++
            "CREATE UNIQUE INDEX one_open_interval_per_task ON intervals(task_id) WHERE end_ms IS NULL;" ++
            "CREATE UNIQUE INDEX one_open_focus ON intervals(role) WHERE end_ms IS NULL AND role='focus';" ++
            "CREATE INDEX intervals_start ON intervals(start_ms);" ++
            "CREATE TABLE notes(id INTEGER PRIMARY KEY, interval_id INTEGER NOT NULL REFERENCES intervals(id) ON DELETE CASCADE, at_ms INTEGER NOT NULL, text TEXT NOT NULL CHECK(length(text)>0));" ++
            "CREATE TABLE saved_set(task_id INTEGER PRIMARY KEY REFERENCES tasks(id), role TEXT NOT NULL CHECK(role IN ('focus','parallel')));" ++
            "CREATE UNIQUE INDEX one_saved_focus ON saved_set(role) WHERE role='focus';" ++
            "CREATE TABLE day_summaries(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), text TEXT NOT NULL);" ++
            "CREATE TABLE postings(id INTEGER PRIMARY KEY, day TEXT NOT NULL CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), task_id INTEGER NOT NULL REFERENCES tasks(id), provider_instance TEXT NOT NULL, external_ref TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('sending','confirmed','unknown','cancelled')), amount_text TEXT NOT NULL, amount_micro INTEGER NOT NULL CHECK(amount_micro>=0), provider_data TEXT, created_ms INTEGER NOT NULL, confirmed_ms INTEGER, covered_start_ms INTEGER, covered_end_ms INTEGER CHECK(covered_end_ms IS NULL OR covered_end_ms>covered_start_ms));" ++
            "CREATE UNIQUE INDEX one_inflight_posting ON postings(day,provider_instance,external_ref) WHERE state IN ('sending','unknown');" ++
            "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);" ++
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" ++
            "CREATE TABLE lunches(id INTEGER PRIMARY KEY, out_ms INTEGER NOT NULL, back_ms INTEGER CHECK(back_ms IS NULL OR back_ms>=out_ms));" ++
            "CREATE UNIQUE INDEX one_open_lunch ON lunches(back_ms IS NULL) WHERE back_ms IS NULL;" ++
            "CREATE TABLE day_edits(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), edited_ms INTEGER NOT NULL);" ++
            "CREATE TABLE provider_trust(id INTEGER PRIMARY KEY CHECK(id=1), sha256 TEXT NOT NULL, how TEXT NOT NULL CHECK(how IN ('compared','accepted')), approved_ms INTEGER NOT NULL, last_good TEXT, loading TEXT);",
    );
    // 2: lunch breaks as recorded, and when each day's history was last edited.
    if (version > 0 and version < 2) try db.exec(
        "CREATE TABLE lunches(id INTEGER PRIMARY KEY, out_ms INTEGER NOT NULL, back_ms INTEGER CHECK(back_ms IS NULL OR back_ms>=out_ms));" ++
            "CREATE UNIQUE INDEX one_open_lunch ON lunches(back_ms IS NULL) WHERE back_ms IS NULL;" ++
            "CREATE TABLE day_edits(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), edited_ms INTEGER NOT NULL);" ++
            "PRAGMA user_version=2;",
    );
    // 3: the span of focus time a posting booked with its own start and end;
    // null for a posting of a day's total.
    if (version > 0 and version < 3) try db.exec(
        "ALTER TABLE postings ADD COLUMN covered_start_ms INTEGER;" ++
            "ALTER TABLE postings ADD COLUMN covered_end_ms INTEGER CHECK(covered_end_ms IS NULL OR covered_end_ms>covered_start_ms);" ++
            "PRAGMA user_version=3;",
    );
    if (version > 0 and version < 4) try db.exec(
        "CREATE TABLE provider_trust(id INTEGER PRIMARY KEY CHECK(id=1), sha256 TEXT NOT NULL, how TEXT NOT NULL CHECK(how IN ('compared','accepted')), approved_ms INTEGER NOT NULL, last_good TEXT, loading TEXT);" ++
            "PRAGMA user_version=4;",
    );
    if (version > 0 and version < 5) try migrateV5(db);
    if (version < 6) try db.exec(
        "ALTER TABLE provider_trust ADD COLUMN mode TEXT NOT NULL DEFAULT 'manual' CHECK(mode IN ('manual','source'));" ++
            "CREATE TABLE provider_source(id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL, source TEXT NOT NULL, public_key TEXT NOT NULL, provider TEXT NOT NULL, channel TEXT NOT NULL, highest_sequence INTEGER NOT NULL, highest_digest TEXT NOT NULL, enrolled_ms INTEGER NOT NULL, how TEXT NOT NULL CHECK(how IN ('compared','accepted')), last_check_ms INTEGER, last_error TEXT);" ++
            "CREATE TABLE provider_release(generation INTEGER NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, manifest TEXT NOT NULL, signature TEXT NOT NULL, PRIMARY KEY(generation,sequence));" ++
            "CREATE TABLE provider_generation(id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL);" ++
            "INSERT INTO provider_generation(id,value) VALUES(1,0);" ++
            "CREATE TABLE provider_quarantine(sha256 TEXT PRIMARY KEY);" ++
            "INSERT OR IGNORE INTO provider_quarantine(sha256) SELECT loading FROM provider_trust WHERE loading IS NOT NULL;",
    );
    // 7: time captured from outside sources (agent sessions, a game overlay):
    // each run's subject and state, and the events already applied.
    if (version < 7) try db.exec(
        "CREATE TABLE capture_runs(source TEXT NOT NULL, run TEXT NOT NULL, task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL, attended INTEGER NOT NULL CHECK(attended IN (0,1)), working INTEGER NOT NULL DEFAULT 0 CHECK(working IN (0,1)), role TEXT CHECK(role IN ('focus','parallel')), lease_until_ms INTEGER, idle_since_ms INTEGER, started_ms INTEGER NOT NULL, ended_ms INTEGER, PRIMARY KEY(source,run));" ++
            "CREATE TABLE capture_events(source TEXT NOT NULL, event TEXT NOT NULL, run TEXT NOT NULL, kind TEXT NOT NULL, at_ms INTEGER NOT NULL, PRIMARY KEY(source,event));",
    );
    // 8: which intervals capture opened (their focus is an estimate), and
    // which notes a captured prompt or a run's outcome wrote.
    if (version < 8) try db.exec(
        "ALTER TABLE intervals ADD COLUMN captured INTEGER NOT NULL DEFAULT 0 CHECK(captured IN (0,1));" ++
            "ALTER TABLE notes ADD COLUMN source TEXT CHECK(source IN ('prompt','outcome'));",
    );
    if (version < 9) try db.exec(
        "CREATE TABLE projects(id INTEGER PRIMARY KEY, label TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK(length(trim(label))>0 AND label=trim(label) AND length(CAST(label AS BLOB))<=200), archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)));" ++
            "ALTER TABLE tasks ADD COLUMN project_id INTEGER REFERENCES projects(id);" ++
            "ALTER TABLE tasks ADD COLUMN project_choice_explicit INTEGER NOT NULL DEFAULT 0 CHECK(project_choice_explicit IN (0,1));" ++
            "ALTER TABLE tasks ADD COLUMN project_fallback_eligible INTEGER NOT NULL DEFAULT 0 CHECK(project_fallback_eligible IN (0,1));" ++
            "CREATE INDEX tasks_project ON tasks(project_id);" ++
            "ALTER TABLE intervals ADD COLUMN project_id INTEGER REFERENCES projects(id);" ++
            "ALTER TABLE intervals ADD COLUMN posting_span_id INTEGER;" ++
            "CREATE INDEX intervals_project_start ON intervals(project_id,start_ms);" ++
            "ALTER TABLE saved_set ADD COLUMN project_id INTEGER REFERENCES projects(id);" ++
            "CREATE TABLE capture_project_keys(source TEXT NOT NULL, project_key TEXT NOT NULL, project_id INTEGER NOT NULL REFERENCES projects(id), project_hint TEXT NOT NULL, PRIMARY KEY(source,project_key));" ++
            "CREATE INDEX capture_project_keys_project ON capture_project_keys(project_id);" ++
            "ALTER TABLE capture_runs ADD COLUMN project_id INTEGER REFERENCES projects(id);" ++
            "ALTER TABLE capture_runs ADD COLUMN project_key TEXT;",
    );
    try db.exec("PRAGMA user_version=9");
    var check = try db.prepare("PRAGMA foreign_key_check");
    defer check.finalize();
    if (try check.step() != .done) return error.ForeignKeyViolation;
    try tx.commit();
}

pub const current: i64 = 9;

const legacyBase =
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
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);";


fn backup(db: *sqlite.Db, version: i64) !void {
    var path: ?[]const u8 = null;
    {
        var list = try db.prepare("PRAGMA database_list");
        defer list.finalize();
        while (try list.step() == .row) {
            if (std.mem.eql(u8, list.columnText(1).?, "main")) {
                const name = list.columnText(2) orelse "";
                if (name.len != 0) path = try std.heap.page_allocator.dupe(u8, name);
                break;
            }
        }
    }
    const db_path = path orelse return;
    defer std.heap.page_allocator.free(db_path);
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(clock.nowMs(), 1000)) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    const name = try std.fmt.allocPrint(std.heap.page_allocator, "backup-v{d}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.db", .{
        version, day.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    });
    defer std.heap.page_allocator.free(name);
    const target = try std.fs.path.join(std.heap.page_allocator, &.{ std.fs.path.dirname(db_path) orelse ".", name });
    defer std.heap.page_allocator.free(target);
    var vacuum = try db.prepare("VACUUM INTO ?1");
    defer vacuum.finalize();
    try vacuum.bindText(1, target);
    if (try vacuum.step() != .done) return error.Sqlite;
}

fn migrateV5(db: *sqlite.Db) !void {
    try db.exec(
        "CREATE TABLE tasks_new(id INTEGER PRIMARY KEY, title TEXT NOT NULL CHECK(length(title)>0), created_ms INTEGER NOT NULL);" ++
            "INSERT INTO tasks_new(id,title,created_ms) SELECT id,title,created_ms FROM tasks;" ++
            "DROP TABLE tasks; ALTER TABLE tasks_new RENAME TO tasks;" ++
            "CREATE TABLE intervals_new(id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES tasks(id), role TEXT NOT NULL CHECK(role IN ('focus','parallel')), start_ms INTEGER NOT NULL, end_ms INTEGER CHECK(end_ms IS NULL OR end_ms>=start_ms), opened_by TEXT NOT NULL CHECK(opened_by IN ('switch','parallel','resume')), closed_by TEXT CHECK(closed_by IN ('switch','pause','stop','recovered')), text TEXT, CHECK((end_ms IS NULL)=(closed_by IS NULL)));" ++
            "INSERT INTO intervals_new(id,task_id,role,start_ms,end_ms,opened_by,closed_by,text) SELECT id,task_id,role,start_ms,end_ms,CASE WHEN opened_by='import' THEN 'switch' ELSE opened_by END,CASE WHEN closed_by='import' THEN 'stop' ELSE closed_by END,text FROM intervals;" ++
            "DROP TABLE intervals; ALTER TABLE intervals_new RENAME TO intervals;" ++
            "CREATE UNIQUE INDEX one_open_interval_per_task ON intervals(task_id) WHERE end_ms IS NULL;" ++
            "CREATE UNIQUE INDEX one_open_focus ON intervals(role) WHERE end_ms IS NULL AND role='focus';" ++
            "CREATE INDEX intervals_start ON intervals(start_ms);" ++
            "CREATE TABLE notes_new(id INTEGER PRIMARY KEY, interval_id INTEGER NOT NULL REFERENCES intervals(id) ON DELETE CASCADE, at_ms INTEGER NOT NULL, text TEXT NOT NULL CHECK(length(text)>0));" ++
            "INSERT INTO notes_new(id,interval_id,at_ms,text) SELECT id,interval_id,at_ms,text FROM notes;" ++
            "DROP TABLE notes; ALTER TABLE notes_new RENAME TO notes;" ++
            "CREATE TABLE day_summaries_new(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), text TEXT NOT NULL);" ++
            "INSERT INTO day_summaries_new(day,text) SELECT day,text FROM day_summaries;" ++
            "DROP TABLE day_summaries; ALTER TABLE day_summaries_new RENAME TO day_summaries;" ++
            "CREATE TABLE postings_new(id INTEGER PRIMARY KEY, day TEXT NOT NULL CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), task_id INTEGER NOT NULL REFERENCES tasks(id), provider_instance TEXT NOT NULL, external_ref TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('sending','confirmed','unknown','cancelled')), amount_text TEXT NOT NULL, amount_micro INTEGER NOT NULL CHECK(amount_micro>=0), provider_data TEXT, created_ms INTEGER NOT NULL, confirmed_ms INTEGER, covered_start_ms INTEGER, covered_end_ms INTEGER CHECK(covered_end_ms IS NULL OR covered_end_ms>covered_start_ms));" ++
            "INSERT INTO postings_new(id,day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,provider_data,created_ms,confirmed_ms,covered_start_ms,covered_end_ms) SELECT id,day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,provider_data,created_ms,confirmed_ms,covered_start_ms,covered_end_ms FROM postings;" ++
            "DROP TABLE postings; ALTER TABLE postings_new RENAME TO postings;" ++
            "CREATE UNIQUE INDEX one_inflight_posting ON postings(day,provider_instance,external_ref) WHERE state IN ('sending','unknown');" ++
            "DROP TABLE import_settings; DROP TABLE imports;",
    );
}

test "schema constraints and version" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try ensure(&db);
    try ensure(&db);
    try std.testing.expectEqual(@as(i64, 9), try scalar(&db, "PRAGMA user_version"));
    try db.exec("INSERT INTO projects(label) VALUES('fresh')");
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO projects(label) VALUES('FRESH')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO projects(label) VALUES('')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO projects(label) VALUES(' trim ')"));
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
    try db.exec("PRAGMA user_version=10");
    try std.testing.expectError(error.SchemaVersion, ensure(&db));
}

fn legacyFixture(db: *sqlite.Db, version: i64) !void {
    try db.exec(legacyBase);
    try db.exec("CREATE TABLE lunches(id INTEGER PRIMARY KEY, out_ms INTEGER NOT NULL, back_ms INTEGER CHECK(back_ms IS NULL OR back_ms>=out_ms));CREATE UNIQUE INDEX one_open_lunch ON lunches(back_ms IS NULL) WHERE back_ms IS NULL;CREATE TABLE day_edits(day TEXT PRIMARY KEY CHECK(day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'), edited_ms INTEGER NOT NULL);");
    try db.exec("ALTER TABLE postings ADD COLUMN covered_start_ms INTEGER;ALTER TABLE postings ADD COLUMN covered_end_ms INTEGER CHECK(covered_end_ms IS NULL OR covered_end_ms>covered_start_ms);");
    if (version == 4) try db.exec("CREATE TABLE provider_trust(id INTEGER PRIMARY KEY CHECK(id=1), sha256 TEXT NOT NULL, how TEXT NOT NULL CHECK(how IN ('compared','accepted')), approved_ms INTEGER NOT NULL, last_good TEXT, loading TEXT);");
    try db.exec("INSERT INTO imports(id,at_ms,source,report,events) VALUES(9,0,'x','{}','[]');INSERT INTO import_settings(key,value) VALUES('x','y');INSERT INTO tasks(id,title,created_ms,import_id) VALUES(11,'A',1,9);INSERT INTO intervals(id,task_id,role,start_ms,end_ms,opened_by,closed_by,text,import_id) VALUES(12,11,'focus',1,2,'import','import','work',9);INSERT INTO notes(id,interval_id,at_ms,text,import_id) VALUES(13,12,1,'note',9);INSERT INTO day_summaries(day,text,import_id) VALUES('2026-03-10','summary',9);INSERT INTO postings(id,day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms,confirmed_ms,import_id,covered_start_ms,covered_end_ms) VALUES(14,'2026-03-10',11,'example','ref','confirmed','1',1000000,1,2,9,1,2);");
    if (version == 3) try db.exec("PRAGMA user_version=3") else try db.exec("PRAGMA user_version=4");
}

fn scalar(db: *sqlite.Db, sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try std.testing.expectEqual(.row, try stmt.step());
    return stmt.columnI64(0);
}

fn assertV9(db: *sqlite.Db) !void {
    try std.testing.expectEqual(@as(i64, 9), try scalar(db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(i64, 11), try scalar(db, "SELECT id FROM tasks"));
    try std.testing.expectEqual(@as(i64, 12), try scalar(db, "SELECT id FROM intervals"));
    try std.testing.expectEqual(@as(i64, 13), try scalar(db, "SELECT id FROM notes"));
    try std.testing.expectEqual(@as(i64, 7), try scalar(db, "SELECT length(text) FROM day_summaries WHERE day='2026-03-10' AND text='summary'"));
    try std.testing.expectEqual(@as(i64, 14), try scalar(db, "SELECT id FROM postings"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM intervals WHERE opened_by='switch' AND closed_by='stop' AND text='work'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM postings WHERE covered_start_ms=1 AND covered_end_ms=2 AND amount_micro=1000000"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM tasks WHERE project_id IS NULL AND project_choice_explicit=0 AND project_fallback_eligible=0"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM intervals WHERE project_id IS NULL AND posting_span_id IS NULL"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM sqlite_master WHERE name IN ('imports','import_settings')"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='import_id'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_table_info('intervals') WHERE name='import_id'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_table_info('notes') WHERE name='import_id'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_table_info('day_summaries') WHERE name='import_id'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_table_info('postings') WHERE name='import_id'"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('one_open_interval_per_task','one_open_focus','intervals_start','one_inflight_posting')"));
    var check = try db.prepare("PRAGMA foreign_key_check");
    defer check.finalize();
    try std.testing.expectEqual(.done, try check.step());
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO intervals(task_id,role,start_ms,opened_by) VALUES(11,'focus',3,'import')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO postings(day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,created_ms,covered_start_ms,covered_end_ms) VALUES('2026-03-10',11,'example','bad','confirmed','1',1,1,2,1)"));
}

test "v3 and v4 history upgrades to v9" {
    for ([_]i64{ 3, 4 }) |version| {
        var db: sqlite.Db = .{};
        try db.open(":memory:");
        defer db.close();
        try legacyFixture(&db, version);
        try ensure(&db);
        try assertV9(&db);
    }
}

test "fresh v9 has no import provenance" {
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try ensure(&db);
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT count(*) FROM sqlite_master WHERE name IN ('imports','import_settings')"));
    inline for (.{ "tasks", "intervals", "notes", "day_summaries", "postings" }) |table| {
        try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT count(*) FROM pragma_table_info('" ++ table ++ "') WHERE name='import_id'"));
    }
}

test "file upgrade makes a v4 backup, current file does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/work's db.db", .{tmp.sub_path});
    defer a.free(path);
    var db: sqlite.Db = .{};
    try db.open(path);
    try legacyFixture(&db, 4);
    try ensure(&db);
    try assertV9(&db);
    try ensure(&db);
    db.close();
    const current_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/current.db", .{tmp.sub_path});
    defer a.free(current_path);
    var current_db: sqlite.Db = .{};
    try current_db.open(current_path);
    try ensure(&current_db);
    try ensure(&current_db);
    current_db.close();
    var dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "backup-v")) continue;
        try std.testing.expect(std.mem.startsWith(u8, entry.name, "backup-v4-"));
        count += 1;
        const backup_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, entry.name });
        defer a.free(backup_path);
        var copy: sqlite.Db = .{};
        try copy.openReadOnly(backup_path);
        defer copy.close();
        try std.testing.expectEqual(@as(i64, 4), try scalar(&copy, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(i64, 12), try scalar(&copy, "SELECT id FROM intervals"));
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "populated v5 upgrades to v9 without changing history or trust" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/populated.db", .{tmp.sub_path});
    defer a.free(path);
    var db: sqlite.Db = .{};
    try db.open(path);
    try legacyFixture(&db, 4);
    try db.exec("PRAGMA foreign_keys=OFF");
    try migrateV5(&db);
    try db.exec("PRAGMA foreign_keys=ON");
    try db.exec("PRAGMA user_version=5");
    const sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try db.exec("INSERT INTO provider_trust(id,sha256,how,approved_ms,last_good,loading) VALUES(1,'" ++ sha ++ "','compared',7,'" ++ sha ++ "','" ++ sha ++ "')");
    try ensure(&db);
    try assertV9(&db);
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM provider_trust WHERE mode='manual' AND loading='" ++ sha ++ "' AND last_good='" ++ sha ++ "'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM provider_quarantine WHERE sha256='" ++ sha ++ "'"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(&db, "SELECT value FROM provider_generation WHERE id=1"));
    try ensure(&db);
    db.close();
    var dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var backups: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "backup-v5-")) backups += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), backups);
}

test "populated v8 upgrades to v9 in place with one v8 backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/populated-v8.db", .{tmp.sub_path});
    defer a.free(path);
    var db: sqlite.Db = .{};
    try db.open(path);
    try ensure(&db);
    try db.exec(
        "PRAGMA foreign_keys=OFF;" ++
        "DROP INDEX tasks_project;DROP INDEX intervals_project_start;DROP INDEX capture_project_keys_project;" ++
        "ALTER TABLE capture_runs DROP COLUMN project_key;ALTER TABLE capture_runs DROP COLUMN project_id;" ++
        "ALTER TABLE saved_set DROP COLUMN project_id;" ++
        "ALTER TABLE intervals DROP COLUMN posting_span_id;ALTER TABLE intervals DROP COLUMN project_id;" ++
        "ALTER TABLE tasks DROP COLUMN project_fallback_eligible;ALTER TABLE tasks DROP COLUMN project_choice_explicit;ALTER TABLE tasks DROP COLUMN project_id;" ++
        "DROP TABLE capture_project_keys;DROP TABLE projects;PRAGMA user_version=8;PRAGMA foreign_keys=ON;",
    );
    try db.exec(
        "INSERT INTO tasks(id,title,created_ms) VALUES(17,'synthetic',100);" ++
        "INSERT INTO intervals(id,task_id,role,start_ms,end_ms,opened_by,closed_by,text,captured) VALUES(18,17,'focus',100,200,'switch','stop','work',1);" ++
        "INSERT INTO notes(id,interval_id,at_ms,text,source) VALUES(19,18,150,'note','prompt');" ++
        "INSERT INTO day_summaries(day,text) VALUES('2026-03-10','summary');" ++
        "INSERT INTO postings(id,day,task_id,provider_instance,external_ref,state,amount_text,amount_micro,provider_data,created_ms,confirmed_ms,covered_start_ms,covered_end_ms) VALUES(20,'2026-03-10',17,'synthetic','r','confirmed','0.5',500000,'{}',100,200,100,200);" ++
        "INSERT INTO capture_runs(source,run,task_id,attended,working,started_ms) VALUES('agent','run',17,1,0,100);" ++
        "INSERT INTO saved_set(task_id,role) VALUES(17,'focus');",
    );
    try ensure(&db);
    try ensure(&db);
    try std.testing.expectEqual(@as(i64, 9), try scalar(&db, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM intervals WHERE id=18 AND task_id=17 AND start_ms=100 AND end_ms=200 AND text='work' AND captured=1 AND project_id IS NULL AND posting_span_id IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM tasks WHERE id=17 AND project_id IS NULL AND project_choice_explicit=0 AND project_fallback_eligible=0"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM notes WHERE id=19 AND interval_id=18 AND at_ms=150 AND text='note' AND source='prompt'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM day_summaries WHERE day='2026-03-10' AND text='summary'"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM postings WHERE id=20 AND task_id=17 AND amount_text='0.5' AND amount_micro=500000 AND provider_data='{}' AND covered_start_ms=100 AND covered_end_ms=200"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM capture_runs WHERE source='agent' AND run='run' AND project_id IS NULL AND project_key IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&db, "SELECT count(*) FROM saved_set WHERE task_id=17 AND project_id IS NULL"));
    var check = try db.prepare("PRAGMA foreign_key_check");
    defer check.finalize();
    try std.testing.expectEqual(.done, try check.step());
    try db.exec("INSERT INTO projects(id,label) VALUES(1,'alpha')");
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO projects(label) VALUES('ALPHA')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO projects(label) VALUES(' blank ')"));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO projects(label,archived) VALUES('wrong',2)"));
    try std.testing.expectError(error.Sqlite, db.exec("UPDATE tasks SET project_id=999 WHERE id=17"));
    db.close();
    var dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var backups: usize = 0;
    while (try it.next(std.testing.io)) |entry| if (std.mem.startsWith(u8, entry.name, "backup-v8-")) {
        backups += 1;
        const backup_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, entry.name });
        defer a.free(backup_path);
        var copy: sqlite.Db = .{};
        try copy.openReadOnly(backup_path);
        defer copy.close();
        try std.testing.expectEqual(@as(i64, 8), try scalar(&copy, "PRAGMA user_version"));
        try std.testing.expectEqual(@as(i64, 1), try scalar(&copy, "SELECT count(*) FROM postings WHERE id=20 AND covered_start_ms=100 AND covered_end_ms=200"));
    };
    try std.testing.expectEqual(@as(usize, 1), backups);
}
