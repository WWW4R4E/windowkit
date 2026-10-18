//! macOS 平台实现，基于 Cocoa/AppKit。
//!
//! 属于本模块的内容：
//! - AppKit 事件循环
//! - Cocoa 窗口管理
//! - 窗口注册表与活跃窗口跟踪

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const interface_mod = @import("../interface.zig");
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

// 运行时链接的 Foundation 常量
extern "c" var NSDefaultRunLoopMode: *anyopaque;

// 阻塞式事件等待需要 distantFuture
fn getDistantFuture() objc.Object {
    const NSDate = objc.getClass("NSDate") orelse unreachable;
    return NSDate.msgSend(objc.Object, "distantFuture", .{});
}

pub const MacPlatform = struct {
    app: objc.Object,
    delegate: ?objc.Object,
    running: bool,

    /// 按 ID 跟踪所有窗口的注册表
    window_registry: WindowRegistry,

    /// 平台资源使用的分配器
    allocator: std.mem.Allocator,

    /// 每次 `run` 循环迭代触发一次的宿主钩子；见 `setLoopTurnCallback`。
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    /// `run` 循环每次迭代调用一次。
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// macOS 平台能力位。
    pub const capabilities: interface_mod.PlatformCapabilities = .{
        .high_dpi = true,
        .multi_window = true,
        .display_link = true,
        .can_close_window = true,
        .glass_effects = true,
        // NSDraggingDestination 挂在自定义 NSView 上(见 input_view.zig),
        // 接受 file URL 拖放,.file_drop 事件。
        .file_drop = true,
        .ime = true,
        .custom_cursors = true,
        // AppKit 本身支持（`-[NSWindow performWindowDragWithEvent:]`、
        // `movableByWindowBackground`），但平台层没有暴露任何拖动机制，
        // 宣告 true 等于承诺一个不存在的调用面。
        .window_drag_by_content = false,
        .name = "macOS",
    };

    /// 在调用方给定的最终地址上就地初始化。
    ///
    /// 逐字段赋值而非结构体字面量：`MacPlatform` 内嵌窗口注册表，
    /// 字面量会先物化一个栈临时再拷贝；这个地址还会交给 AppKit 持有的
    /// window delegate，初始化完成前必须稳定。
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        assert(@intFromPtr(self) != 0);

        const NSApp = objc.getClass("NSApplication") orelse return error.ClassNotFound;
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        if (app.value == null) return error.ApplicationUnavailable;

        // NSApplicationActivationPolicyRegular：带 Dock 图标和菜单栏的
        // 前台应用，区别于 accessory / 背景代理。
        _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 0)});

        self.allocator = allocator;
        self.app = app;
        self.delegate = null;
        self.running = false;
        self.loop_turn_callback = null;

        self.window_registry = WindowRegistry.init(allocator);
        errdefer self.window_registry.deinit();

        assert(self.window_registry.count() == 0);
        assert(!self.running);
    }

    pub fn deinit(self: *Self) void {
        assert(self.app.value != null);

        // 窗口在各自的 `Window.deinit` 里自行注销。若有残留，属于调用方
        // 泄漏而非本层，所以只做上界检查而不要求清空：销毁顺序由应用决定。
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        self.running = false;
        self.window_registry.deinit();
        // NSApplication 是进程级单例；释放它等于对自己未曾拥有的共享实例
        // 二次释放。
    }

    // =========================================================================
    // 窗口注册表
    // =========================================================================

    /// 注册窗口并返回其 ID。
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        assert(@intFromPtr(window) != 0);
        assert(self.window_registry.count() < WindowRegistry.MAX_WINDOWS);

        const id = try self.window_registry.register(window);
        assert(id.isValid());
        return id;
    }

    /// 按 ID 注销窗口。
    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        const before = self.window_registry.count();

        _ = self.window_registry.unregister(id);

        // `unregister` 幂等，断言它只会缩小集合。
        assert(self.window_registry.count() <= before);
    }

    /// 按 ID 取窗口。
    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
        return self.window_registry.get(id);
    }

    /// 取活跃窗口 ID。
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        const id = self.window_registry.getActiveWindow();
        if (id) |active| assert(active.isValid());
        return id;
    }

    /// 设置活跃窗口。
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        if (id) |active| {
            assert(active.isValid());
            assert(self.window_registry.contains(active));
        }
        self.window_registry.setActiveWindow(id);
    }

    /// 取已注册窗口数量。
    pub fn windowCount(self: *const Self) u32 {
        const total = self.window_registry.count();
        assert(total <= WindowRegistry.MAX_WINDOWS);
        return total;
    }

    /// 安装每轮迭代的宿主钩子。`null` 表示清除。
    ///
    /// 契约固定入口；宿主为什么需要这个时点见 `platform/contract.zig`
    /// 里 `LoopTurnCallback` 的说明。
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    /// 运行应用事件循环。
    /// 阻塞直至调用 `quit()` 或应用终止。
    /// 渲染发生在 DisplayLink 线程，不在这里。
    pub fn run(self: *Self) void {
        assert(self.app.value != null);
        assert(!self.running);

        // 创建 autorelease pool（现代运行时 API: objc_autoreleasePoolPush/Pop）
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        self.running = true;

        // 激活应用
        _ = self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        // 通知启动完成
        _ = self.app.msgSend(void, "finishLaunching", .{});

        // 进入事件循环 —— 阻塞式
        while (self.running) {
            // 每次迭代建一个内层 autorelease pool
            const inner_pool = objc.AutoreleasePool.init();
            defer inner_pool.deinit();

            // 阻塞等待事件（省 CPU）
            const event = self.app.msgSend(
                ?*anyopaque,
                "nextEventMatchingMask:untilDate:inMode:dequeue:",
                .{
                    @as(u64, 0xFFFFFFFFFFFFFFFF), // NSEventMaskAny
                    getDistantFuture().value,
                    NSDefaultRunLoopMode,
                    true,
                },
            );

            if (event) |e| {
                self.app.msgSend(void, "sendEvent:", .{e});
                self.app.msgSend(void, "updateWindows", .{});
            }

            // `sendEvent:` 已返回，它执行的每个 AppKit delegate 回调 ——
            // 包括标题栏关闭触发的 `windowShouldClose:` / `windowWillClose:` ——
            // 都已出栈。此刻销毁窗口侧状态是安全的，宿主的钩子在这里触发。
            //
            // 放在 if 之外：即使没取到事件也要每轮触发一次，因为待回收的
            // 往往是**上一个**事件的关闭。
            //
            // AppKit 的嵌套 run loop（菜单追踪、模态面板、live resize）
            // 到不了这里，嵌套期间不触发钩子 —— 回收推迟到下一次外层
            // 迭代，这正是该钩子预期的延迟语义。
            if (self.loop_turn_callback) |on_turn| on_turn(self);
        }
    }

    pub fn quit(self: *Self) void {
        assert(self.app.value != null);

        self.running = false;
        assert(!self.isRunning());

        self.app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
    }

    /// 事件循环当前是否在泵事件。
    ///
    /// macOS 是 `blocking_event_loop` 后端，只有在 `run` 分发的回调
    /// 内部才观察得到。
    pub fn isRunning(self: *const Self) bool {
        assert(self.app.value != null);
        return self.running;
    }
};
