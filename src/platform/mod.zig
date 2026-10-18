//! 平台抽象层。
//!
//! 编译期选后端：每个目标只分析一个后端命名空间，没走到的分支
//! 不付出任何代码量或编译时长。
//!
//! ## Usage
//!
//! ```zig
//! const windowkit = @import("windowkit");
//!
//! var plat: windowkit.Platform = undefined;
//! try plat.initInPlace(allocator);
//! defer plat.deinit();
//!
//! var win = try windowkit.PlatformWindow.init(allocator, &plat, &options);
//! defer win.deinit();
//!
//! plat.run();
//! ```

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// 共享契约
// =============================================================================

pub const interface = @import("interface.zig");

/// 平台能力列表。
pub const PlatformCapabilities = interface.PlatformCapabilities;

/// 窗口创建选项（平台无关）。
pub const WindowOptions = interface.WindowOptions;

/// 所选后端的宿主把控制权交给我们的方式。
pub const DriveModel = interface.DriveModel;

/// 组件选择的光标形状。
pub const CursorShape = interface.CursorShape;

/// 半透明背景样式（全后端共用）。
pub const GlassStyle = interface.GlassStyle;

/// 原生句柄与帧缓冲尺寸：依赖方自持渲染时的接线点。
pub const native_handles = @import("native_handles.zig");

/// 四平台原生对象（`wl_display`+`wl_surface` / `NSWindow`+`CAMetalLayer` / `HWND`+`HINSTANCE` / web）。
pub const NativeHandles = native_handles.NativeHandles;

/// 帧缓冲**物理**像素尺寸（= 逻辑尺寸 × DPR）。
pub const FramebufferSize = native_handles.FramebufferSize;

/// 窗口的唯一标识。
pub const WindowId = interface.WindowId;

/// 按 ID 追踪窗口的中央注册表。
pub const WindowRegistry = interface.WindowRegistry;

// =============================================================================
// 编译期平台选择
// =============================================================================

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;
pub const is_windows = builtin.os.tag == .windows;

/// 刻意不含渲染后端（Vulkan / Metal / WebGPU）：`backend` 只管
/// 窗口 + 输入 + 事件循环。
pub const backend = if (is_wasm)
    @import("web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig"),
    .linux => @import("linux/mod.zig"),
    .windows => @import("windows/mod.zig"),
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};

/// 当前目标的 Platform 类型（编译期选定）。
pub const Platform = backend.Platform;

/// 当前目标的操作系统级窗口句柄（编译期选定）。
///
/// macOS 上是 `NSWindow`（包装），Linux 上是 `wl_surface` + xdg-shell
/// 状态，Web 上是 `HTMLCanvasElement` 的垫片。
pub const PlatformWindow = backend.PlatformWindow;

/// 所选后端的宿主驱动模型。
///
/// macOS 与 Linux 是 `blocking_event_loop`，Web 是 `host_callback`。
pub const drive_model: DriveModel = backend.drive_model;

/// 用于 vsync 的 DisplayLink（仅 macOS）。
pub const DisplayLink = if (is_wasm or is_linux or is_windows)
    void
else
    backend.DisplayLink;

// =============================================================================
// 后端命名空间（供进阶用法）
// =============================================================================

pub const macos = if (is_macos) @import("macos/mod.zig") else struct {};
pub const linux = if (is_linux) @import("linux/mod.zig") else struct {};
pub const windows = if (is_windows) @import("windows/mod.zig") else struct {};
pub const web = if (is_wasm) @import("web/mod.zig") else struct {};

// =============================================================================
// 辅助函数
// =============================================================================

/// 取当前平台的能力。
pub fn getCapabilities() PlatformCapabilities {
    return Platform.capabilities;
}
