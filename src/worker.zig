//! Runs provider calls one at a time, off the caller's thread and never under
//! the database lock. A deadline bounds how long the caller waits; it does not
//! cancel the call. While a timed-out call is still running, new calls fail
//! at once with `busy`. A stuck call never holds up shutdown.
const std = @import("std");
const Io = std.Io;
const contract = @import("kowalski_provider");

pub const Call = union(enum) {
    fields,
    lookup: []const u8,
    quote: []const u8,
    post: struct { posting: i64, request: []const u8 },
    login_prompts,
    /// JSON answers to the login prompts; secrets, wiped after the call.
    login: []const u8,
};

pub const Done = struct {
    code: u32,
    retry_safe: bool,
    outcome_known: bool,
    message: []const u8,
    /// Provider output, copied before the provider frees its buffer.
    out: []const u8,

    pub fn ok(d: Done) bool {
        return d.code == 0;
    }
};

pub const Outcome = union(enum) {
    done: Done,
    /// The previous call has not returned yet; this one was not made.
    busy,
    /// Gave up waiting; the call may still complete or have completed.
    deadline,
};

// Process-wide: a call can outlive the daemon that started it.
var running: std.atomic.Value(bool) = .init(false);
var running_post: std.atomic.Value(i64) = .init(0);

pub fn runningPost() ?i64 {
    const id = running_post.load(.acquire);
    return if (id == 0) null else id;
}
// Jobs use the page allocator: one leaked by a stuck call at exit is expected.
const job_allocator = std.heap.page_allocator;

const Job = struct {
    table: *const contract.Table,
    call: Call,
    /// Owned copies of the call's input.
    input: []u8,
    result: Done = undefined,
    finished: Io.Event = .unset,
    /// The caller and the thread each hold one; the last to let go frees.
    refs: std.atomic.Value(u8) = .init(2),
    io: Io,
    late: ?*const fn (context: *anyopaque, posting: i64, done: Done) void,
    late_context: ?*anyopaque,
    /// 0: waiting; 1: caller timed out; 2: result belongs to caller.
    waiter: std.atomic.Value(u8) = .init(0),

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        // The input can hold login answers.
        @memset(job.input, 0);
        job_allocator.free(job.input);
        if (job.finished.isSet()) {
            job_allocator.free(job.result.message);
            job_allocator.free(job.result.out);
        }
        job_allocator.destroy(job);
    }
};

