//! Windows 平台模块 —— 只管窗口。
//!
//! Win32 窗口管理(消息循环、DPI、玻璃、IME)+ 事件循环。渲染由依赖方
//! 持有:窗口层只派发 `on_render` 回调,原生对象经
//! `window.nativeHandles()` 交出(`HWND` + `HINSTANCE`)。
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

// 平台核心类型
pub const platform = @import("platform.zig");
pub const window = @import("window.zig");

// 底层 Win32 绑定
pub const win32 = @import("win32.zig");

// 输入与拖放
pub const input = @import("input.zig");
pub const drop_target = @import("drop_target.zig");

// 对外规范入口。
pub const Platform = platform.WindowsPlatform;
pub const PlatformWindow = window.Window;

/// `run()` 阻塞在 Win32 消息循环里直到 quit / 所有窗口关闭。
pub const drive_model: interface.DriveModel = .blocking_event_loop;

// 便捷别名
pub const WindowsPlatform = platform.WindowsPlatform;
pub const Window = window.Window;

// 能力声明转发
pub const capabilities = WindowsPlatform.capabilities;
