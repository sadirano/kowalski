//! A minimal provider showing the contract in src/provider_api.zig. It talks
//! to nothing: lookups echo the ref, posts succeed. Build kowalski with it:
//!
//!     zig build -Dprovider=examples/provider.zig
//!
//! A real provider keeps its own HTTP/TLS, sessions and credentials (Windows
//! Credential Manager) and never hands secrets to kowalski.
const std = @import("std");
const k = @import("kowalski_provider");

const allocator = std.heap.page_allocator;

fn give(text: []const u8, out: *k.Bytes) bool {
    const copy = allocator.dupe(u8, text) catch return false;
    out.* = .of(copy);
    return true;
}

fn outOfMemory() k.Status {
    return .{ .code = 1, .retry_safe = 1 };
}

fn fields(_: ?*anyopaque, out: *k.Bytes) callconv(.c) k.Status {
    if (!give("[{\"name\":\"echo\",\"label\":\"Echoed ref\",\"type\":\"text\",\"order\":1}]", out)) return outOfMemory();
    return .{};
}

fn lookup(_: ?*anyopaque, ref: k.Bytes, out: *k.Bytes) callconv(.c) k.Status {
    const json = std.json.Stringify.valueAlloc(allocator, .{ .title = ref.slice(), .fields = .{ .echo = ref.slice() } }, .{}) catch return outOfMemory();
    out.* = .of(json);
    return .{};
}

/// Hours to two decimals, rounded up; only the unposted difference is quoted.
fn quote(_: ?*anyopaque, request: k.Bytes, out: *k.Bytes) callconv(.c) k.Status {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct { total_focus_ms: i64, posted: []struct { amount_micro: i64 } };
    const input = std.json.parseFromSliceLeaky(Input, a, request.slice(), .{ .ignore_unknown_fields = true }) catch return .{ .code = 1 };
    const hundredths: i64 = @divFloor(input.total_focus_ms + 36_000 - 1, 36_000);
    var posted_micro: i64 = 0;
    for (input.posted) |p| posted_micro += p.amount_micro;
    const micro = @max(0, hundredths * 10_000 - posted_micro);
    var buffer: [32]u8 = undefined;
    const printed = std.fmt.bufPrint(&buffer, "{d}.{d:0>2}", .{ @divFloor(micro, 1_000_000), @divFloor(@mod(micro, 1_000_000), 10_000) }) catch unreachable;
    const json = std.json.Stringify.valueAlloc(a, .{ .post = true, .reason = "", .amount_text = printed, .amount_micro = micro }, .{}) catch return outOfMemory();
    if (!give(json, out)) return outOfMemory();
    return .{};
}

fn post(_: ?*anyopaque, request: k.Bytes, out: *k.Bytes) callconv(.c) k.Status {
    _ = request;
    if (!give("{\"data\":{\"example\":true}}", out)) return .{ .code = 1, .outcome_known = 0 };
    return .{};
}

fn loginPrompts(_: ?*anyopaque, out: *k.Bytes) callconv(.c) k.Status {
    if (!give("[{\"name\":\"token\",\"label\":\"Token\",\"secret\":true}]", out)) return outOfMemory();
    return .{};
}

fn login(_: ?*anyopaque, answers: k.Bytes) callconv(.c) k.Status {
    // This example has no remote account and deliberately stores nothing.
    return if (answers.slice().len > 0) .{} else .{ .code = 1 };
}

fn free(_: ?*anyopaque, buffer: k.Bytes) callconv(.c) void {
    allocator.free(@constCast(buffer.slice()));
}

const table: k.Table = .{
    .version = k.version,
    .instance = .of("example"),
    .traits = .of("{\"link\":\"https://tickets.example/{ref}\"}"),
    .context = null,
    .fields = fields,
    .lookup = lookup,
    .quote = quote,
    .post = post,
    .login_prompts = loginPrompts,
    .login = login,
    .free = free,
};

pub fn kowalskiProvider(requested: u32) callconv(.c) ?*const k.Table {
    return if (requested == k.version) &table else null;
}
