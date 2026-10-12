const std = @import("std");
const sqlite = @import("sqlite.zig");
const manifest = @import("provider_manifest");

pub const Enrollment = struct {
    generation: i64,
    source: []const u8,
    public_key: []const u8,
    provider: []const u8,
    channel: []const u8,
    highest_sequence: i64,
    highest_digest: []const u8,
    enrolled_ms: i64,
    how: []const u8,
    last_check_ms: ?i64,
    last_error: ?[]const u8,
};

pub const Outcome = enum { available, same, older };

pub fn read(db: *sqlite.Db, a: std.mem.Allocator) !?Enrollment {
    var stmt = try db.prepare("SELECT generation,source,public_key,provider,channel,highest_sequence,highest_digest,enrolled_ms,how,last_check_ms,last_error FROM provider_source WHERE id=1");
    defer stmt.finalize();
    if (try stmt.step() == .done) return null;
    return .{
        .generation = stmt.columnI64(0), .source = try a.dupe(u8, stmt.columnText(1).?),
        .public_key = try a.dupe(u8, stmt.columnText(2).?), .provider = try a.dupe(u8, stmt.columnText(3).?),
        .channel = try a.dupe(u8, stmt.columnText(4).?), .highest_sequence = stmt.columnI64(5),
        .highest_digest = try a.dupe(u8, stmt.columnText(6).?), .enrolled_ms = stmt.columnI64(7),
        .how = try a.dupe(u8, stmt.columnText(8).?),
        .last_check_ms = if (stmt.columnIsNull(9)) null else stmt.columnI64(9),
        .last_error = if (stmt.columnText(10)) |value| try a.dupe(u8, value) else null,
    };
}

pub fn currentGeneration(db: *sqlite.Db) !i64 {
    var stmt = try db.prepare("SELECT value FROM provider_generation WHERE id=1");
    defer stmt.finalize();
    if (try stmt.step() != .row) return error.Sqlite;
    return stmt.columnI64(0);
}

pub fn enroll(db: *sqlite.Db, expected_generation: i64, source: []const u8, key: []const u8, how: []const u8, m: manifest.Manifest, bytes: []const u8, signature: []const u8, now: i64) !void {
    if (!manifest.validHex(key, 64) or source.len == 0 or source.len > 2048 or
        !(std.mem.eql(u8, how, "compared") or std.mem.eql(u8, how, "accepted"))) return error.BadEnrollment;
    var tx = try db.transaction();
    defer tx.deinit();
    if (try currentGeneration(db) != expected_generation) return error.SourceChanged;
    try db.exec("UPDATE provider_generation SET value=value+1 WHERE id=1");
    const next_generation = try currentGeneration(db);
    const digest = manifest.digest(bytes);
    var stmt = try db.prepare("INSERT INTO provider_source(id,generation,source,public_key,provider,channel,highest_sequence,highest_digest,enrolled_ms,how,last_check_ms,last_error) VALUES(1,?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,NULL) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation,source=excluded.source,public_key=excluded.public_key,provider=excluded.provider,channel=excluded.channel,highest_sequence=excluded.highest_sequence,highest_digest=excluded.highest_digest,enrolled_ms=excluded.enrolled_ms,how=excluded.how,last_check_ms=NULL,last_error=NULL");
    defer stmt.finalize();
    try stmt.bindI64(1, next_generation);
    try stmt.bindText(2, source);
    try stmt.bindText(3, key);
    try stmt.bindText(4, m.provider);
    try stmt.bindText(5, m.channel);
    try stmt.bindI64(6, m.sequence);
    try stmt.bindText(7, &digest);
    try stmt.bindI64(8, now);
    try stmt.bindText(9, how);
    _ = try stmt.step();
    try saveRelease(db, next_generation, m.sequence, &digest, bytes, signature);
    try tx.commit();
}

pub fn check(db: *sqlite.Db, a: std.mem.Allocator, generation: i64, m: manifest.Manifest, bytes: []const u8, signature: []const u8, now: i64) !Outcome {
    var tx = try db.transaction();
    defer tx.deinit();
    const source = (try read(db, a)) orelse return error.SourceChanged;
    if (source.generation != generation) return error.SourceChanged;
    if (!std.mem.eql(u8, source.provider, m.provider) or !std.mem.eql(u8, source.channel, m.channel)) return error.IdentityChanged;
    const digest = manifest.digest(bytes);
    if (m.sequence == source.highest_sequence and !std.mem.eql(u8, source.highest_digest, &digest)) return error.ManifestChangedWithoutSequence;
    const outcome: Outcome = if (m.sequence > source.highest_sequence) .available else if (m.sequence == source.highest_sequence) .same else .older;
    var stmt = try db.prepare("UPDATE provider_source SET highest_sequence=?1,highest_digest=?2,last_check_ms=?3,last_error=NULL WHERE id=1");
    defer stmt.finalize();
    try stmt.bindI64(1, if (outcome == .available) m.sequence else source.highest_sequence);
    try stmt.bindText(2, if (outcome == .available) &digest else source.highest_digest);
    try stmt.bindI64(3, now);
    _ = try stmt.step();
    try saveRelease(db, generation, m.sequence, &digest, bytes, signature);
    try tx.commit();
    return outcome;
}

