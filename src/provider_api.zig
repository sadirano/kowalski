//! Provider ABI v3. Full rules: docs/provider-contract.md.
//! A compiled-in provider exports kowalskiProvider and kowalskiProviderInfo.

/// Bumped on any incompatible change to the table or the JSON shapes below.
pub const version: u32 = 3;

pub const Bytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn of(text: []const u8) Bytes {
        return .{ .ptr = text.ptr, .len = text.len };
    }

    pub fn slice(b: Bytes) []const u8 {
        return if (b.ptr) |p| p[0..b.len] else "";
    }
};

pub const Status = extern struct {
    /// 0 is success; anything else is the provider's own code.
    code: u32 = 0,
    /// 1 when calling again cannot repeat an effect.
    retry_safe: u8 = 0,
    /// 0 when the remote may or may not have applied the call.
    outcome_known: u8 = 1,
    /// Readable detail, owned by the provider (freed with `free`).
    message: Bytes = .{},
};

pub const Table = extern struct {
    version: u32,
    /// Binding namespace of the refs this provider owns. Static.
    instance: Bytes,
    /// Static capability JSON; see docs/provider-contract.md.
    traits: Bytes = .{},
    context: ?*anyopaque,
    /// Field descriptions; see docs/provider-contract.md.
    fields: *const fn (context: ?*anyopaque, out: *Bytes) callconv(.c) Status,
    /// Looks up a ref; see docs/provider-contract.md.
    lookup: *const fn (context: ?*anyopaque, ref: Bytes, out: *Bytes) callconv(.c) Status,
    /// Quotes a post; see docs/provider-contract.md.
    quote: *const fn (context: ?*anyopaque, request: Bytes, out: *Bytes) callconv(.c) Status,
    /// Posts hours; see docs/provider-contract.md.
    post: *const fn (context: ?*anyopaque, request: Bytes, out: *Bytes) callconv(.c) Status,
    /// Describes login prompts; see docs/provider-contract.md.
    login_prompts: *const fn (context: ?*anyopaque, out: *Bytes) callconv(.c) Status,
    /// Saves login answers; see docs/provider-contract.md.
    login: *const fn (context: ?*anyopaque, answers: Bytes) callconv(.c) Status,
    /// Frees one output buffer, including a status message.
    free: *const fn (context: ?*anyopaque, buffer: Bytes) callconv(.c) void,
    /// Initializes this process's provider context before any operational call.
    init: *const fn (context: ?*anyopaque, config: Bytes, out_context: *?*anyopaque) callconv(.c) Status,
    /// Releases context after the last call, only when no call is running.
    deinit: *const fn (context: ?*anyopaque) callconv(.c) void,
};

/// The entry every provider exports. Null means it cannot serve `requested`.
pub const Entry = fn (requested: u32) callconv(.c) ?*const Table;

/// Static UTF-8 JSON metadata, valid for the process lifetime.
pub const Info = fn () callconv(.c) Bytes;
