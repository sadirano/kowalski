//! Reusable contract checks for a provider.
const std = @import("std");
const contract = @import("kowalski_provider");

pub fn check(entry: *const contract.Entry, info: *const contract.Info, data_dir: []const u8) !void {
    const a = std.testing.allocator;
    const original = entry(contract.version) orelse return error.MissingVersion;
    try std.testing.expectEqual(contract.version, original.version);
    try std.testing.expect(entry(contract.version + 1) == null);
    try std.testing.expect(original.instance.slice().len > 0);

    const metadata = try std.json.parseFromSlice(std.json.Value, a, info().slice(), .{});
    defer metadata.deinit();
    try std.testing.expect(metadata.value == .object);
    const contracts = metadata.value.object.get("contracts") orelse return error.MissingContracts;
    try std.testing.expect(contracts == .array);
    var found = false;
    for (contracts.array.items) |v| if (v == .integer and v.integer == contract.version) {
        found = true;
    };
    try std.testing.expect(found);
    try expectString(metadata.value, "name");
    try expectString(metadata.value, "build");

    if (original.traits.slice().len > 0) {
        const traits = try std.json.parseFromSlice(std.json.Value, a, original.traits.slice(), .{});
        defer traits.deinit();
        try std.testing.expect(traits.value == .object);
    }
    const config = try std.json.Stringify.valueAlloc(a, .{ .contract = contract.version, .data_dir = data_dir }, .{});
    defer a.free(config);
    var context: ?*anyopaque = null;
    const started = original.init(original.context, .of(config), &context);
    defer if (started.message.ptr != null) original.free(context, started.message);
    try std.testing.expectEqual(@as(u32, 0), started.code);
    var table = original.*;
    table.context = context;
    defer table.deinit(table.context);
    try checkArray(&table, a, .fields);
    try checkArray(&table, a, .login_prompts);
}

const ArrayKind = enum { fields, login_prompts };

fn checkArray(table: *const contract.Table, a: std.mem.Allocator, kind: ArrayKind) !void {
    var out: contract.Bytes = .{};
    const status = switch (kind) {
        .fields => table.fields(table.context, &out),
        .login_prompts => table.login_prompts(table.context, &out),
    };
    defer if (status.message.ptr != null) table.free(table.context, status.message);
    defer if (out.ptr != null) table.free(table.context, out);
    try std.testing.expectEqual(@as(u32, 0), status.code);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.slice(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    for (parsed.value.array.items) |item| {
        try std.testing.expect(item == .object);
        try expectString(item, "name");
        try expectString(item, "label");
        switch (kind) {
            .fields => {
                try expectString(item, "type");
                const order = item.object.get("order") orelse return error.MissingOrder;
                try std.testing.expect(order == .integer);
            },
            .login_prompts => if (item.object.get("secret")) |secret| try std.testing.expect(secret == .bool),
        }
    }
}

fn expectString(value: std.json.Value, key: []const u8) !void {
    const field = value.object.get(key) orelse return error.MissingKey;
    try std.testing.expect(field == .string);
    try std.testing.expect(field.string.len > 0 or std.mem.eql(u8, key, "build"));
}
