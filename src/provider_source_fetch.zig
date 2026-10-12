const std = @import("std");
const Io = std.Io;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

pub const Fetcher = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, std.mem.Allocator, Io, []const u8, usize) anyerror![]const u8,
};

pub const CopyResult = struct { size: usize, digest: [64]u8 };

pub fn verifyCopy(copied: CopyResult, expected_size: usize, expected_hash: []const u8) !void {
    if (copied.size != expected_size) return error.DllSizeMismatch;
    if (!std.mem.eql(u8, &copied.digest, expected_hash)) return error.DllHashMismatch;
}
pub const Copier = struct {
    context: *anyopaque,
    copy: *const fn (*anyopaque, std.mem.Allocator, Io, []const u8, Io.File, usize) anyerror!CopyResult,
};

fn stream(reader: *Io.Reader, file: Io.File, io: Io, limit: usize) !CopyResult {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var total: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buffer);
        if (n == 0) break;
        if (n > limit - total) return error.SourceTooLarge;
        try file.writeStreamingAll(io, buffer[0..n]);
        hash.update(buffer[0..n]);
        total += n;
    }
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    return .{ .size = total, .digest = std.fmt.bytesToHex(bytes, .lower) };
}

pub fn realCopy(_: *anyopaque, a: std.mem.Allocator, io: Io, address: []const u8, dest: Io.File, limit: usize) !CopyResult {
    if (std.mem.startsWith(u8, address, "https://")) {
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        const uri = try std.Uri.parse(address);
        var req = try client.request(.GET, uri, .{ .redirect_behavior = .not_allowed, .keep_alive = false });
        defer req.deinit();
        req.accept_encoding = @splat(false);
        req.accept_encoding[@backingInt(std.http.ContentEncoding.identity)] = true;
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        if (response.head.status != .ok) return error.SourceHttp;
        var transfer: [64]u8 = undefined;
        return stream(response.reader(&transfer), dest, io, limit);
    }
    var input = try Io.Dir.cwd().openFile(io, address, .{});
    defer input.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = input.reader(io, &buffer);
    return stream(&reader.interface, dest, io, limit);
}

pub fn realGet(_: *anyopaque, a: std.mem.Allocator, io: Io, address: []const u8, limit: usize) ![]const u8 {
    if (std.mem.startsWith(u8, address, "https://")) {
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        const storage = try a.alloc(u8, limit);
        var body: Io.Writer = .fixed(storage);
        const response = client.fetch(.{ .location = .{ .url = address }, .response_writer = &body, .redirect_behavior = .not_allowed }) catch |err| switch (err) {
            error.WriteFailed => return error.SourceTooLarge,
            else => return err,
        };
        if (response.status != .ok) return error.SourceHttp;
        return body.buffered();
    }
    return Io.Dir.cwd().readFileAlloc(io, address, a, .limited(limit));
}

pub fn validSource(source: []const u8) bool {
    if (source.len == 0 or source.len > 2048) return false;
    for (source) |c| if (c < 32 or c == 127) return false;
    if (std.mem.startsWith(u8, source, "https://")) return std.mem.indexOfScalar(u8, source, '?') == null and std.mem.indexOfScalar(u8, source, '#') == null;
    return std.mem.indexOf(u8, source, "://") == null;
}

pub fn location(a: std.mem.Allocator, source: []const u8, file: []const u8) ![]const u8 {
    if (!validSource(source) or std.mem.indexOfScalar(u8, file, '/') != null or std.mem.indexOfScalar(u8, file, '\\') != null or std.mem.eql(u8, file, "..")) return error.BadSource;
    if (std.mem.startsWith(u8, source, "https://")) return std.fmt.allocPrint(a, "{s}{s}{s}", .{ source, if (std.mem.endsWith(u8, source, "/")) "" else "/", file });
    return std.fs.path.join(a, &.{ source, file });
}

var outstanding = std.atomic.Value(bool).init(false);

const Job = struct {
    refs: std.atomic.Value(u8) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    arena: std.heap.ArenaAllocator,
    io: Io,
    fetcher: Fetcher,
    path: []const u8,
    limit: usize,
    result: anyerror![]const u8 = error.NotReady,
    completed: Io.Timestamp = .zero,

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) == 1) {
            job.arena.deinit();
            std.heap.page_allocator.destroy(job);
        }
    }

    fn work(job: *Job) void {
        job.result = job.fetcher.get(job.fetcher.context, job.arena.allocator(), job.io, job.path, job.limit);
        job.completed = Io.Clock.awake.now(job.io);
        job.done.store(true, .release);
        outstanding.store(false, .release);
        job.release();
    }
};

/// The worker owns its result after a timeout; a late result is discarded.
pub fn boundedGet(io: Io, a: std.mem.Allocator, fetcher: Fetcher, path: []const u8, limit: usize, deadline: Io.Timestamp) ![]const u8 {
    if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.SourceTimeout;
    if (outstanding.swap(true, .acq_rel)) return error.CheckBusy;
    var owns_slot = true;
    errdefer if (owns_slot) outstanding.store(false, .release);
    const job = try std.heap.page_allocator.create(Job);
    var owns_job = true;
    errdefer if (owns_job) {
        job.arena.deinit();
        std.heap.page_allocator.destroy(job);
    };
    job.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .io = io, .fetcher = fetcher, .path = undefined, .limit = limit };
    job.path = try job.arena.allocator().dupe(u8, path);
    const thread = try std.Thread.spawn(.{}, Job.work, .{job});
    owns_slot = false;
    owns_job = false;
    thread.detach();
    defer job.release();
    while (!job.done.load(.acquire)) {
        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.SourceTimeout;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    if (job.completed.nanoseconds > deadline.nanoseconds) return error.SourceTimeout;
    const bytes = try job.result;
    return a.dupe(u8, bytes);
}

