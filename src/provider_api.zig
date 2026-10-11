//! The provider contract, imported as `kowalski_provider`. A provider is a
//! versioned function table returned by one entry function. Only fixed-width
//! integers, opaque handles and UTF-8 pointer-plus-length buffers cross it;
//! the provider frees its own outputs. The same table can later be exported
//! from a DLL unchanged.
//!
//! A private build compiles a provider in with `zig build -Dprovider=<file>`;
//! that file imports this module and declares
//! `pub fn kowalskiProvider(requested: u32) callconv(.c) ?*const Table`.

/// Bumped on any incompatible change to the table or the JSON shapes below.
pub const version: u32 = 2;

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
    /// Static JSON with what the provider allows, every key optional:
    /// `{"link":"https://..{ref}..","paid_breaks":[{"from":"HH:MM","to":"HH:MM","minutes":N}],
    ///   "settings":[..],"post_options":[..],"sessions":true}`.
    /// `sessions` declares that posts may include local `start` and `end`.
    /// `link` opens a ref (`{ref}` is replaced, percent-encoded). A pause
    /// inside a paid break window counts as worked time, up to `minutes`.
    /// `settings` (up to 16): `{"name":"a_z0_9","label":..,"labels":{..},
    /// "hint":..,"hints":{..},"type":"choice"|"text","choices":[{"value":..,
    /// "label":..,"labels":{..}}],"default":..}`, shown in Settings and kept
    /// as `provider.<name>`. `post_options` (up to 16): the same without
    /// choices and default, `"type":"bool"`, chosen per post. Each list is
    /// dropped whole if malformed, and each bad entry on its own.
    traits: Bytes = .{},
    context: ?*anyopaque,
    /// Output: JSON `[{"name":..,"label":..,"type":..,"order":..}]`. A field
    /// may add `"labels":{"<lang>":".."}` (pt, ja) for the dashboard; `label`
    /// stays the English one the CLI prints.
    fields: *const fn (context: ?*anyopaque, out: *Bytes) callconv(.c) Status,
    /// Output: JSON `{"title":..,"fields":{"<name>":"<value>"}}` for an external ref.
    lookup: *const fn (context: ?*anyopaque, ref: Bytes, out: *Bytes) callconv(.c) Status,
    /// Request: JSON with day, ref, day_over, task_open, total_focus_ms and
    /// confirmed `posted` amounts (oldest first). Output: JSON with post,
    /// reason, amount_text and amount_micro. The provider owns posting policy.
    quote: *const fn (context: ?*anyopaque, request: Bytes, out: *Bytes) callconv(.c) Status,
    /// Request: JSON with stable posting_id, day, ref, amount_text,
    /// amount_micro, text, the task's title, the policy inputs, `settings`
    /// (every declared setting, stored or default) and `options` (every
    /// declared post option). A session post also carries `start` and `end`
    /// as local "HH:MM" on the same day; a session reaching midnight uses
    /// end "23:59". That entry covers the span, and amount_* is the quoted
    /// amount for that session. Output may be empty, or JSON with accepted
    /// amount_text, amount_micro and arbitrary data.
    post: *const fn (context: ?*anyopaque, request: Bytes, out: *Bytes) callconv(.c) Status,
    /// Output: JSON `[{"name":..,"label":..,"secret":bool}]`, what `login`
    /// asks for, in order, with optional `labels` as for `fields`. The CLI
    /// and the dashboard mask secret answers.
    login_prompts: *const fn (context: ?*anyopaque, out: *Bytes) callconv(.c) Status,
    /// Called with JSON `{"<name>":"<answer>"}` for the login prompts, from
    /// the CLI process or, for the dashboard, on the daemon's provider
    /// worker like any other call. The provider saves what it needs itself.
    login: *const fn (context: ?*anyopaque, answers: Bytes) callconv(.c) Status,
    /// Frees one output buffer, including a status message.
    free: *const fn (context: ?*anyopaque, buffer: Bytes) callconv(.c) void,
};

/// The entry every provider exports. Null means it cannot serve `requested`.
pub const Entry = fn (requested: u32) callconv(.c) ?*const Table;
