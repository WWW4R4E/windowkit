//! 浏览器侧 `std.Io` 的时钟支持。
//!
//! 浏览器应用对异步服务都是通过显式 JS 回调驱动的，所以不被支持的
//! 操作保留 `std.Io.failing` 语义。时钟是例外：动画与交互计时需要
//! 一个单调推进的时钟源，哪怕并不存在通用的 WASM I/O 后端。

const std = @import("std");
const imports = @import("imports.zig");

const nanoseconds_per_millisecond: f64 = @floatFromInt(std.time.ns_per_ms);

pub const browser: std.Io = .{
    .userdata = null,
    .vtable = &browser_vtable,
};

const browser_vtable: std.Io.VTable = blk: {
    var vtable = std.Io.failing.vtable.*;
    vtable.now = now;
    vtable.clockResolution = clockResolution;
    break :blk vtable;
};

comptime {
    std.debug.assert(browser_vtable.now != std.Io.failing.vtable.now);
    std.debug.assert(browser_vtable.clockResolution != std.Io.failing.vtable.clockResolution);
}

fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    std.debug.assert(userdata == null);

    const milliseconds = switch (clock) {
        .real => imports.getTimestampMillis(),
        .awake, .boot => imports.getFrameTime(),
        .cpu_process, .cpu_thread => return .zero,
    };
    std.debug.assert(std.math.isFinite(milliseconds));
    std.debug.assert(milliseconds >= 0);

    const nanoseconds: i96 = @intFromFloat(milliseconds * nanoseconds_per_millisecond);
    return std.Io.Timestamp.fromNanoseconds(nanoseconds);
}

fn clockResolution(
    userdata: ?*anyopaque,
    clock: std.Io.Clock,
) std.Io.Clock.ResolutionError!std.Io.Duration {
    std.debug.assert(userdata == null);
    std.debug.assert(std.time.ns_per_ms > 0);

    return switch (clock) {
        .real, .awake, .boot => .{ .nanoseconds = std.time.ns_per_ms },
        .cpu_process, .cpu_thread => error.ClockUnavailable,
    };
}
