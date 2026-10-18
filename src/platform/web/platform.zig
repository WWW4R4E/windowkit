//! WebPlatform — WASM/浏览器上的平台实现。

const std = @import("std");
const imports = @import("imports.zig");
const interface_mod = @import("../interface.zig");
const window_registry = @import("../window_registry.zig");
const WebWindow = @import("window.zig").WebWindow;
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const WebPlatform = struct {
    /// `run` 已注册帧回调且未被 `quit` 停掉时为 true。
    /// 支撑 `isRunning`；每个后端对宿主必须履行的确切状态转换见
    /// `contract.verifyPlatform`。
    running: bool = false,

    /// 按 ID 追踪窗口的注册表。
    /// 注意：Web 只支持单窗口，这里保留是为了 API 一致。
    window_registry: WindowRegistry,

    /// 平台资源用的分配器
    allocator: std.mem.Allocator,

    /// 每个宿主帧回调触发一次的 owner 钩子；见 `fireLoopTurn`。
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    /// 每个宿主帧回调调用一次的回调。
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Web/WASM 的平台能力
    pub const capabilities: interface_mod.PlatformCapabilities = .{
        .high_dpi = true,
        .multi_window = false, // 窗口由浏览器管理
        .display_link = false, // 用 requestAnimationFrame
        .can_close_window = false, // 不能关浏览器标签页
        .glass_effects = false, // CSS backdrop-filter 是另一回事

        .ime = true, // 经 beforeinput/compositionend 事件
        // CSS 能表达所有 `CursorShape`，但 `imports.zig` 没有光标桥，
        // 所以 `WebWindow.setCursorShape` 只记录请求、JS 宿主不会应用。
        // 落地导入的那次改动里把它翻回 `true`（设计决策 7：不支持的
        // 操作要显式暴露，这就是机制）。
        .custom_cursors = false,
        .window_drag_by_content = false,
        .name = "Web/WASM",
    };

    /// 原位初始化。
    ///
    /// 之前按值返回的 `init`/`initWithAllocator` 会在构造后强迫调用方
    /// 移动平台对象，这对任何宿主持有 `&self` 的后端都不健全。Web 目前
    /// 虽不持有它，但边界与 Wayland 共用、而 Wayland 持有，所以契约
    /// 对所有后端都钉死原位形式（见 `contract.verifyPlatform`）。
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.window_registry = WindowRegistry.init(allocator);
        self.loop_turn_callback = null;
        // 还没在跑。`run` 是唯一把它置真值的地方：宿主每帧之后都查
        // `isRunning` 来决定要不要再排一帧，这里若提前置真，应用还没
        // 初始化完就可能被要走一帧。
        self.running = false;

        std.debug.assert(self.window_registry.count() == 0);
        std.debug.assert(self.window_registry.getActiveWindow() == null);
    }

    pub fn deinit(self: *Self) void {
        // 所有窗口必须先注销完；这里有存活条目说明某次 `WebWindow.deinit`
        // 被跳过，其 ID 会悬空。
        std.debug.assert(self.window_registry.count() == 0);

        self.window_registry.deinit();
        // 不管宿主有没有先调 `quit`，析构都结束循环，
        // 这样 `deinit` 之后的轮询不可能再要一帧。
        self.running = false;
    }

    // =========================================================================
    // 窗口注册表（web 上仅单窗口）
    // =========================================================================

    /// 平台注册窗口，返回其 ID。
    ///
    /// 浏览器掌管标签页/窗口管理，所以 `capabilities` 声明
    /// `multi_window = false`。在这里强制，而不是让第二个无 canvas 的
    /// 窗口注册进来然后悄悄永不渲染。
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        comptime std.debug.assert(!capabilities.multi_window);
        std.debug.assert(self.window_registry.count() == 0);

        const id = try self.window_registry.register(window);

        std.debug.assert(id.isValid());
        std.debug.assert(self.window_registry.count() == 1);
        return id;
    }

    /// 按 ID 注销窗口。
    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        std.debug.assert(id.isValid());

        _ = self.window_registry.unregister(id);

        std.debug.assert(!self.window_registry.contains(id));
    }

    /// 按 ID 取窗口。
    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        const found = self.window_registry.get(id);
        if (!id.isValid()) std.debug.assert(found == null);
        return found;
    }

    /// 取激活窗口 ID。
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        const active = self.window_registry.getActiveWindow();
        if (active) |id| std.debug.assert(id.isValid());
        if (self.window_registry.count() == 0) std.debug.assert(active == null);
        return active;
    }

    /// 按 ID 设置激活窗口。
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        if (id) |window_id| std.debug.assert(window_id.isValid());

        self.window_registry.setActiveWindow(id);

        std.debug.assert(self.window_registry.getActiveWindow() == id);
    }

    /// 已注册窗口数量。
    pub fn windowCount(self: *const Self) u32 {
        const count = self.window_registry.count();
        std.debug.assert(count <= 1); // 单窗口后端；见 `registerWindow`。
        return count;
    }

    /// 注册浏览器帧回调后立即返回。
    ///
    /// 这是契约里 `DriveModel.host_callback` 那一半：与原生后端不同，
    /// 这里没有可阻塞的循环，时钟归宿主。`isRunning` 告诉宿主继续
    /// 排帧，本方法就是它开始返回 true 的时刻。
    pub fn run(self: *Self) void {
        // 注册两次会开出第二条 rAF 链，之后每一帧两条链都在渲染。
        std.debug.assert(!self.running);
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = true;
        imports.requestAnimationFrame();
    }

    /// 停止排帧。浏览器标签页本身保持打开；见
    /// `capabilities.can_close_window`。
    pub fn quit(self: *Self) void {
        // 在 `run` 之前、帧内、析构中调用都合法；这三种状态浏览器宿主
        // 都可能到达。单窗口不变量仍然要守住：如果第二个 canvas 能调
        // `quit`，说明 `registerWindow` 的注册表防线被绕过了。
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = false;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// 安装每回合的 owner 钩子。传 `null` 清除。
    ///
    /// 契约钉死的接口；为什么要给 owner 这个挂点见
    /// `platform/contract.zig` 里关于 `LoopTurnCallback` 的说明。
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    /// 在这次宿主帧回调里执行 owner 的回合。
    ///
    /// `DriveModel.host_callback` 没有可以派发回合的循环：`run` 注册
    /// `requestAnimationFrame` 后即返回，循环归浏览器，回合点就是帧
    /// 入口本身。调用方在每个 tick 里、排空输入环形缓冲并渲染之后
    /// 调一次——与原生后端"没有窗口回调在栈上"的触发位置等价。
    ///
    /// 原生后端不需要对等方法：它们的 `run` 循环本身就是周期，钩子
    /// 内联触发。
    pub fn fireLoopTurn(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);

        if (self.loop_turn_callback) |on_turn| on_turn(self);
    }

    /// 浏览器每个 rAF 回合的窗口侧工作：轮询 canvas 尺寸 + 派发 `on_render`。
    ///
    /// 原生后端在自己的事件循环 / DisplayLink 里派发渲染回调，web 的时钟
    /// 属于宿主，所以派发点暴露给宿主的 `frame()`：在 `fireLoopTurn` 之前
    /// 调用它，等价于原生"先把窗口侧的帧工作做完，再跑 owner 的回合"。
    /// rAF 链是否续期仍由 `isRunning()` 决定，本方法不碰帧率。
    pub fn frameTick(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);

        const win = self.window_registry.getActiveWindowTyped(WebWindow) orelse return;
        win.updateSize();
        win.renderFrame();
    }
};
