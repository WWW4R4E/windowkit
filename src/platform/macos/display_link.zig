//! CVDisplayLink 封装：vsync 同步的渲染节拍。
//!
//! CVDisplayLink 提供一条与显示器刷新率同步的高优先级线程回调。
//!
//! 参考: https://developer.apple.com/documentation/corevideo/cvdisplaylink
//!
//! ## 为什么用 CVDisplayLink 而不是 CADisplayLink？
//!
//! `CADisplayLink` 是较新的 Core Animation API（macOS 14+），本层坚持
//! `CVDisplayLink` 有两个原因：
//!
//! 1. **专用 vsync 线程，不走 run loop。** CVDisplayLink 回调跑在
//!    CoreVideo 管理的高优先级线程上；macOS 的 CADisplayLink 经主
//!    run loop 派发，会和 AppKit 事件、NSTimer、追踪区域互相挤占。
//!    每个全操优先的渲染回调用专用线程更稳。
//! 2. **直接钉住 ProMotion。** `CVDisplayLinkSetCurrentCGDisplay` 能
//!    可靠地把 link 绑到指定显示器的刷新率；CADisplayLink 的
//!    `preferredFrameRateRange` 只是 macOS 可以自适应忽略的提示。
//!
//! ## 设计取舍
//!
//! 本层选择在 vsync 线程上直接渲染、用 `Window.render_mutex` 做同步
//! （见 `src/platform/mutex.zig`），而不是像 Zed 的 GPUI 那样把渲染
//! 弹回主线程 —— 两者都成立，这里取的是更低延迟、代价是一把锁。
//! 另一个教训：`CVDisplayLinkRelease` 曾被观察到与 CV timer 线程
//! 竞争引发偶发段错误；本层在 `deinit` 中先 `stop()`（同步返回）再
//! release，竞争窗口应当已关闭。若窗口关闭时出现同类崩溃，放弃
//! release、直接泄漏 link 是已知的止血方案（每窗口有界代价）。

const std = @import("std");
const objc = @import("objc");

// ============================================================================
// CoreVideo 类型
// ============================================================================

/// CVDisplayLink 的不透明引用
pub const CVDisplayLinkRef = *opaque {};

/// CVReturn 错误码
pub const CVReturn = enum(i32) {
    success = 0,
    first = -6660,
    invalid_argument = -6661,
    allocation_failed = -6662,
    unsupported = -6663,
    // DisplayLink 专用错误
    invalid_display = -6670,
    display_link_already_running = -6671,
    display_link_not_running = -6672,
    display_link_callbacks_not_set = -6673,
    _,

    pub fn isSuccess(self: CVReturn) bool {
        return self == .success;
    }
};

/// CVTimeStamp —— 传给 display link 回调的时间信息
pub const CVTimeStamp = extern struct {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
    smpte_time: SMPTETime,
    flags: u64,
    reserved: u64,
};

/// SMPTE 时间码格式
pub const SMPTETime = extern struct {
    subframes: i16,
    subframe_divisor: i16,
    counter: u32,
    type: u32,
    flags: u32,
    hours: i16,
    minutes: i16,
    seconds: i16,
    frames: i16,
};

/// CVDisplayLink 输出回调签名
pub const CVDisplayLinkOutputCallback = *const fn (
    display_link: CVDisplayLinkRef,
    in_now: *const CVTimeStamp,
    in_output_time: *const CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) CVReturn;

// ============================================================================
// CoreVideo 外部函数
// ============================================================================

/// 为活跃显示器集合创建 display link
pub extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(
    display_link_out: *?CVDisplayLinkRef,
) CVReturn;

/// 设置 display link 的输出回调
pub extern "c" fn CVDisplayLinkSetOutputCallback(
    display_link: CVDisplayLinkRef,
    callback: CVDisplayLinkOutputCallback,
    user_info: ?*anyopaque,
) CVReturn;

/// 启动 display link
pub extern "c" fn CVDisplayLinkStart(display_link: CVDisplayLinkRef) CVReturn;

/// 停止 display link
pub extern "c" fn CVDisplayLinkStop(display_link: CVDisplayLinkRef) CVReturn;

/// 查询 display link 是否在运行
pub extern "c" fn CVDisplayLinkIsRunning(display_link: CVDisplayLinkRef) bool;

