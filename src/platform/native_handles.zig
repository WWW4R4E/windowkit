//! 原生句柄与帧缓冲尺寸 — 依赖方自持渲染时的接线点。
//!
//! windowkit 不做渲染，只把各后端的原生对象**原样交出去**，并给出
//! swapchain 真正关心的物理像素尺寸：
//!
//! ```zig
//! const h = win.nativeHandles();
//! switch (h) {
//!     .wayland => |wl| _ = wl, // vkCreateWaylandSurfaceKHR(wl.display, wl.surface)
//!     .appkit => |mac| _ = mac, // CAMetalLayer → nextDrawable
//!     .win32 => |w| _ = w, // vkCreateWin32SurfaceKHR(w.hinstance, w.hwnd)
//! }
//! const px = win.framebufferSize(); // 渲染目标只认这个值
//! ```
//!
//! 契约（README「接入方自己渲染」一节有完整版）：
//!
//! - `nativeHandles` 只在窗口 `init` 成功之后、`deinit` 之前有效。窗口
//!   销毁后再引用这些对象是未定义行为——依赖方必须先销毁自己的
//!   surface / swapchain / drawable，再 `win.deinit()`。
//! - `framebufferSize` 是**物理**像素（= 逻辑尺寸 × DPR），随窗口缩放与
//!   DPR 变化更新；`width()` / `height()` 返回的逻辑尺寸不参与渲染。

const std = @import("std");

/// 帧缓冲物理像素尺寸。
pub const FramebufferSize = struct {
    width_px: u32,
    height_px: u32,
};

/// 三平台的原生窗口对象。
///
/// windowkit 不解释这些指针的内部结构，只保证它们在窗口存活期内有效。
pub const NativeHandles = union(enum) {
    /// Linux/Wayland：`wl_display` + `wl_surface`。
    wayland: struct {
        display: *anyopaque,
        surface: *anyopaque,
    },

    /// macOS/AppKit：`NSWindow` / `NSView` / `CAMetalLayer`。
    ///
    /// `metal_layer` 由窗口层创建，并随窗口缩放、DPR 变化同步
    /// `contentsScale` / `drawableSize`；像素格式、`maximumDrawableCount`
    /// 等其余配置由依赖方拿句柄自行设置，窗口层不关心。
    appkit: struct {
        ns_window: *anyopaque,
        ns_view: *anyopaque,
        metal_layer: *anyopaque,
    },

    /// Windows/Win32：`HWND` + `HINSTANCE`。
    ///
    /// `hinstance` 是 `GetModuleHandleW(null)` —— 建 Vulkan surface
    /// （`vkCreateWin32SurfaceKHR`）时要它；D3D12 只用 `hwnd`。
    /// 客户区物理像素尺寸读 `framebufferSize()`（DPI 感知下 `GetClientRect`
    /// 已是物理值），不从 HWND 自己算。
    win32: struct {
        hwnd: *anyopaque,
        hinstance: *anyopaque,
    },
};

test "NativeHandles tags map one-to-one to fields" {
    const wl: NativeHandles = .{ .wayland = .{
        .display = @ptrFromInt(0x1000),
        .surface = @ptrFromInt(0x2000),
    } };
    try std.testing.expect(wl == .wayland and wl.wayland.display != wl.wayland.surface);

    const w32: NativeHandles = .{ .win32 = .{
        .hwnd = @ptrFromInt(0x3000),
        .hinstance = @ptrFromInt(0x4000),
    } };
    try std.testing.expect(w32 == .win32 and w32.win32.hwnd != w32.win32.hinstance);
}
