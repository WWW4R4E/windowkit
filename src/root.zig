//! windowkit — 四平台窗口创建（Linux/Wayland · macOS/AppKit · Windows/Win32 · Web/Canvas）。
//!
//! GLFW 式**纯窗口库**：窗口创建/销毁、属性（标题、尺寸、玻璃效果）、IME、
//! 输入回调、事件循环、vsync 帧节拍（`requestRender` + `setRenderCallback`）。
//! windowkit 不做渲染、也不定义任何渲染接口——绘制归依赖方，它从窗口拿到的
//! 是三样东西：帧回调（`setRenderCallback`）、原生句柄（`nativeHandles()`）、
//! 物理像素尺寸（`framebufferSize()`）。契约见 README「接入方自己渲染」。
//!
//! ## 用法（原生）
//!
//! ```zig
//! const windowkit = @import("windowkit");
//!
//! pub fn main() !void {
//!     var gpa: std.heap.DebugAllocator(.{}) = .init;
//!     defer _ = gpa.deinit();
//!
//!     var plat: windowkit.Platform = undefined;
//!     try plat.initInPlace(gpa.allocator());
//!     defer plat.deinit();
//!
//!     const win = try windowkit.PlatformWindow.init(
//!         gpa.allocator(),
//!         &plat,
//!         &.{ .title = "Hello", .width = 800, .height = 600 },
//!     );
//!     defer win.deinit();
//!
//!     plat.run(); // 阻塞事件循环，直到所有窗口关闭或 quit()
//! }
//! ```
//!
//! ## 接入渲染（依赖方）
//!
//! ```zig
//! // 1. 每帧节拍：平台按 vsync / rAF 派发回调，依赖方在这里录命令。
//! win.setRenderCallback(myFrame); // fn (*PlatformWindow) void
//!
//! // 2. 建自己的 surface / swapchain：凭原生句柄 + 物理像素尺寸。
//! const h = win.nativeHandles();
//! switch (h) {
//!     .wayland => |wl| _ = wl, // vkCreateWaylandSurfaceKHR(wl.display, wl.surface)
//!     .appkit => |mac| _ = mac, // CAMetalLayer → nextDrawable
//!     .win32 => |w| _ = w, // vkCreateWin32SurfaceKHR(w.hinstance, w.hwnd)
//!     .web => {}, // JS: canvas.getContext("webgpu")
//! }
//! const px = win.framebufferSize(); // 物理像素；尺寸变化走 on_resize 回调
//!
//! // 3. 销毁顺序：先销毁自己的渲染资源，再关窗口。
//! defer {
//!     renderer.deinit(); // surface/swapchain/drawable
//!     win.deinit();
//! }
//! ```
//!
//! 用 `setUserData` / `getUserData` 让自己的渲染对象在帧回调里可取回。
//!
//! 见 `src/examples/demo.zig`（原生）与 `src/examples/web_demo.zig`（WASM）。

const std = @import("std");

/// 编译期选定的平台后端（`linux/` · `macos/` · `windows/` · `web/`）。
pub const platform = @import("platform/mod.zig");

pub const Platform = platform.Platform;
pub const PlatformWindow = platform.PlatformWindow;
pub const WindowOptions = platform.WindowOptions;
pub const WindowId = platform.WindowId;
pub const WindowRegistry = platform.WindowRegistry;
pub const PlatformCapabilities = platform.PlatformCapabilities;

/// 四平台原生对象：`win.nativeHandles()` 返回它。见 `platform/native_handles.zig`。
pub const NativeHandles = platform.NativeHandles;

/// 帧缓冲**物理**像素尺寸：`win.framebufferSize()` 返回它。
pub const FramebufferSize = platform.FramebufferSize;
pub const GlassStyle = platform.GlassStyle;
pub const CursorShape = platform.CursorShape;
pub const DriveModel = platform.DriveModel;

/// 目标判定：`platform.is_wasm` / `is_linux` / `is_macos` / `is_windows` 的别名。
pub const is_wasm = platform.is_wasm;
pub const is_linux = platform.is_linux;
pub const is_macos = platform.is_macos;
pub const is_windows = platform.is_windows;

/// 输入事件（`InputEvent`、`KeyTag`、`Modifiers` …）。原生与 Web 共用
/// 同一个类型，所以回调签名在四个平台上是一致的。
pub const input = @import("input/mod.zig");

/// 几何/颜色原语（`Color`、`Size(f64)`、`RectF`、`Point(f64)`）。
pub const geometry = @import("geometry.zig");
pub const Color = geometry.Color;

test {
    std.testing.refAllDecls(@This());
}