fn saveRelease(db: *sqlite.Db, generation: i64, sequence: i64, digest: []const u8, bytes: []const u8, signature: []const u8) !void {
    var existing = try db.prepare("SELECT digest FROM provider_release WHERE generation=?1 AND sequence=?2");
    defer existing.finalize();
    try existing.bindI64(1, generation);
    try existing.bindI64(2, sequence);
    if (try existing.step() == .row) {
        if (!std.mem.eql(u8, existing.columnText(0).?, digest)) return error.ManifestChangedWithoutSequence;
        return;
    }
    var stmt = try db.prepare("INSERT INTO provider_release(generation,sequence,digest,manifest,signature) VALUES(?1,?2,?3,?4,?5)");
    defer stmt.finalize();
    try stmt.bindI64(1, generation);
    try stmt.bindI64(2, sequence);
    try stmt.bindText(3, digest);
    try stmt.bindText(4, bytes);
    try stmt.bindText(5, signature);
    _ = try stmt.step();
}

pub const Release = struct { sequence: i64, digest: []const u8, bytes: []const u8, signature: []const u8 };

pub fn release(db: *sqlite.Db, a: std.mem.Allocator, generation: i64, sequence: i64) !?Release {
    var stmt = try db.prepare("SELECT sequence,digest,manifest,signature FROM provider_release WHERE generation=?1 AND sequence=?2");
    defer stmt.finalize();
    try stmt.bindI64(1, generation);
    try stmt.bindI64(2, sequence);
    if (try stmt.step() == .done) return null;
    return .{ .sequence = stmt.columnI64(0), .digest = try a.dupe(u8, stmt.columnText(1).?), .bytes = try a.dupe(u8, stmt.columnText(2).?), .signature = try a.dupe(u8, stmt.columnText(3).?) };
}

pub fn recordError(db: *sqlite.Db, generation: i64, message: []const u8, now: i64) !void {
    var stmt = try db.prepare("UPDATE provider_source SET last_check_ms=?1,last_error=?2 WHERE id=1 AND generation=?3");
    defer stmt.finalize();
    try stmt.bindI64(1, now);
    try stmt.bindText(2, message);
    try stmt.bindI64(3, generation);
    _ = try stmt.step();
}

pub fn installTrust(db: *sqlite.Db, a: std.mem.Allocator, generation: i64, bytes: []const u8, m: manifest.Manifest, now: i64, allow_older: bool) !void {
    var tx = try db.transaction();
    defer tx.deinit();
    const source = (try read(db, a)) orelse return error.SourceChanged;
    if (source.generation != generation) return error.SourceChanged;
    const digest = manifest.digest(bytes);
    const retained = (try release(db, a, generation, m.sequence)) orelse return error.ReleaseChanged;
    if (!std.mem.eql(u8, retained.digest, &digest)) return error.ReleaseChanged;
    if (!allow_older and (m.sequence != source.highest_sequence or !std.mem.eql(u8, &digest, source.highest_digest))) return error.ReleaseChanged;
    if (allow_older and m.sequence >= source.highest_sequence) return error.NotOlder;
    try db.exec("INSERT OR IGNORE INTO provider_quarantine(sha256) SELECT loading FROM provider_trust WHERE loading IS NOT NULL");
    var stmt = try db.prepare("INSERT INTO provider_trust(id,sha256,how,approved_ms,loading,mode) VALUES(1,?1,?2,?3,(SELECT sha256 FROM provider_quarantine WHERE sha256=?1),'source') ON CONFLICT(id) DO UPDATE SET sha256=excluded.sha256,how=excluded.how,approved_ms=excluded.approved_ms,mode='source',loading=excluded.loading");
    defer stmt.finalize();
    try stmt.bindText(1, m.sha256);
    try stmt.bindText(2, source.how);
    try stmt.bindI64(3, now);
    _ = try stmt.step();
    try tx.commit();
}

pub fn stop(db: *sqlite.Db) !void {
    var tx = try db.transaction();
    defer tx.deinit();
    try db.exec("DELETE FROM provider_release;DELETE FROM provider_source;UPDATE provider_trust SET mode='manual' WHERE id=1");
    try tx.commit();
}

