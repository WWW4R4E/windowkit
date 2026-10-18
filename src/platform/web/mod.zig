//! Web 平台模块 — 只管窗口。
//!
//! 基于浏览器 canvas 的窗口 + `requestAnimationFrame` 宿主循环。渲染回调由宿主
//! 的 `frame()` 经 `WebPlatform.frameTick()` 逐帧派发（web 的时钟属于宿主）。
//!
//! ## 用法
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

pub const imports = @import("imports.zig");
pub const io = @import("io.zig");
pub const window = @import("window.zig");
pub const platform = @import("platform.zig");
pub const composition_buffer = @import("composition_buffer.zig");


// 后端规范表面。
pub const Platform = platform.WebPlatform;
pub const PlatformWindow = window.WebWindow;

/// 宿主经 `requestAnimationFrame` 驱动；`run` 注册一次回调后立即返回。
pub const drive_model: interface.DriveModel = .host_callback;

// 便捷类型别名
pub const WebPlatform = platform.WebPlatform;
pub const WebWindow = window.WebWindow;

// 能力再导出
pub const capabilities = WebPlatform.capabilities;
