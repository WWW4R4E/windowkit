//! Linux 平台模块 —— 仅窗口。
//!
//! Wayland 窗口管理（xdg-shell、装饰、viewporter、IME）加事件循环。
//! 渲染由依赖方持有：窗口层只派发 `on_render` 回调，
//! 原生对象经 `window.nativeHandles()` 交出。
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

// 平台核心类型
pub const platform = @import("platform.zig");
pub const window = @import("window.zig");

// 底层绑定
pub const wayland = @import("wayland.zig");

// 输入处理
pub const input = @import("input.zig");
pub const dnd = @import("dnd.zig");

// 后端的规范出口类型。
pub const Platform = platform.LinuxPlatform;
pub const PlatformWindow = window.Window;

/// `Platform.run` 阻塞在 Wayland 的 poll/dispatch 循环里直到退出。
pub const drive_model: interface.DriveModel = .blocking_event_loop;

// 便捷别名
pub const LinuxPlatform = platform.LinuxPlatform;
pub const Window = window.Window;

// 转发 capabilities
pub const capabilities = LinuxPlatform.capabilities;
