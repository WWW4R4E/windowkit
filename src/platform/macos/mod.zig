//! macOS 平台后端 — 只管窗口。
//!
//! AppKit 窗口管理层（NSWindow / NSView + NSTextInputClient / window
//! delegate / 玻璃效果），事件循环走 NSApp，渲染节拍由 CVDisplayLink 驱动。
//! 渲染由依赖方持有：`on_render` 回调逐 vsync 派发，`CAMetalLayer` 经
//! `nativeHandles()` 交出（窗口层继续同步 contentsScale / drawableSize）。
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

const interface = @import("../interface.zig");

// 核心平台类型
pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const window_delegate = @import("window_delegate.zig");

// 显示同步
pub const display_link = @import("display_link.zig");

// 底层绑定
pub const appkit = @import("appkit.zig");

// 输入处理
pub const input = @import("input.zig");
pub const input_view = @import("input_view.zig");

// 后端规范入口。
pub const Platform = platform.MacPlatform;
pub const PlatformWindow = window.Window;

/// `[NSApp run]` 在 `quit` 之前接管线程，因此 macOS 后端在 `run` 中阻塞。
pub const drive_model: interface.DriveModel = .blocking_event_loop;

// 便捷类型别名
pub const MacPlatform = platform.MacPlatform;
pub const Window = window.Window;
pub const DisplayLink = display_link.DisplayLink;

// 能力位再导出
pub const capabilities = MacPlatform.capabilities;

// 平台接口契约类型再导出
pub const WindowOptions = interface.WindowOptions;
pub const GlassStyle = interface.GlassStyle;
pub const CursorShape = interface.CursorShape;
