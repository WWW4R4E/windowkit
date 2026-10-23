//! Windows 平台实现 —— Win32 消息循环 + DWM vsync 节拍。
//!
//! 与 macOS/Linux 一样是 `blocking_event_loop`:`run()` 阻塞泵消息直到
//! `quit()` 或所有窗口关闭。vsync 用 `DwmFlush`(阻塞到下一个合成帧),
//! 渲染回调在 UI 线程派发 —— 没有后台渲染线程,天然无需锁。
//!
//! DPI:进程初始化设 PER_MONITOR_AWARE_V2,`GetDpiForWindow` 取每窗口
//! 缩放,`WM_DPICHANGED` 响应热插拔/跨屏拖动。

const std = @import("std");
const assert = std.debug.assert;
const win32 = @import("win32.zig");
const window_mod = @import("window.zig");
const interface_mod = @import("../interface.zig");
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const WindowsPlatform = struct {
    hinstance: ?*anyopaque,
    running: bool,
    window_registry: WindowRegistry,
    allocator: std.mem.Allocator,

    /// UI 线程是否由我们成功初始化了 OLE(`OleInitialize`)。拖放目标是
    /// COM 对象,RegisterDragDrop 的前置条件;deinit 只在成功时配对
    /// OleUninitialize(宿主自己初始化过就不动它的账)。
    ole_initialized: bool = false,

    /// 事件循环每转一圈调用一次的宿主钩子(每轮 `run` 迭代各触发一次)。
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Windows 平台能力声明。
    pub const capabilities: interface_mod.PlatformCapabilities = .{
        .high_dpi = true,
        .multi_window = true,
        // DwmFlush 给出 vsync 节拍(阻塞到合成帧),等价于 display link。
        .display_link = true,
        .can_close_window = true,
        // DWM backdrop(Mica/Acrylic)+ 分层透明度。
        .glass_effects = true,
        // OLE IDropTarget:`WM_DESTROY` 前挂在窗口上,.file_drop 事件。
        .file_drop = true,
        .ime = true,
        .custom_cursors = true,
        // 没有暴露按内容拖动的 API(ReleaseCapture + WM_NCLBUTTONDOWN
        // HTCAPTION 可做,但 PlatformWindow 无此入口,不虚标)。
        .window_drag_by_content = false,
        .name = "Windows",
    };

    /// 原地初始化(调用方保证地址稳定)。
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        assert(@intFromPtr(self) != 0);

        // DPI 感知必须在任何窗口创建前设置;失败(老系统)静默降级为
        // 系统 DPI 感知,再不行就是未感知(系统缩放位图)。
        if (win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
            _ = win32.SetProcessDPIAware();
        }

        // OLE:文件拖放目标是 COM 对象,RegisterDragDrop 前置条件。
        // 必须 OleInitialize 而不是 CoInitializeEx —— 后者注册拖放恒返回
        // E_OUTOFMEMORY(MSDN 明文,实测 0x8007000e)。
        // S_FALSE = 宿主已初始化过(仍需配对 Uninitialize);其他失败
        // (如 RPC_E_CHANGED_MODE = 宿主用了 MTA)则不动 OLE,拖放注册
        // 会在窗口侧失败并优雅降级。
        const ole_hr = win32.OleInitialize(null);
        self.ole_initialized = win32.SUCCEEDED.check(ole_hr);

        self.hinstance = win32.GetModuleHandleW(null);
        self.allocator = allocator;
        self.running = false;
        self.loop_turn_callback = null;

        self.window_registry = WindowRegistry.init(allocator);
        errdefer self.window_registry.deinit();

        // 注册窗口类(重复注册返回 false,可接受)。
        _ = window_mod.registerWindowClass(self.hinstance);

        assert(self.window_registry.count() == 0);
        assert(!self.running);
    }

    pub fn deinit(self: *Self) void {
        // 窗口在自己的 deinit 里注销;剩下的由调用方泄漏,不强求空。
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
        self.running = false;
        self.window_registry.deinit();
        if (self.ole_initialized) win32.OleUninitialize();
    }

    // =========================================================================
    // 窗口注册表
    // =========================================================================

    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        assert(@intFromPtr(window) != 0);
        assert(self.window_registry.count() < WindowRegistry.MAX_WINDOWS);
        const id = try self.window_registry.register(window);
        assert(id.isValid());
        return id;
    }

    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        const before = self.window_registry.count();
        _ = self.window_registry.unregister(id);
        assert(self.window_registry.count() <= before);
    }

    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        return self.window_registry.get(id);
    }

    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.window_registry.getActiveWindow();
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        if (id) |active| {
            assert(active.isValid());
            assert(self.window_registry.contains(active));
        }
        self.window_registry.setActiveWindow(id);
    }

    pub fn windowCount(self: *const Self) u32 {
        return self.window_registry.count();
    }

    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    // =========================================================================
    // 事件循环
    // =========================================================================

    /// 非阻塞地泵一轮输入：排空消息队列里**当前就绪**的所有消息并分派。
    ///
    /// 遇到 `WM_QUIT` 即视作 `quit()`（置 `running` = false、停止排空，与
    /// 原 `run` 的行为一致——队列里排在其后的消息一并留在队列，交给
    /// `deinit` 前谁也不再处理，这不影响收尾）。队列排空即返回，不做任何
    /// 等待、也不派发渲染节拍——帧节奏归调用方的循环。
    pub fn pump(self: *Self) void {
        var msg: win32.MSG = undefined;
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            if (msg.message == win32.WM_QUIT) {
                self.running = false;
                return;
            }
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
            if (!self.running) return; // 分派中 quit() 被调，停止排空
        }
    }

    /// 最多阻塞 `timeout_ms` 毫秒，等到消息队列有新输入为止。
    ///
    /// 返回 true 表示队列已有待处理输入、一次 `pump()` 即可收掉；false
    /// 表示超时（`timeout_ms` 已到）或等待被打断（保守当没事发生，调用方
    /// 下一轮重试即可）。`timeout_ms` 传 `interface.wait_infinite` 表示
    /// 无限期阻塞。
    ///
    /// 本方法同样不派发任何回调：分派语义集中在 `pump()` 一处。已处于
    /// 退出状态（`quit()` 之后）时不等待、直接返回 false。
    pub fn waitEvent(self: *Self, timeout_ms: u32) bool {
        if (!self.running) return false;

        const wait = win32.MsgWaitForMultipleObjectsEx(
            0,
            null,
            timeout_ms,
            win32.QS_ALLINPUT,
            win32.MWMO_INPUTAVAILABLE,
        );
        return wait != win32.WAIT_TIMEOUT;
    }

    /// 进入运行状态（过程式循环的起点）。
    ///
    /// 过程式调用方必须在自己搭循环之前调一次：
    ///
    /// ```zig
    /// plat.start();
    /// while (plat.isRunning()) {
    ///     _ = plat.waitEvent(16);
    ///     plat.pump();
    ///     tickAndRender();
    /// }
    /// ```
    ///
    /// `run()` 内部会自己调它；重复调用属于用法错误。
    pub fn start(self: *Self) void {
        assert(!self.running);
        self.running = true;
    }

    /// 阻塞泵消息直到 quit() 或最后一个窗口关闭。
    ///
    /// 节拍:`PeekMessage` 排空 → 派发渲染回调 → `DwmFlush`(阻塞到下一个
    /// 合成帧)。空闲时(无窗口要渲染)`GetMessage` 阻塞等事件,不烧 CPU。
    pub fn run(self: *Self) void {
        self.start();

        while (self.running) {
            // 排空当前所有待处理消息（WM_QUIT 在 pump 里置 running=false）。
            self.pump();
            if (!self.running) break;

            // 渲染节拍:每个注册窗口派发一次 on_render。
            self.dispatchRenderTicks();

            if (self.loop_turn_callback) |on_turn| on_turn(self);

            // vsync:DwmFlush 阻塞到下一个合成帧。失败(禁用 DWM / 远程
            // 会话)退化为 16ms 睡眠,保持 ~60Hz 节拍而不是忙轮询。
            if (win32.DwmFlush() != win32.S_OK) {
                win32.Sleep(16);
            }
        }

        self.running = false;
    }

    /// 给所有窗口派发一帧(每 vsync 一次)。
    ///
    /// 依赖方的 on_render 在这里被调用;`needs_render` 标志与 macOS 的
    /// benchmark_mode 同语义 —— 默认连续渲染,`requestRender` 显式驱动。
    fn dispatchRenderTicks(self: *Self) void {
        var it = self.window_registry.iterator();
        while (it.next()) |id| {
            const ptr = self.window_registry.get(id.*) orelse continue;
            const win: *window_mod.Window = @ptrCast(@alignCast(ptr));
            if (win.isClosed()) continue;

            // needs_render 为真才派发;渲染后清零(下一帧由 requestRender
            // 或 resize 重新置位)。
            if (win.needs_render.swap(false, .acq_rel)) {
                win.render();
            }
        }
    }

    /// 结束事件循环(投递 WM_QUIT,GetMessage/PeekMessage 收到后退出)。
    pub fn quit(self: *Self) void {
        self.running = false;
        win32.PostQuitMessage(0);
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// 主显示器缩放(建窗口前给初始 scale_factor 兜底)。
    pub fn primaryScaleFactor(self: *const Self) f64 {
        _ = self;
        const dpi = win32.GetDpiForSystem();
        if (dpi == 0) return 1.0;
        return @as(f64, @floatFromInt(dpi)) / 96.0;
    }
};

// =============================================================================
// 测试
// =============================================================================

test "capabilities declares glass and vsync" {
    const caps = WindowsPlatform.capabilities;
    try std.testing.expect(caps.glass_effects);
    try std.testing.expect(caps.display_link);
    try std.testing.expect(caps.multi_window);
    try std.testing.expect(caps.high_dpi);
    try std.testing.expectEqualStrings("Windows", caps.name);
}
