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

// `pump` 的非阻塞探测需要 distantPast
fn getDistantPast() objc.Object {
    const NSDate = objc.getClass("NSDate") orelse unreachable;
    return NSDate.msgSend(objc.Object, "distantPast", .{});
}

// `waitEvent` 的有界等待需要 `+[NSDate dateWithTimeIntervalSinceNow:]`
fn getDateAfterSeconds(seconds: f64) objc.Object {
    const NSDate = objc.getClass("NSDate") orelse unreachable;
    return NSDate.msgSend(objc.Object, "dateWithTimeIntervalSinceNow:", .{seconds});
}

pub const MacPlatform = struct {
    app: objc.Object,
    delegate: ?objc.Object,
    running: bool,

    /// 只在 `run()` 的糖循环执行期间为 true。`quit()` 靠它区分手段：
    /// 糖模式下要靠 `terminate:` 打断 `[NSApp …]` 时代的行为；过程模式
    /// （调用方自己的循环）里 `running` = false 就足够，多发的
    /// `terminate:` 会直接杀进程、跳过调用方的有序收尾。
    run_loop_active: bool = false,

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

    /// 进入运行状态（过程式循环的起点）。
    ///
    /// 过程式调用方必须在自己搭循环之前调一次；与 `run()` 不同，它
    /// 不激活应用、也不调 `finishLaunching`（那两件事属于 `run()` 的
    /// 启动糖）。重复调用属于用法错误。
    pub fn start(self: *Self) void {
        assert(self.app.value != null);
        assert(!self.running);
        self.running = true;
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

        self.start();
        self.run_loop_active = true;
        defer self.run_loop_active = false;

        // 激活应用
        _ = self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        // 通知启动完成
        _ = self.app.msgSend(void, "finishLaunching", .{});

        while (self.running) {
            // 等到下一批事件（`wait_infinite` 即 DistantFuture），随后
            // `pump` 把它连同时序撞车扎堆过来的兄弟一起分派完。
            _ = self.waitEvent(interface_mod.wait_infinite);
            if (!self.running) break;
            self.pump();
        }
    }

    /// 非阻塞泵一轮：取走**当前已就绪**的所有事件并逐个分派。
    ///
    /// 每取到一条就 `sendEvent:` + `updateWindows`（同原 `run` 迭代的
    /// 一致语义）；取空即返回。分派全程持一个本方法私有的 autorelease
    /// pool —— `sendEvent:` 进来的回调产生的自动释放对象在这里收口，
    /// 不落到调用方的 pool 里。
    ///
    /// 即使一条事件也没有，owner 回合钩子也要触发一次：待回收的往往
    /// 是上个事件的关闭（见 run 里对钩子的说明）。AppKit 的嵌套 run
    /// loop（菜单追踪、模态面板、live resize）到不了这里，嵌套期间
    /// 不触发钩子 —— 回收推迟到下一次外层迭代，正是该钩子的预期延迟
    /// 语义。
    ///
    /// 不做渲染调度：macOS 的帧节拍在 DisplayLink 线程独立派发，与泵
    /// 无关；不设 `setRenderCallback` 的调用方（过程模式）自己掌握帧。
    pub fn pump(self: *Self) void {
        assert(self.app.value != null);

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        // 与原 run 相同的掩码：NSEventMaskAny。
        const any_mask: u64 = 0xFFFFFFFFFFFFFFFF;
        const past = getDistantPast();

        while (true) {
            const event = self.app.msgSend(
                ?*anyopaque,
                "nextEventMatchingMask:untilDate:inMode:dequeue:",
                .{ any_mask, past.value, NSDefaultRunLoopMode, true },
            );
            if (event == null) break;

            self.app.msgSend(void, "sendEvent:", .{event.?});
            self.app.msgSend(void, "updateWindows", .{});

            // 回调里 quit() 之后不再排空，与 Win32 pump 对 WM_QUIT 的
            // 处理保持一致。
            if (!self.running) return;
        }

        if (self.loop_turn_callback) |on_turn| on_turn(self);
    }

    /// 最多阻塞 `timeout_ms` 毫秒等下一批事件。
    ///
    /// 用 `nextEventMatchingMask:untilDate:inMode:dequeue:` 做等待：有界
    /// 超时传 `+[NSDate dateWithTimeIntervalSinceNow:]`，无限期
    /// （`interface_mod.wait_infinite`）传 `distantFuture`，0 传
    /// `distantPast`（纯探测）。返回是否已有事件就绪（事件**留在**
    /// 队列里，`dequeue:` 是 false；分派归调用方的 `pump()`）。
    pub fn waitEvent(self: *Self, timeout_ms: u32) bool {
        assert(self.app.value != null);
        if (!self.running) return false;

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const any_mask: u64 = 0xFFFFFFFFFFFFFFFF;
        const date = if (timeout_ms == interface_mod.wait_infinite)
            getDistantFuture()
        else if (timeout_ms == 0)
            getDistantPast()
        else
            getDateAfterSeconds(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);

        const event = self.app.msgSend(
            ?*anyopaque,
            "nextEventMatchingMask:untilDate:inMode:dequeue:",
            .{ any_mask, date.value, NSDefaultRunLoopMode, false },
        );
        return event != null;
    }

    pub fn quit(self: *Self) void {
        assert(self.app.value != null);

        self.running = false;
        assert(!self.isRunning());

        // 糖模式（`run` 在栈上）保持历史行为：`terminate:` 打断默认
        // 假定牢固的事件循环。过程模式不发——调用方循环以
        // `isRunning()` 为条件，置 false 即优雅退出。
        if (self.run_loop_active) {
            self.app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
        }
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
