//! windowkit — 三平台窗口创建（Linux/Wayland · macOS/AppKit · Windows/Win32）。
//!
//! 纯窗口库，不做渲染。两种事件循环用法（引擎/嵌入宿主用过程式，独立小
//! 应用可用回调糖）：
//!
//! ```zig
//! plat.run();                                  // 回调糖：库拥有循环
//!
//! plat.start();                                // 过程式：循环主权在调用方
//! while (plat.isRunning()) {
//!     _ = plat.waitEvent(16);
//!     plat.pump();
//!     tickAndRender();
//! }
//! ```
//!
//! 用法、渲染接入契约（原生句柄 / 物理像素 / 销毁时序）、线程模型见 README；
//! `pump` / `waitEvent` / `run` 的语义契约见 `platform/interface.zig`；
//! 可运行示例见 `src/examples/demo.zig`。

const std = @import("std");

/// 编译期选定的平台后端（`linux/` · `macos/` · `windows/`）。
pub const platform = @import("platform/mod.zig");

pub const Platform = platform.Platform;
pub const PlatformWindow = platform.PlatformWindow;
pub const WindowOptions = platform.WindowOptions;
pub const WindowId = platform.WindowId;
pub const WindowRegistry = platform.WindowRegistry;
pub const PlatformCapabilities = platform.PlatformCapabilities;

/// 三平台原生对象：`win.nativeHandles()` 返回它。见 `platform/native_handles.zig`。
pub const NativeHandles = platform.NativeHandles;

/// 帧缓冲**物理**像素尺寸：`win.framebufferSize()` 返回它。
pub const FramebufferSize = platform.FramebufferSize;
pub const GlassStyle = platform.GlassStyle;
pub const CursorShape = platform.CursorShape;

/// 目标判定：`platform.is_linux` / `is_macos` / `is_windows` 的别名。
pub const is_linux = platform.is_linux;
pub const is_macos = platform.is_macos;
pub const is_windows = platform.is_windows;

/// 输入事件（`InputEvent`、`KeyTag`、`Modifiers` …）。三个平台共用
/// 同一个类型，所以回调签名在所有平台上是一致的。
pub const input = @import("input/mod.zig");

/// 几何/颜色原语（`Color`、`Size(f64)`、`RectF`、`Point(f64)`）。
pub const geometry = @import("geometry.zig");
pub const Color = geometry.Color;

test {
    std.testing.refAllDecls(@This());
}