pub const Worker = struct {
    table: *const contract.Table,
    io: Io,
    late: ?*const fn (context: *anyopaque, posting: i64, done: Done) void = null,
    late_context: ?*anyopaque = null,

    pub fn instance(w: Worker) []const u8 {
        return w.table.instance.slice();
    }

    /// Makes one call, waiting at most `deadline_ms`. Results are copied into `a`.
    pub fn run(w: Worker, a: std.mem.Allocator, call: Call, deadline_ms: i64) !Outcome {
        if (running.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return .busy;
        running_post.store(if (call == .post) call.post.posting else 0, .release);
        const job = job_allocator.create(Job) catch |err| {
            running_post.store(0, .release);
            running.store(false, .release);
            return err;
        };
        const input: []const u8 = switch (call) {
            .lookup, .quote, .login => |value| value,
            .post => |p| p.request,
            else => "",
        };
        job.* = .{ .table = w.table, .call = call, .input = job_allocator.dupe(u8, input) catch |err| {
            job_allocator.destroy(job);
            running_post.store(0, .release);
            running.store(false, .release);
            return err;
        }, .io = w.io, .late = w.late, .late_context = w.late_context };
        switch (job.call) {
            .lookup => job.call = .{ .lookup = job.input },
            .quote => job.call = .{ .quote = job.input },
            .login => job.call = .{ .login = job.input },
            .post => |p| job.call = .{ .post = .{ .posting = p.posting, .request = job.input } },
            else => {},
        }
        const thread = std.Thread.spawn(.{}, work, .{job}) catch |err| {
            job_allocator.free(job.input);
            job_allocator.destroy(job);
            running_post.store(0, .release);
            running.store(false, .release);
            return err;
        };
        thread.detach();
        defer job.release();
        job.finished.waitTimeout(w.io, .{ .duration = .{ .raw = .fromMilliseconds(deadline_ms), .clock = .awake } }) catch {
            if (job.waiter.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) return .deadline;
            while (!job.finished.isSet()) std.Thread.yield() catch {};
        };
        const r = job.result;
        return .{ .done = .{
            .code = r.code,
            .retry_safe = r.retry_safe,
            .outcome_known = r.outcome_known,
            .message = try a.dupe(u8, r.message),
            .out = try a.dupe(u8, r.out),
        } };
    }
};

/// Makes one call on this thread, for a provider that answers at once (the
/// tour's). It shares nothing with the worker's one-call-at-a-time state.
pub fn runInline(table: *const contract.Table, a: std.mem.Allocator, call: Call) !Outcome {
    var out: contract.Bytes = .{};
    const status = switch (call) {
        .fields => table.fields(table.context, &out),
        .lookup => |ref| table.lookup(table.context, .of(ref), &out),
        .quote => |request| table.quote(table.context, .of(request), &out),
        .post => |p| table.post(table.context, .of(p.request), &out),
        .login_prompts => table.login_prompts(table.context, &out),
        .login => |answers| table.login(table.context, .of(answers)),
    };
    defer if (status.message.ptr != null) table.free(table.context, status.message);
    defer if (out.ptr != null) table.free(table.context, out);
    return .{ .done = .{
        .code = status.code,
        .retry_safe = status.retry_safe != 0,
        .outcome_known = status.outcome_known != 0,
        .message = try a.dupe(u8, status.message.slice()),
        .out = try a.dupe(u8, out.slice()),
    } };
}

fn work(job: *Job) void {
    defer job.release();
    const t = job.table;
    var out: contract.Bytes = .{};
    const status = switch (job.call) {
        .fields => t.fields(t.context, &out),
        .lookup => |ref| t.lookup(t.context, .of(ref), &out),
        .quote => |request| t.quote(t.context, .of(request), &out),
        .post => |p| t.post(t.context, .of(p.request), &out),
        .login_prompts => t.login_prompts(t.context, &out),
        .login => |answers| t.login(t.context, .of(answers)),
    };
    const message = job_allocator.dupe(u8, status.message.slice()) catch &.{};
    const copied = job_allocator.dupe(u8, out.slice()) catch &.{};
    if (status.message.ptr != null) t.free(t.context, status.message);
    if (out.ptr != null) t.free(t.context, out);
    job.result = .{
        .code = status.code,
        .retry_safe = status.retry_safe != 0,
        .outcome_known = status.outcome_known != 0,
        .message = message,
        .out = copied,
    };
    const waiter = job.waiter.cmpxchgStrong(0, 2, .acq_rel, .acquire);
    if (waiter != null and waiter.? == 1 and job.call == .post) {
        if (job.late) |late| if (job.late_context) |context| late(context, job.call.post.posting, job.result);
    }
    running_post.store(0, .release);
    running.store(false, .release);
    job.finished.set(job.io);
}

// ---------------------------------------------------------------- tests

/// A fake provider for tests: `ref` "slow" blocks until `release` is set.
pub const Fake = struct {
    pub var release: std.atomic.Value(bool) = .init(true);
    pub var posted: std.atomic.Value(u32) = .init(0);
    pub var seen_posting: std.atomic.Value(i64) = .init(0);
    pub var fake_policy_past_only: bool = false;
    pub var post_output: ?[]const u8 = null;
    /// Next post fails with this code and outcome (0 = succeed).
    pub var post_code: u32 = 0;
    pub var post_known: u8 = 1;
    pub var fail_on_call: u32 = 0;
    pub var post_calls: u32 = 0;
    pub var requests: [8][4096]u8 = undefined;
    pub var request_lens: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    /// The last post request, for tests that check what was sent.
    pub var last_post: [4096]u8 = undefined;
    pub var last_post_len: usize = 0;

    fn give(text: []const u8, out: *contract.Bytes) void {
        const copy = std.heap.page_allocator.dupe(u8, text) catch return;
        out.* = .of(copy);
    }
    fn fields(_: ?*anyopaque, out: *contract.Bytes) callconv(.c) contract.Status {
        give("[{\"name\":\"client\",\"label\":\"Client\",\"type\":\"text\",\"order\":1}]", out);
        return .{};
    }
    fn lookup(_: ?*anyopaque, ref: contract.Bytes, out: *contract.Bytes) callconv(.c) contract.Status {
        if (std.mem.eql(u8, ref.slice(), "slow")) {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
        }
        if (std.mem.eql(u8, ref.slice(), "missing")) {
            var message: contract.Bytes = .{};
            give("no such ticket", &message);
            return .{ .code = 404, .retry_safe = 1, .message = message };
        }
        give("{\"title\":\"Remote title\",\"fields\":{\"client\":\"Example\"}}", out);
        return .{};
    }
    fn quote(_: ?*anyopaque, request: contract.Bytes, out: *contract.Bytes) callconv(.c) contract.Status {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const Input = struct { day_over: bool, total_focus_ms: i64, posted: []struct { amount_micro: i64 } };
        const input = std.json.parseFromSliceLeaky(Input, a, request.slice(), .{ .ignore_unknown_fields = true }) catch return .{ .code = 1 };
        if (fake_policy_past_only and !input.day_over) {
            give("{\"post\":false,\"reason\":\"day not over\",\"amount_text\":\"\",\"amount_micro\":0}", out);
            return .{};
        }
        const quarters = @divFloor(input.total_focus_ms + 15 * 60_000 - 1, 15 * 60_000);
        var posted_micro: i64 = 0;
        for (input.posted) |p| posted_micro += p.amount_micro;
        const micro = @max(0, quarters * 250_000 - posted_micro);
        var buffer: [32]u8 = undefined;
        const amount = std.fmt.bufPrint(&buffer, "{d}.{d:0>2}", .{ @divFloor(micro, 1_000_000), @divFloor(@mod(micro, 1_000_000), 10_000) }) catch return .{ .code = 1 };
        const json = std.json.Stringify.valueAlloc(a, .{ .post = true, .reason = "", .amount_text = amount, .amount_micro = micro }, .{}) catch return .{ .code = 1 };
        give(json, out);
        return .{};
    }
    fn post(_: ?*anyopaque, request: contract.Bytes, out: *contract.Bytes) callconv(.c) contract.Status {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const Input = struct { posting_id: i64 };
        const input = std.json.parseFromSliceLeaky(Input, arena.allocator(), request.slice(), .{ .ignore_unknown_fields = true }) catch return .{ .code = 1 };
        seen_posting.store(input.posting_id, .release);
        last_post_len = @min(request.slice().len, last_post.len);
        @memcpy(last_post[0..last_post_len], request.slice()[0..last_post_len]);
        post_calls += 1;
        if (post_calls <= requests.len) {
            request_lens[post_calls - 1] = last_post_len;
            @memcpy(requests[post_calls - 1][0..last_post_len], last_post[0..last_post_len]);
        }
        if (std.mem.indexOf(u8, request.slice(), "\"ref\":\"slow\"") != null) {
            while (!release.load(.acquire)) std.Thread.yield() catch {};
        }
        if (post_code != 0 and (fail_on_call == 0 or post_calls == fail_on_call)) return .{ .code = post_code, .outcome_known = post_known };
        _ = posted.fetchAdd(1, .acq_rel);
        give(post_output orelse "{\"data\":{\"entry\":42}}", out);
        return .{};
    }
    fn loginPrompts(_: ?*anyopaque, out: *contract.Bytes) callconv(.c) contract.Status {
        give("[{\"name\":\"token\",\"label\":\"Token\",\"secret\":true}]", out);
        return .{};
    }
    fn login(_: ?*anyopaque, answers: contract.Bytes) callconv(.c) contract.Status {
        return if (answers.slice().len > 0) .{} else .{ .code = 1 };
    }
    fn free(_: ?*anyopaque, buffer: contract.Bytes) callconv(.c) void {
        std.heap.page_allocator.free(@constCast(buffer.slice()));
    }
    pub const table: contract.Table = .{
        .version = contract.version,
        .instance = .of("fake"),
        .traits = .of("{\"sessions\":true,\"link\":\"https://tickets.example/t/{ref}\",\"paid_breaks\":[{\"from\":\"08:00\",\"to\":\"12:00\",\"minutes\":15},{\"from\":\"13:00\",\"to\":\"18:00\",\"minutes\":15}]}"),
        .context = null,
        .fields = fields,
        .lookup = lookup,
        .quote = quote,
        .post = post,
        .login_prompts = loginPrompts,
        .login = login,
        .free = free,
    };
};

test "calls return copies, a stuck call times out and leaves the worker busy" {
    const w: Worker = .{ .table = &Fake.table, .io = std.testing.io };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const looked = try w.run(a, .{ .lookup = "T-1" }, 5_000);
    try std.testing.expect(looked.done.ok());
    try std.testing.expect(std.mem.indexOf(u8, looked.done.out, "Remote title") != null);
    const missing = try w.run(a, .{ .lookup = "missing" }, 5_000);
    try std.testing.expectEqual(@as(u32, 404), missing.done.code);
    try std.testing.expectEqualStrings("no such ticket", missing.done.message);
    const quoted = try w.run(a, .{ .quote = "{\"day_over\":true,\"total_focus_ms\":3660000,\"posted\":[]}" }, 5_000);
    try std.testing.expect(std.mem.indexOf(u8, quoted.done.out, "\"amount_micro\":1250000") != null);

    Fake.release.store(false, .release);
    try std.testing.expectEqual(Outcome.deadline, try w.run(a, .{ .lookup = "slow" }, 50));
    try std.testing.expectEqual(Outcome.busy, try w.run(a, .fields, 5_000));
    Fake.release.store(true, .release);
    while (running.load(.acquire)) std.Thread.yield() catch {};
    const fields = try w.run(a, .fields, 5_000);
    try std.testing.expect(std.mem.indexOf(u8, fields.done.out, "\"client\"") != null);
}

test "a late post calls its handler once with the stable id" {
    const Seen = struct { count: u32 = 0, posting: i64 = 0 };
    const Handler = struct {
        fn call(context: *anyopaque, posting: i64, done: Done) void {
            const seen: *Seen = @ptrCast(@alignCast(context));
            seen.count += 1;
            seen.posting = posting;
            std.debug.assert(done.ok());
        }
    };
    var seen: Seen = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w: Worker = .{ .table = &Fake.table, .io = std.testing.io, .late = Handler.call, .late_context = &seen };
    Fake.release.store(false, .release);
    defer Fake.release.store(true, .release);
    try std.testing.expectEqual(Outcome.deadline, try w.run(arena.allocator(), .{ .post = .{ .posting = 42, .request = "{\"posting_id\":42,\"ref\":\"slow\"}" } }, 50));
    try std.testing.expectEqual(@as(?i64, 42), runningPost());
    Fake.release.store(true, .release);
    while (runningPost() != null) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u32, 1), seen.count);
    try std.testing.expectEqual(@as(i64, 42), seen.posting);
    try std.testing.expectEqual(@as(i64, 42), Fake.seen_posting.load(.acquire));
}