test "source state pins identity, high-water mark, and manual transition" {
    const schema = @import("schema.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try schema.ensure(&db);
    const key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const m: manifest.Manifest = .{ .provider = "sample", .channel = "stable", .sequence = 4, .version = "4", .file = "sample-4.dll", .size = 1, .sha256 = key };
    try enroll(&db, 0, "folder", key, "compared", m, "four", "sig", 1);
    const first = (try read(&db, a)).?;
    try std.testing.expectEqual(@as(i64, 1), first.generation);
    try std.testing.expectEqual(Outcome.same, try check(&db, a, first.generation, m, "four", "sig", 2));
    var other_identity = m;
    other_identity.provider = "other";
    try std.testing.expectError(error.IdentityChanged, check(&db, a, first.generation, other_identity, "four", "sig", 2));
    try std.testing.expectError(error.ManifestChangedWithoutSequence, check(&db, a, first.generation, m, "changed", "sig", 3));
    var newer = m;
    newer.sequence = 5;
    try std.testing.expectEqual(Outcome.available, try check(&db, a, first.generation, newer, "five", "sig", 4));
    try std.testing.expectEqual(Outcome.older, try check(&db, a, first.generation, m, "four", "sig", 5));
    var older = m;
    older.sequence = 3;
    try std.testing.expectEqual(Outcome.older, try check(&db, a, first.generation, older, "three", "sig", 5));
    try std.testing.expectEqualStrings("three", (try release(&db, a, first.generation, 3)).?.bytes);
    try std.testing.expectError(error.ManifestChangedWithoutSequence, check(&db, a, first.generation, older, "changed", "sig", 5));
    try std.testing.expectEqual(@as(i64, 5), (try read(&db, a)).?.highest_sequence);
    try std.testing.expectError(error.ReleaseChanged, installTrust(&db, a, first.generation, "tampered", m, 6, true));
    try installTrust(&db, a, first.generation, "four", m, 6, true);
    try std.testing.expectEqual(@as(i64, 5), (try read(&db, a)).?.highest_sequence);
    try db.exec("UPDATE provider_trust SET loading='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'");
    try installTrust(&db, a, first.generation, "five", newer, 7, false);
    try db.exec("UPDATE provider_source SET highest_digest='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'");
    try std.testing.expectError(error.ReleaseChanged, installTrust(&db, a, first.generation, "five", newer, 7, false));
    var stmt = try db.prepare("SELECT mode,loading FROM provider_trust WHERE id=1");
    defer stmt.finalize();
    try std.testing.expectEqual(.row, try stmt.step());
    try std.testing.expectEqualStrings("source", stmt.columnText(0).?);
    try std.testing.expectEqualStrings(key, stmt.columnText(1).?);
    try db.exec("UPDATE provider_trust SET last_good='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'");
    try stop(&db);
    try std.testing.expect((try read(&db, a)) == null);
    try std.testing.expectEqual(@as(i64, 1), try currentGeneration(&db));
    var trust = try db.prepare("SELECT sha256,last_good,loading,mode FROM provider_trust WHERE id=1");
    defer trust.finalize();
    try std.testing.expectEqual(.row, try trust.step());
    try std.testing.expectEqualStrings(key, trust.columnText(0).?);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", trust.columnText(1).?);
    try std.testing.expectEqualStrings(key, trust.columnText(2).?);
    try std.testing.expectEqualStrings("manual", trust.columnText(3).?);
    try enroll(&db, 1, "second", key, "compared", m, "four", "sig", 8);
    try std.testing.expectEqual(@as(i64, 2), (try read(&db, a)).?.generation);
    try std.testing.expectError(error.SourceChanged, installTrust(&db, a, 1, "four", m, 9, false));
}

test "quarantine survives intervening source installs" {
    const schema = @import("schema.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: sqlite.Db = .{};
    try db.open(":memory:");
    defer db.close();
    try schema.ensure(&db);
    const hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var m: manifest.Manifest = .{ .provider = "sample", .channel = "stable", .sequence = 1, .version = "1", .file = "sample-1.dll", .size = 1, .sha256 = hash_a };
    try enroll(&db, 0, "folder", hash_a, "compared", m, "one", "sig", 1);
    try installTrust(&db, a, 1, "one", m, 2, false);
    try db.exec("UPDATE provider_trust SET loading='" ++ hash_a ++ "'");
    m.sequence = 2;
    m.sha256 = hash_b;
    try std.testing.expectEqual(Outcome.available, try check(&db, a, 1, m, "two", "sig", 3));
    try installTrust(&db, a, 1, "two", m, 4, false);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM provider_quarantine WHERE sha256='" ++ hash_a ++ "'"));
    m.sequence = 1;
    m.sha256 = hash_a;
    try installTrust(&db, a, 1, "one", m, 5, true);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(&db, "SELECT count(*) FROM provider_trust WHERE loading='" ++ hash_a ++ "'"));
}

fn scalarCount(db: *sqlite.Db, sql: []const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (try stmt.step() != .row) return error.Sqlite;
    return stmt.columnI64(0);
}
