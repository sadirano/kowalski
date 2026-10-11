//! Windows session and power events, received by a hidden top-level window on
//! its own thread. Message-only windows miss broadcasts such as
//! WM_POWERBROADCAST, so the window is a normal one that is never shown.
const std = @import("std");

pub const Kind = enum { suspending, resumed, locked, ending };
pub const Handler = *const fn (context: *anyopaque, kind: Kind) void;

/// Also used by scripts/events-smoke.ps1 to find the window.
pub const class_name = "sadirano-kowalski-events";

const Hwnd = *anyopaque;
const WndProc = *const fn (?Hwnd, u32, usize, isize) callconv(.winapi) isize;

const WndClassExW = extern struct {
    cbSize: u32 = @sizeOf(WndClassExW),
    style: u32 = 0,
    lpfnWndProc: WndProc,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const Msg = extern struct {
    hwnd: ?Hwnd,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: extern struct { x: i32, y: i32 },
    lPrivate: u32,
};

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.winapi) u16;
extern "user32" fn UnregisterClassW(name: [*:0]const u16, instance: ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?Hwnd, menu: ?*anyopaque, instance: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?Hwnd;
extern "user32" fn DestroyWindow(hwnd: Hwnd) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(hwnd: ?Hwnd, msg: u32, w: usize, l: isize) callconv(.winapi) isize;
extern "user32" fn GetMessageW(msg: *Msg, hwnd: ?Hwnd, min: u32, max: u32) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(msg: *const Msg) callconv(.winapi) isize;
extern "user32" fn PostMessageW(hwnd: Hwnd, msg: u32, w: usize, l: isize) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
extern "wtsapi32" fn WTSRegisterSessionNotification(hwnd: Hwnd, flags: u32) callconv(.winapi) i32;
extern "wtsapi32" fn WTSUnRegisterSessionNotification(hwnd: Hwnd) callconv(.winapi) i32;

const wm_destroy: u32 = 0x0002;
const wm_close: u32 = 0x0010;
const wm_queryendsession: u32 = 0x0011;
const wm_endsession: u32 = 0x0016;
const wm_powerbroadcast: u32 = 0x0218;
const wm_wtssession_change: u32 = 0x02B1;
const pbt_apmsuspend: usize = 0x0004;
const pbt_apmresumesuspend: usize = 0x0007;
const pbt_apmresumeautomatic: usize = 0x0012;
const wts_session_lock: usize = 0x7;
const notify_for_this_session: u32 = 0;

// One window per process; the window procedure reaches the handler here.
var handler: ?Handler = null;
var handler_context: ?*anyopaque = null;

fn windowProc(hwnd: ?Hwnd, msg: u32, w: usize, l: isize) callconv(.winapi) isize {
    switch (msg) {
        wm_powerbroadcast => {
            switch (w) {
                pbt_apmsuspend => deliver(.suspending),
                // Both arrive after a user-driven wake; recovery is idempotent.
                pbt_apmresumesuspend, pbt_apmresumeautomatic => deliver(.resumed),
                else => {},
            }
            return 1;
        },
        wm_wtssession_change => {
            if (w == wts_session_lock) deliver(.locked);
            return 0;
        },
        wm_queryendsession => return 1,
        wm_endsession => {
            // Windows may end the process once this returns.
            if (w != 0) deliver(.ending);
            return 0;
        },
        wm_close => {
            _ = DestroyWindow(hwnd.?);
            return 0;
        },
        wm_destroy => {
            _ = WTSUnRegisterSessionNotification(hwnd.?);
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, w, l),
    }
}

fn deliver(kind: Kind) void {
    if (handler) |h| h(handler_context.?, kind);
}

pub const Window = struct {
    thread: std.Thread,
    hwnd: Hwnd,

    /// Creates the window on a new thread and returns once it exists.
    pub fn start(context: *anyopaque, on_event: Handler) !Window {
        handler = on_event;
        handler_context = context;
        var created: Created = .{};
        const thread = try std.Thread.spawn(.{}, run, .{&created});
        while (created.state.load(.acquire) == .pending) std.Thread.yield() catch {};
        if (created.state.load(.acquire) == .failed) {
            thread.join();
            return error.EventWindow;
        }
        return .{ .thread = thread, .hwnd = created.hwnd.? };
    }

    /// Closes the window and waits for its thread.
    pub fn stop(w: *Window) void {
        _ = PostMessageW(w.hwnd, wm_close, 0, 0);
        w.thread.join();
        handler = null;
        handler_context = null;
    }
};

const Created = struct {
    state: std.atomic.Value(enum(u8) { pending, ready, failed }) = .init(.pending),
    hwnd: ?Hwnd = null,
};

fn run(created: *Created) void {
    const class = std.unicode.utf8ToUtf16LeStringLiteral(class_name);
    const instance = GetModuleHandleW(null);
    const registered = RegisterClassExW(&.{ .lpfnWndProc = windowProc, .hInstance = instance, .lpszClassName = class }) != 0;
    defer if (registered) {
        _ = UnregisterClassW(class, instance);
    };
    const hwnd = if (registered) CreateWindowExW(0, class, class, 0, 0, 0, 0, 0, null, null, instance, null) else null;
    if (hwnd == null) {
        created.state.store(.failed, .release);
        return;
    }
    // Without it lock events are lost but power events still arrive.
    _ = WTSRegisterSessionNotification(hwnd.?, notify_for_this_session);
    created.hwnd = hwnd;
    created.state.store(.ready, .release);

    var msg: Msg = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) _ = DispatchMessageW(&msg);
}

test "the event window starts, delivers a posted lock and stops" {
    const Seen = struct {
        kinds: std.atomic.Value(u32) = .init(0),
        fn on(context: *anyopaque, kind: Kind) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.kinds.fetchOr(@as(u32, 1) << @intFromEnum(kind), .acq_rel);
        }
    };
    var seen: Seen = .{};
    var window = try Window.start(&seen, Seen.on);
    _ = PostMessageW(window.hwnd, wm_wtssession_change, wts_session_lock, 0);
    _ = PostMessageW(window.hwnd, wm_powerbroadcast, pbt_apmresumeautomatic, 0);
    window.stop();
    try std.testing.expectEqual(@as(u32, 0b0110), seen.kinds.load(.acquire));
}
