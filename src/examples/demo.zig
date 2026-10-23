//! windowkit 原生 demo — 窗口创建 + 事件循环 + 输入/尺寸/帧回调。
//!
//! 运行：`zig build run`
//!
//! - Esc / 关闭按钮 / 标题栏关闭 → 关闭窗口并退出事件循环
//! - 鼠标移动 → 每次把坐标写进窗口标题（证明事件循环与窗口属性通路是活的）
//! - 窗口缩放 → 终端打印新尺寸
//! - 每 vsync 派发 `on_render`（首帧打印一次句柄/帧缓冲尺寸——渲染归依赖方）

const std = @import("std");
const windowkit = @import("windowkit");

const Platform = windowkit.Platform;
const PlatformWindow = windowkit.PlatformWindow;
const WindowOptions = windowkit.WindowOptions;
const input = windowkit.input;

var g_resize_count: u64 = 0;
var g_render_count: u64 = 0;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 平台对象必须有稳定地址（Wayland registry / NSApp 回调会持有它），
    // 所以放在栈上并原地初始化——这个栈帧活得比下面的事件循环久。
    var plat: Platform = undefined;
    try plat.initInPlace(allocator);
    defer plat.deinit();

    const options: WindowOptions = .{ .title = "windowkit demo", .width = 800, .height = 600, .centered = true, .file_drop = false };

    const win = try PlatformWindow.init(allocator, &plat, &options);
    defer win.deinit();

    win.setInputCallback(onInput);
    win.setCloseCallback(onClose);
    win.setResizeCallback(onResize);
    win.setRenderCallback(onFrame); // 每 vsync 派发；见 onFrame

    std.debug.print(
        "windowkit: window created ({d}x{d}, scale {d:.2}) — Esc 或关闭按钮退出\n",
        .{ win.width(), win.height(), win.getScaleFactor() },
    );

    // 原生句柄 + 帧缓冲尺寸：依赖方自持渲染时凭这两者建 surface/swapchain。
    const handles = win.nativeHandles();
    const px = win.framebufferSize();
    std.debug.print(
        "windowkit: handles={s}, framebuffer {d}x{d}（逻辑 {d}x{d} × scale {d:.2}）\n",
        .{
            @tagName(std.meta.activeTag(handles)),
            px.width_px,
            px.height_px,
            win.width(),
            win.height(),
            win.getScaleFactor(),
        },
    );

    // 阻塞事件循环：Wayland 上直到没有打开的窗口；macOS 上直到 quit()。
    plat.run();

    std.debug.print(
        "windowkit: event loop exited after {d} resizes / {d} render ticks\n",
        .{ g_resize_count, g_render_count },
    );
}

/// 帧回调：平台按自己的 vsync 时钟派发（Linux = frame callback 线程，
/// macOS = DisplayLink 线程持锁）。这里只在首帧打印一次，证明"渲染归依赖方"
/// 的派发通路是活的——真实消费者在这里录命令并 present。
fn onFrame(win: *PlatformWindow) void {
    g_render_count += 1;
    if (g_render_count == 1) {
        const px = win.framebufferSize();
        std.debug.print(
            "windowkit: on_render #1 → framebuffer {d}x{d}（在此录命令并 present）\n",
            .{ px.width_px, px.height_px },
        );
    }
}

/// 输入回调：返回 true 表示事件已被消费。
fn onInput(win: *PlatformWindow, event: input.InputEvent) bool {
    switch (event) {
        .key_down => |k| {
            if (k.key == .escape) {
                win.close();
                return true;
            }
        },
        .mouse_moved => |m| setTitlePosition(win, m.position.x, m.position.y),
        .scroll => |s| {
            std.debug.print("windowkit: scroll dy={d:.1}\n", .{s.delta.y});
        },
        .file_drop => |f| {
            // paths 只在回调期间有效,要留存必须自己拷。
            std.debug.print("windowkit: file_drop {s} @ ({d:.0},{d:.0})\n", .{
                @tagName(f.phase),
                f.position.x,
                f.position.y,
            });
            for (f.paths) |p| std.debug.print("  → {s}\n", .{p});
        },
        else => {},
    }
    return false;
}

/// 把鼠标坐标写进标题，用来看事件循环是否真的在跑。
/// `setTitle` 会把内容拷进窗口自己的固定缓冲，所以这里用栈缓冲是安全的。
fn setTitlePosition(win: *PlatformWindow, x: f64, y: f64) void {
    // 255 = `title_bytes_max` 下限。
    var buf: [255]u8 = undefined;
    const title = std.fmt.bufPrint(
        &buf,
        "windowkit — ({d:.0}, {d:.0})",
        .{ x, y },
    ) catch return;
    win.setTitle(title);
}

/// 返回 false 可以阻止关闭；这里放行并顺带结束事件循环。
fn onClose(win: *PlatformWindow) bool {
    // macOS 的 run() 不会因为窗口全关而自己退出，
    // 统一在这里 quit() 一次：Linux 只是提前结束循环，行为一致。
    win.getPlatform().quit();
    return true;
}

fn onResize(win: *PlatformWindow, width: f64, height: f64) void {
    g_resize_count += 1;
    std.debug.print(
        "windowkit: resize #{d} → {d:.0}x{d:.0} (scale {d:.2})\n",
        .{ g_resize_count, width, height, win.getScaleFactor() },
    );
}