const CopyJob = struct {
    refs: std.atomic.Value(u8) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    arena: std.heap.ArenaAllocator,
    io: Io,
    copier: Copier,
    source: []const u8,
    stage: []const u8,
    file: Io.File,
    limit: usize,
    deadline: Io.Timestamp,
    result: anyerror!CopyResult = error.NotReady,
    completed: Io.Timestamp = .zero,

    fn release(job: *CopyJob) void {
        if (job.refs.fetchSub(1, .acq_rel) == 1) {
            job.arena.deinit();
            std.heap.page_allocator.destroy(job);
        }
    }

    fn work(job: *CopyJob) void {
        job.result = job.copier.copy(job.copier.context, job.arena.allocator(), job.io, job.source, job.file, job.limit);
        job.file.close(job.io);
        job.completed = Io.Clock.awake.now(job.io);
        var discard = job.completed.nanoseconds > job.deadline.nanoseconds;
        if (job.result) |_| {} else |_| discard = true;
        if (discard) {
            Io.Dir.cwd().deleteFile(job.io, job.stage) catch {};
        }
        job.done.store(true, .release);
        outstanding.store(false, .release);
        job.release();
    }
};

/// Ownership of the exclusive stage file transfers to the worker.
pub fn boundedCopy(io: Io, copier: Copier, source: []const u8, stage: []const u8, file: Io.File, limit: usize, deadline: Io.Timestamp) !CopyResult {
    var owns_file = true;
    defer if (owns_file) {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, stage) catch {};
    };
    if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.SourceTimeout;
    if (outstanding.swap(true, .acq_rel)) return error.CheckBusy;
    var owns_slot = true;
    errdefer if (owns_slot) outstanding.store(false, .release);
    const job = try std.heap.page_allocator.create(CopyJob);
    var owns_job = true;
    errdefer if (owns_job) {
        job.arena.deinit();
        std.heap.page_allocator.destroy(job);
    };
    job.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .io = io, .copier = copier,
        .source = undefined, .stage = undefined, .file = file, .limit = limit, .deadline = deadline };
    const ja = job.arena.allocator();
    job.source = try ja.dupe(u8, source);
    job.stage = try ja.dupe(u8, stage);
    const thread = try std.Thread.spawn(.{}, CopyJob.work, .{job});
    owns_file = false;
    owns_slot = false;
    owns_job = false;
    thread.detach();
    defer job.release();
    while (!job.done.load(.acquire)) {
        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.SourceTimeout;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    if (job.completed.nanoseconds > deadline.nanoseconds) return error.SourceTimeout;
    return job.result;
}

test "slow source returns by deadline, refuses overlap, discards late data, and recovers" {
    const Fake = struct {
        fn get(_: *anyopaque, _: std.mem.Allocator, _: Io, _: []const u8, _: usize) ![]const u8 {
            Sleep(300);
            return "late";
        }
        fn fast(_: *anyopaque, _: std.mem.Allocator, _: Io, _: []const u8, _: usize) ![]const u8 { return "fresh"; }
    };
    const fetcher: Fetcher = .{ .context = undefined, .get = Fake.get };
    const io = std.testing.io;
    const start = Io.Clock.awake.now(io);
    try std.testing.expectError(error.SourceTimeout, boundedGet(io, std.testing.allocator, fetcher, "unused", 4, start.addDuration(.fromMilliseconds(15))));
    const elapsed = Io.Clock.awake.now(io).toMilliseconds() - start.toMilliseconds();
    try std.testing.expect(elapsed < 200);
    const fast: Fetcher = .{ .context = undefined, .get = Fake.fast };
    try std.testing.expectError(error.CheckBusy, boundedGet(io, std.testing.allocator, fast, "unused", 5, Io.Clock.awake.now(io).addDuration(.fromMilliseconds(100))));
    try io.sleep(.fromMilliseconds(350), .awake);
    const fresh = try boundedGet(io, std.testing.allocator, fast, "unused", 5, Io.Clock.awake.now(io).addDuration(.fromMilliseconds(100)));
    defer std.testing.allocator.free(fresh);
    try std.testing.expectEqualStrings("fresh", fresh);
}

test "streamed DLL enforces size cap and exact digest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const source = try std.fs.path.join(a, &.{ root, "source.dll" });
    const stage = try std.fs.path.join(a, &.{ root, "stage.tmp" });
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = source, .data = "abcd" });
    const copier: Copier = .{ .context = undefined, .copy = realCopy };
    var file = try cwd.createFile(io, stage, .{ .exclusive = true });
    try std.testing.expectError(error.SourceTooLarge, boundedCopy(io, copier, source, stage, file, 3, Io.Clock.awake.now(io).addDuration(.fromMilliseconds(1000))));
    file = try cwd.createFile(io, stage, .{ .exclusive = true });
    const copied = try boundedCopy(io, copier, source, stage, file, 4, Io.Clock.awake.now(io).addDuration(.fromMilliseconds(1000)));
    try std.testing.expectError(error.DllSizeMismatch, verifyCopy(copied, 3, &copied.digest));
    try std.testing.expectError(error.DllHashMismatch, verifyCopy(copied, 4, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try verifyCopy(copied, 4, &copied.digest);
}
