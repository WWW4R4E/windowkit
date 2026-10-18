//! WASM 用的 JS/浏览器 API 导入。
//!
//! 这些 extern 函数由 JS 宿主实现，衔接 Zig/WASM 与浏览器 API。
//!
//! 这里只保留**窗口域**的桥：canvas 尺寸、rAF、输入轮询、IME、剪贴板、
//! 文件对话框、日志。渲染相关的 extern（pipeline / draw / 字体与 SVG
//! 栅格化 / 图像解码）统统不在这里——窗口库对宿主不提任何渲染要求，
//! 那些桥归消费方自己的 JS glue。

const std = @import("std");

// =============================================================================
// 控制台 / 调试
// =============================================================================

pub extern "env" fn consoleLog(ptr: [*]const u8, len: u32) void;
pub extern "env" fn consoleError(ptr: [*]const u8, len: u32) void;

/// 直接输出编译期字符串——不占栈、不格式化。
/// 用于栈帧尚未验证过的最早调试阶段。
pub fn logRaw(comptime msg: []const u8) void {
    consoleLog(msg.ptr, msg.len);
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleLog(str.ptr, @intCast(str.len));
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleError(str.ptr, @intCast(str.len));
}

// =============================================================================
// Canvas / 窗口
// =============================================================================

pub extern "env" fn getCanvasWidth() u32;
pub extern "env" fn getCanvasHeight() u32;
/// `window.devicePixelRatio`。
///
/// 用 `f64` 是因为 JS 的 `Number` 本身就是 IEEE-754 双精度，这是宿主侧
/// 的原生精度。声明成 `f32` 会先收窄宿主值，`WebWindow.updateSize` 再
/// 扩回去，白折腾一遭，还损失浏览器缩放比例非整数时的精度。
pub extern "env" fn getDevicePixelRatio() f64;
/// 取 canvas 实际像素宽度（canvas.width，非 clientWidth）。
pub extern "env" fn getCanvasPixelWidth() u32;
pub extern "env" fn getCanvasPixelHeight() u32;
pub extern "env" fn setCanvasSize(width: u32, height: u32) void;
pub extern "env" fn setDocumentTitle(ptr: [*]const u8, len: u32) void;

/// 移动隐藏输入框位置，用于 IME 候选窗定位。
pub extern "env" fn setImeCursorPosition(x: f32, y: f32, width: f32, height: f32) void;

// =============================================================================
// 动画帧
// =============================================================================

/// 请求下一帧动画——JS 侧到时候回调进 WASM。
pub extern "env" fn requestAnimationFrame() void;

/// 取当前帧的时间戳（毫秒）。
pub extern "env" fn getFrameTime() f64;

/// 取当前时间戳（毫秒，来自 JS 的 Date.now()）。
pub extern "env" fn getTimestampMillis() f64;

// =============================================================================
// 输入事件（从 JS 轮询）
// =============================================================================

pub extern "env" fn getMouseX() f32;
pub extern "env" fn getMouseY() f32;
pub extern "env" fn getMouseButtons() u32; // 位掩码：1=左键 2=右键 4=中键
pub extern "env" fn isMouseInCanvas() bool;
