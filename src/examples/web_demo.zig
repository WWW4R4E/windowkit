//! windowkit Web demo — 在浏览器里创建 canvas 窗口并泵 rAF 事件循环。
//!
//! 由 `src/platform/web/entry.zig` 作为子模块导入，JS 侧通过三个导出驱动：
//! `init()` 创建平台 + 窗口，`frame(ts)` 每帧经 `WebPlatform.frameTick()`
//! 轮询尺寸并派发 `on_render`，`resize(w, h)` 响应 canvas 尺寸变化。
//!
//! 注意：输入事件的 JS ring buffer 排空（`key_events` / `mouse_events` 等）
//! 属于"绘制/事件对接"层，不在本 demo 范围内。现在这个 demo 只验证
//! 窗口创建与事件循环。

const std = @import("std");
const windowkit = @import("windowkit");

/// freestanding 目标没有 stderr，日志交给 JS；这里压掉默认级别即可。
pub const std_options: std.Options = .{
    .log_level = .err,
};

pub const wasm_app = struct {
    var g_platform: windowkit.Platform = undefined;
    var g_window: ?*windowkit.PlatformWindow = null;
    var g_initialized: bool = false;

    /// JS 调用的第一个导出（符号名固定为 `init`）。
    fn wasmInit() callconv(.c) void {
        initImpl() catch {};
    }

    fn initImpl() !void {
        const allocator = std.heap.wasm_allocator;

        // 模块级全局，地址稳定；`initInPlace` 要求的就是这个地址。
        g_platform = undefined;
        try g_platform.initInPlace(allocator);

        const options: windowkit.WindowOptions = .{
            .title = "windowkit web demo",
            .width = 800,
            .height = 600,
        };

        const win = try windowkit.PlatformWindow.init(allocator, &g_platform, &options);
        g_window = win;
        // 渲染回调：原生上由事件循环/DisplayLink 派发，web 上由 `frameTick`
        // 每帧派发（见 `WebPlatform.frameTick`）。这里只在首帧打印一次，
        // 证明 `setRenderCallback` 的通路在四个平台上都活着。
        win.setRenderCallback(onRender);

        g_initialized = true;

        // 启动 rAF 链；真正的逐帧续期在 `frame` 里。
        g_platform.run();
    }

    var g_render_count: u64 = 0;

    fn onRender(win: *windowkit.PlatformWindow) void {
        g_render_count += 1;
        if (g_render_count == 1) {
            const px = win.framebufferSize();
            const handles = win.nativeHandles();
            windowkit.platform.web.imports.log(
                "on_render #1: handles={s}, framebuffer {d}x{d} (logical {d}x{d})",
                .{
                    @tagName(std.meta.activeTag(handles)),
                    px.width_px,
                    px.height_px,
                    win.width(),
                    win.height(),
                },
            );
        }
    }

    /// 每个浏览器帧由 JS 调用。
    fn frame(timestamp: f64) callconv(.c) void {
        _ = timestamp;
        if (!g_initialized) return;

        // 窗口侧每帧工作：轮询 canvas 尺寸/DPR + 派发 on_render。
        g_platform.frameTick();

        // owner 的回合点（与原生 run 循环每轮的 hook 对应）。
        g_platform.fireLoopTurn();

        if (g_platform.isRunning()) {
            windowkit.platform.web.imports.requestAnimationFrame();
        }
    }

    /// canvas 尺寸变化由 JS 通知。
    fn resize(width: u32, height: u32) callconv(.c) void {
        _ = width;
        _ = height;
        if (g_window) |w| w.updateSize();
    }

    comptime {
        @export(&wasmInit, .{ .name = "init" });
        @export(&frame, .{ .name = "frame" });
        @export(&resize, .{ .name = "resize" });
    }
};