/// 释放 display link
pub extern "c" fn CVDisplayLinkRelease(display_link: CVDisplayLinkRef) void;

/// 取标称刷新率
pub extern "c" fn CVDisplayLinkGetNominalOutputVideoRefreshPeriod(
    display_link: CVDisplayLinkRef,
) CVTime;

/// 标称刷新周期对应的 CVTime
pub const CVTime = extern struct {
    time_value: i64,
    time_scale: i32,
    flags: i32,
};

/// 把 display link 绑定到指定显示器。
/// 不靠 macOS 按内容自适应改刷新率，而是钉死 link 与显示器的绑定，
/// ProMotion 屏上的帧率才能稳定。
pub extern "c" fn CVDisplayLinkSetCurrentCGDisplay(
    display_link: CVDisplayLinkRef,
    display_id: u32,
) CVReturn;

/// 取主显示器 ID（来自 CoreGraphics）
pub extern "c" fn CGMainDisplayID() u32;

// ============================================================================
// DisplayLink 封装
// ============================================================================

/// 渲染回调类型 —— 每个 vsync 触发
pub const RenderCallback = *const fn (user_data: ?*anyopaque) void;

/// CVDisplayLink 的高层封装
pub const DisplayLink = struct {
    link: CVDisplayLinkRef,
    running: std.atomic.Value(bool),

    const Self = @This();

    /// 创建 display link（启动前必须先设回调）
    pub fn init() !Self {
        var link: ?CVDisplayLinkRef = null;

        // 为活跃显示器集合创建 link
        const create_result = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        if (!create_result.isSuccess() or link == null) {
            return error.DisplayLinkCreationFailed;
        }

        // 绑定主显示器，ProMotion 屏的帧率才稳定。不绑的话，用户交互后
        // macOS 可能自适应降刷新率（如 120Hz → 60Hz）。
        const main_display = CGMainDisplayID();
        _ = CVDisplayLinkSetCurrentCGDisplay(link.?, main_display);

        return Self{
            .link = link.?,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// 设置渲染回调与用户数据
    /// 重要：user_data 必须指向比 DisplayLink 活得久的内存！
    pub fn setCallback(self: *Self, callback: CVDisplayLinkOutputCallback, user_data: ?*anyopaque) !void {
        const result = CVDisplayLinkSetOutputCallback(self.link, callback, user_data);
        if (!result.isSuccess()) {
            return error.DisplayLinkCallbackFailed;
        }
    }

    /// 启动 display link（开始 vsync 回调）
    pub fn start(self: *Self) !void {
        const result = CVDisplayLinkStart(self.link);
        if (!result.isSuccess()) {
            return error.DisplayLinkStartFailed;
        }
        self.running.store(true, .release);
    }

    /// 停止 display link
    pub fn stop(self: *Self) void {
        if (self.running.load(.acquire)) {
            _ = CVDisplayLinkStop(self.link);
            self.running.store(false, .release);
        }
    }

    /// 是否在运行
    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    /// 释放资源。
    ///
    /// 已知题：`CVDisplayLinkRelease` 与 CV timer 线程竞争曾引发偶发段
    /// 错误（Zed 的止血方案是干脆泄漏 link）。这里先 `stop()` 同步
    /// 返回再 release，竞争窗口应当已关闭。若窗口关闭时出现同类崩溃，
    /// 跳过 release 是已知可行的替代。
    pub fn deinit(self: *Self) void {
        self.stop();
        CVDisplayLinkRelease(self.link);
    }

    /// 取刷新率（Hz）
    pub fn getRefreshRate(self: *const Self) f64 {
        const period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(self.link);
        if (period.time_scale > 0 and period.time_value > 0) {
            return @as(f64, @floatFromInt(period.time_scale)) /
                @as(f64, @floatFromInt(period.time_value));
        }
        return 60.0; // 兜底默认值
    }
};

/// 辅助：创建一个什么都不做、只返回成功的 display link 回调
pub fn makeDisplayLinkCallback(
    display_link: CVDisplayLinkRef,
    in_now: *const CVTimeStamp,
    in_output_time: *const CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) CVReturn {
    _ = display_link;
    _ = in_now;
    _ = in_output_time;
    _ = flags_in;
    _ = flags_out;
    _ = user_info;
    return .success;
}
