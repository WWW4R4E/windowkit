//! LinuxPlatform —— Linux/Wayland 平台实现。
//!
//! 提供 Linux 系统的主事件循环与平台生命周期，显示服务协议为 Wayland。

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland.zig");
const interface_mod = @import("../interface.zig");
const LinuxWindow = @import("window.zig").Window;
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;
const linux_input = @import("input.zig");
const input = @import("../../input/events.zig");
const dnd = @import("dnd.zig");

const HIDDEN_FRAME_POLL_MS: i32 = 50;

/// 单次 `wl_display_flush` 允许的重试次数，超过即本次迭代放弃。写缓冲
/// 满是暂态，下一次迭代会重试；设上限是因为无边界重试会把整个 UI 卡死
/// 在一帧之内。
const flush_attempts_max: u32 = 8;

fn eventLoopPollTimeout(has_pending_work: bool, waiting_for_frame: bool, refresh_rate_mhz: i32) i32 {
    std.debug.assert(refresh_rate_mhz > 0);
    std.debug.assert(refresh_rate_mhz <= 1_000_000);
    if (waiting_for_frame) return HIDDEN_FRAME_POLL_MS;
    if (has_pending_work) return 0;

    const frame_time_ms = @divFloor(@as(i32, 1_000_000), refresh_rate_mhz);
    return @max(frame_time_ms, 1);
}

/// 一个窗口对事件循环退出/节流决策的贡献量。
///
/// 从窗口**采样**出来，而不是经窗口读：这样下面的 fold 保持纯函数，
/// 没有 compositor 连接也能测试。
const WindowLoopState = struct {
    /// 窗口尚未记录关闭。
    open: bool,
    /// 有重绘、连续渲染模式或待处理的 resize 未了。
    has_queued_work: bool,
    /// `wl_callback` 在途，compositor 正在为该窗口节流。
    waiting_for_frame: bool,
};

/// 把所有注册窗口的 `WindowLoopState` 聚合起来。
const LoopState = struct {
    open_count: u32,
    has_pending_work: bool,
    all_waiting_for_frame: bool,
};

/// 把各窗口状态折合成事件循环的退出/节流决策。
///
/// `open_count` 数的是未记录关闭的窗口，*不是* registry 条目。已关闭的
/// 窗口在归属方认领（`App.drainClosedWindows`）前保持注册，按条目数就
/// 会让循环继续等一个永远不会再绘制的窗口。
///
/// `all_waiting_for_frame` 是 AND 不是 OR：一个窗口闲着等 `wl_callback`，
/// 不能挡住同帧内还有活要干的兄弟窗口被服务。只有所有打开窗口都被
/// compositor 节流时，循环才退回定时等待。单窗口情形恰好退化为之前的
/// `frame_callback != null` 测试。
fn foldLoopState(windows: []const WindowLoopState) LoopState {
    std.debug.assert(windows.len <= WindowRegistry.MAX_WINDOWS);

    var open_count: u32 = 0;
    var has_pending_work = false;
    var all_waiting_for_frame = true;

    for (windows) |window| {
        if (!window.open) continue;
        open_count += 1;
        if (window.has_queued_work) has_pending_work = true;
        if (!window.waiting_for_frame) all_waiting_for_frame = false;
    }

    std.debug.assert(open_count <= windows.len);
    if (open_count == 0) std.debug.assert(!has_pending_work);

    return .{
        .open_count = open_count,
        .has_pending_work = has_pending_work,
        .all_waiting_for_frame = all_waiting_for_frame,
    };
}

// 静态 listener：必须在 Wayland 对象的整个生命周期内持续存活
const registry_listener = wayland.RegistryListener{
    .global = LinuxPlatform.registryGlobal,
    .global_remove = LinuxPlatform.registryGlobalRemove,
};

const output_listener = wayland.OutputListener{
    .geometry = LinuxPlatform.outputGeometry,
    .mode = LinuxPlatform.outputMode,
    .done = LinuxPlatform.outputDone,
    .scale = LinuxPlatform.outputScale,
    .name = LinuxPlatform.outputName,
    .description = LinuxPlatform.outputDescription,
};

const wm_base_listener = wayland.XdgWmBaseListener{
    .ping = LinuxPlatform.xdgWmBasePing,
};

const seat_listener = wayland.SeatListener{
    .capabilities = LinuxPlatform.seatCapabilities,
    .name = LinuxPlatform.seatName,
};

const pointer_listener = wayland.PointerListener{
    .enter = LinuxPlatform.pointerEnter,
    .leave = LinuxPlatform.pointerLeave,
    .motion = LinuxPlatform.pointerMotion,
    .button = LinuxPlatform.pointerButton,
    .axis = LinuxPlatform.pointerAxis,
    .frame = LinuxPlatform.pointerFrame,
    .axis_source = LinuxPlatform.pointerAxisSource,
    .axis_stop = LinuxPlatform.pointerAxisStop,
    .axis_discrete = LinuxPlatform.pointerAxisDiscrete,
    .axis_value120 = LinuxPlatform.pointerAxisValue120,
    .axis_relative_direction = LinuxPlatform.pointerAxisRelativeDirection,
};

const keyboard_listener = wayland.KeyboardListener{
    .keymap = LinuxPlatform.keyboardKeymap,
    .enter = LinuxPlatform.keyboardEnter,
    .leave = LinuxPlatform.keyboardLeave,
    .key = LinuxPlatform.keyboardKey,
    .modifiers = LinuxPlatform.keyboardModifiers,
    .repeat_info = LinuxPlatform.keyboardRepeatInfo,
};

const touch_listener = wayland.TouchListener{
    .down = LinuxPlatform.touchDown,
    .up = LinuxPlatform.touchUp,
    .motion = LinuxPlatform.touchMotion,
    .frame = LinuxPlatform.touchFrame,
    .cancel = LinuxPlatform.touchCancel,
    .shape = LinuxPlatform.touchShape,
    .orientation = LinuxPlatform.touchOrientation,
};

// Text Input V3 listener，承载 IME 事件
const text_input_listener = wayland.ZwpTextInputV3Listener{
    .enter = LinuxPlatform.textInputEnter,
    .leave = LinuxPlatform.textInputLeave,
    .preedit_string = LinuxPlatform.textInputPreeditString,
    .commit_string = LinuxPlatform.textInputCommitString,
    .delete_surrounding_text = LinuxPlatform.textInputDeleteSurroundingText,
    .done = LinuxPlatform.textInputDone,
};

pub const LinuxPlatform = struct {
    /// 阻塞的 `run()` 循环在不在栈上。仅此含义。
    ///
    /// 支撑 `isRunning`，语义由 `platform/contract.zig` 钉死：`initInPlace`
    /// 后为 false，进入 `run` 到返回为 true，`quit` 之后为 false。
    /// 只由 `run` 与 `quit` 写，其他函数不许碰。
    running: bool = false,

    /// compositor 连接是否还能收发。
    ///
    /// 与 `running` 分开：调用方可以拿 `poll`/`dispatch`/
    /// `dispatchWithTimeout` 自己搭循环而不调 `run`——这些原语问的是
    /// "socket 还能用吗"，用 `running` 回答会冤枉合法的自管循环。
    ///
    /// 不能用 `display != null` 表达：致命协议错误杀掉连接时 `wl_display`
    /// 对象还在，`deinit` 还要靠这个指针销毁各 proxy 并调
    /// `wl_display_disconnect`。在错误现场置空 `display` 会泄漏连接，
    /// 所以存活状态需要自己的位。
    connection_alive: bool = false,

    display: ?*wayland.Display = null,

    /// 按 ID 跟踪所有窗口的 registry
    window_registry: WindowRegistry,

    /// 平台资源的分配器
    allocator: std.mem.Allocator,

    // 全局 Wayland 对象
    registry: ?*wayland.Registry = null,
    compositor: ?*wayland.Compositor = null,
    xdg_wm_base: ?*wayland.XdgWmBase = null,
    decoration_manager: ?*wayland.ZxdgDecorationManagerV1 = null,
    seat: ?*wayland.Seat = null,
    pointer: ?*wayland.Pointer = null,
    keyboard: ?*wayland.Keyboard = null,
    touch: ?*wayland.Touch = null,
    text_input_manager: ?*wayland.ZwpTextInputManagerV3 = null,
    text_input: ?*wayland.ZwpTextInputV3 = null,
    viewporter: ?*wayland.WpViewporter = null,
    cursor_shape_manager: ?*wayland.WpCursorShapeManagerV1 = null,
    cursor_shape_device: ?*wayland.WpCursorShapeDeviceV1 = null,
    output: ?*wayland.Output = null,

    // 显示器刷新率，单位毫赫兹（如 60000 = 60Hz、144000 = 144Hz）
    // 从 wl_output 拿到真实值之前默认 60Hz（60000 mHz）
    refresh_rate_mhz: i32 = 60000,

    // DnD(data-device)协议状态
    dnd_state: *dnd.DndState = dnd.getState(),
    // 窗口正在接收 DnD 手势(enter 记下,leave/drop 消费)
    dnd_target_window: ?*LinuxWindow = null,
    // 最近一次 enter/motion 的 surface 坐标(逻辑像素)
    dnd_x: f64 = 0,
    dnd_y: f64 = 0,

    // 输入状态
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: u32 = 0,
    last_key_serial: u32 = 0,
    last_pointer_serial: u32 = 0,
    pointer_enter_serial: ?u32 = null,
    cursor_shape: ?interface_mod.CursorShape = null,
    modifier_alt: bool = false,
    modifier_ctrl: bool = false,
    modifier_shift: bool = false,
    modifier_super: bool = false,

    // 输入派发、帧节流与交互式移动/缩放的目标窗口。派生自
    // `window_registry.active_window`——只能通过 `setActiveWindowId` 写，
    // 两处记录才不会分叉。
    active_window: ?*LinuxWindow = null,

    // 当前触摸手势序列所属的窗口
    touch_window: ?*LinuxWindow = null,

    // 来自 output 的缩放系数
    scale_factor: i32 = 1,

    /// 归属钩子，`run` 每迭代触发一次；见 `setLoopTurnCallback`。
    loop_turn_callback: ?LoopTurnCallback = null,

    // IME 状态（事件批次内累积，done 时统一应用）
    ime_preedit_text: ?[]const u8 = null,
    ime_commit_text: ?[]const u8 = null,
    ime_delete_before: u32 = 0,
    ime_delete_after: u32 = 0,
    ime_serial: u32 = 0,

    const Self = @This();

    /// Linux/Wayland 平台能力集
    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = true,
        .display_link = false, // 走帧回调
        .can_close_window = true,
        .glass_effects = false, // 取决于 compositor
        // wl_data_device DnD(接收端)。见 dnd.zig。
        .file_drop = true,
        .ime = true,
        .custom_cursors = true,
        .window_drag_by_content = false,
        .name = "Linux/Wayland",
    };

    // =========================================================================
    // 窗口注册表
    // =========================================================================

    /// 注册窗口并返回其 ID。
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        std.debug.assert(@intFromPtr(window) != 0);
        std.debug.assert(self.window_registry.count() < WindowRegistry.MAX_WINDOWS);

        const id = try self.window_registry.register(window);
        std.debug.assert(id.isValid());
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
        return self.window_registry.get(id);
    }

    /// 取当前 active window id。
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.window_registry.getActiveWindow();
    }

    /// 按 ID 设置 active window。
    ///
    /// `WindowId` 是唯一权威。Wayland 的指针、键盘、IME 派发都需要具体的
    /// `*LinuxWindow`，所以指针在这里*派生*而不是另行发布：两个 setter
    /// 会让 `getActiveWindowId()` 报一个窗口而事件进了另一个。
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.window_registry.setActiveWindow(id);
        self.active_window = if (id) |window_id|
            self.window_registry.getTyped(LinuxWindow, window_id)
        else
            null;

        // 上面的 `setActiveWindow` 已断言 id 在注册表里，所以查找不可能
        // 落空；这里为 null 就等于 registry 被破坏了。
        if (id != null) std.debug.assert(self.active_window != null);
        if (id == null) std.debug.assert(self.active_window == null);
    }

    /// 当前窗口关闭或消失后，把 active 角色交给一个还活着的打开窗口。
    ///
    /// `active_window` 是所有指针、键盘、IME 事件的路由目标，其他窗口
    /// 还开着时留 null 会让输入无家可归。跳过已关闭窗口：它们在归属方
    /// 认领前保持注册，把它们选上就是把事件派进一个已经宣布退场的
    /// 窗口。选任何打开窗口都是安全的：compositor 会在下一个 `enter`
    /// 事件里纠正我们。
    pub fn reelectActiveWindow(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        // registry 上限 MAX_WINDOWS，一遍扫描是有界工作。
        var scanned: u32 = 0;
        var chosen: ?WindowId = null;
        var ids = self.window_registry.iterator();
        while (ids.next()) |id| {
            std.debug.assert(scanned < WindowRegistry.MAX_WINDOWS);
            scanned += 1;
            std.debug.assert(id.isValid());

            const window = self.window_registry.getTyped(LinuxWindow, id.*) orelse continue;
            if (window.isClosed()) continue;

            chosen = id.*;
            break;
        }

        self.setActiveWindowId(chosen);
        std.debug.assert(scanned <= self.window_registry.count());
    }

    /// 取已注册窗口数。
    pub fn windowCount(self: *const Self) u32 {
        return self.window_registry.count();
    }

    /// `run` 循环每迭代调用一次的归属回调。
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// 安装每次迭代的归属钩子。传 `null` 清除。
    ///
    /// 契约钉死；为何归属方需要这个点见 `platform/contract.zig` 里
    /// `LoopTurnCallback` 的说明。
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    /// 把平台初始化到最终地址上。
    ///
    /// 不能做成按值的 `init`：`wl_registry_add_listener` 与
    /// `xdg_wm_base_add_listener` 会把 `data` 指针保留到 proxy 生命期结束，
    /// 传临时值的地址，等值被搬去家中后 compositor 就在往死帧里写。
    /// 所以 listener 的安装放在这里作为最终一步，而不是要求每个调用方
    /// 再记一次第二阶段调用。
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        std.debug.assert(@intFromPtr(self) != 0);

        self.* = Self{
            .window_registry = WindowRegistry.init(allocator),
            .allocator = allocator,
        };

        errdefer self.window_registry.deinit();

        self.display = wayland.wl_display_connect(null) orelse {
            return error.FailedToConnectToDisplay;
        };
        self.connection_alive = true;
        errdefer {
            // 断开连接顺带回收了下面 roundtrip 期间绑定的所有 global，
            // bind 失败不需要单独回滚。
            wayland.wl_display_disconnect(self.display.?);
            self.display = null;
            self.connection_alive = false;
        }

        self.registry = wayland.wl_display_get_registry(self.display.?) orelse {
            return error.FailedToGetRegistry;
        };
        errdefer {
            wayland.registryDestroy(self.registry.?);
            self.registry = null;
        }

        try self.setupListeners();

        std.debug.assert(self.compositor != null);
        std.debug.assert(self.xdg_wm_base != null);
        // 契约要求刚初始化的平台报告尚未启动宿主循环，所以只有 `run`
        // 能把 `isRunning` 变成 true。
        std.debug.assert(!self.running);
    }

    /// 绑定捕获 `self` 的 Wayland listener。
    ///
    /// 私有：只允许在 `initInPlace` 里调、且此时地址已经最终确定。
    fn setupListeners(self: *Self) !void {
        std.debug.assert(self.display != null);
        std.debug.assert(self.registry != null);

        // 用最终的指针位置挂 registry listener
        _ = wayland.registryAddListener(self.registry.?, &registry_listener, self);

        // roundtrip 拿全所有 global
        _ = wayland.wl_display_roundtrip(self.display.?);

        // 第二次 roundtrip：处理 seat capabilities，再绑键盘/指针
        _ = wayland.wl_display_roundtrip(self.display.?);

        // 校验必需的 global
        if (self.compositor == null) {
            return error.MissingCompositor;
        }
        if (self.xdg_wm_base == null) {
            return error.MissingXdgWmBase;
        }

        // 用最终的指针挂 XDG WM base 的 ping/pong listener
        _ = wayland.xdgWmBaseAddListener(self.xdg_wm_base.?, &wm_base_listener, self);

        // manager 与 seat 齐了就配好 DnD data device
        if (self.dnd_state.data_device_manager != null and self.seat != null) {
            self.dnd_state.setupDataDevice(self.seat.?, self.display.?);
            if (self.dnd_state.data_device) |device| {
                _ = dnd.dataDeviceAddListener(device, &dnd_device_listener, self);
            }
        }
    }

    pub fn deinit(self: *Self) void {
        // 拆除不能跑在 `run` 之下：它会释放循环还在读的 registry 和连接。
        // `run` 在每个出口都会清 `running`，这里还活着就是调用方重入了。
        std.debug.assert(!self.running);

        // 清理窗口注册表
        self.window_registry.deinit();

        // display 没了就别尝试销毁 Wayland 对象
        if (self.display == null) {
            self.connection_alive = false;
            return;
        }

        // 按创建逆序销毁，主要对象之间 flush
        // DnD data device 先走（依赖 seat 与 manager）
        self.dnd_state.deinit();

        // Text input（依赖 seat 与 manager）
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Destroy(ti);
            self.text_input = null;
        }
        if (self.text_input_manager) |tim| {
            wayland.zwpTextInputManagerV3Destroy(tim);
            self.text_input_manager = null;
        }

        // 输入设备（都依赖 seat）
        if (self.cursor_shape_device) |device| {
            wayland.cursorShapeDeviceDestroy(device);
            self.cursor_shape_device = null;
        }
        if (self.keyboard) |kb| {
            wayland.keyboardDestroy(kb);
            self.keyboard = null;
        }
        if (self.pointer) |ptr| {
            wayland.pointerDestroy(ptr);
            self.pointer = null;
        }

        // flush 确保 destroy 请求先于 seat 销毁送达
        _ = wayland.wl_display_flush(self.display.?);

        if (self.seat) |seat| {
            wayland.seatDestroy(seat);
            self.seat = null;
        }
        if (self.decoration_manager) |dm| {
            wayland.zxdgDecorationManagerV1Destroy(dm);
            self.decoration_manager = null;
        }
        if (self.cursor_shape_manager) |manager| {
            wayland.cursorShapeManagerDestroy(manager);
            self.cursor_shape_manager = null;
        }
        if (self.xdg_wm_base) |wm| {
            wayland.xdgWmBaseDestroy(wm);
            self.xdg_wm_base = null;
        }
        if (self.output) |output| {
            wayland.outputDestroy(output);
            self.output = null;
        }
        if (self.compositor) |comp| {
            wayland.compositorDestroy(comp);
            self.compositor = null;
        }
        if (self.registry) |reg| {
            wayland.registryDestroy(reg);
            self.registry = null;
        }

        // 断开前最后一次 flush
        _ = wayland.wl_display_flush(self.display.?);

        // 最后断连
        wayland.wl_display_disconnect(self.display.?);
        self.display = null;

        self.connection_alive = false;
    }

    /// 非阻塞泵一轮：把已排队的事件一次性派发完，并顺带 flush 与探测。
    ///
    /// 三步，全部非阻塞：
    /// 1. `wl_display_dispatch_pending` — 派发**已进队列**的事件（输入、
    ///    configure、frame callback 到点）；
    /// 2. `flushDisplay` — 把出站请求推出去（新窗口的初始 configure 不
    ///    flush 永远不会回来）；
    /// 3. `poll(fd, 0)` 探测内核缓冲 — 有可读就 `wl_display_dispatch`
    ///    读进并分派（此时必不阻塞；数据已在）。
    ///
    /// 只用 `pump` 纯 busy 轮询的调用方靠第 3 步才不会饿死；配合
    /// `waitEvent` 的标准形式则第 3 步多半空跑，代价一次系统调用。
    /// 本方法不等待、不做渲染调度。连接错误（任一 dispatch 返负）同时
    /// 置 `connection_alive` 与 `running` = false，`waitEvent` 从此恒
    /// false，过程式循环随 `isRunning()` 退出。
    pub fn pump(self: *Self) void {
        // 无连接 / 连接已死都是终态：process 模式靠 `isRunning()` 退圈，
        // 所以这里必须把 `running` 一并落下，不能只置 `connection_alive`。
        const display = self.display orelse {
            self.running = false;
            return;
        };
        if (!self.connection_alive) {
            self.running = false;
            return;
        }

        if (wayland.displayDispatchPending(display) < 0) {
            self.connection_alive = false;
            self.running = false;
            return;
        }

        const fd = wayland.displayGetFd(display);
        var pollfds_buf: [1]posix.pollfd = undefined;
        const pollfds = pollfds_buf[0..1];
        pollfds[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };

        if (!self.flushDisplay(display, pollfds)) {
            self.running = false;
            return;
        }

        const probe = posix.poll(pollfds, 0) catch {
            self.connection_alive = false;
            self.running = false;
            return;
        };
        if (probe > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
            if (wayland.displayDispatch(display) < 0) {
                self.connection_alive = false;
                self.running = false;
            }
        }
    }

    /// 最多阻塞 `timeout_ms` 毫秒等下一批 Wayland 事件。
    ///
    /// 先把出站请求 flush 出去，再 `poll` display fd（与 `run` 同一份
    /// 事件源）；fd 就绪返 true（fd 可读态会保持到数据被读走），分派
    /// 归调用方随之而来的 `pump()`。超时、无事件源（无连接 / 连接死亡）
    /// 返 false。`timeout_ms` 传 `interface_mod.wait_infinite` 表示
    /// 无限期阻塞（poll 第二参 -1）。
    ///
    /// 本方法不做渲染调度：frame callback 到点后 fd 变可读、本方法唤醒，
    /// 渲染时机仍归调用方。
    pub fn waitEvent(self: *Self, timeout_ms: u32) bool {
        const display = self.display orelse {
            self.running = false;
            return false;
        };
        if (!self.connection_alive) {
            self.running = false;
            return false;
        }
        if (!self.running) return false;

        const fd = wayland.displayGetFd(display);
        var pollfds_buf: [1]posix.pollfd = undefined;
        const pollfds = pollfds_buf[0..1];
        pollfds[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };

        if (!self.flushDisplay(display, pollfds)) {
            self.running = false;
            return false;
        }

        const timeout: i32 = if (timeout_ms == interface_mod.wait_infinite)
            -1
        else
            @intCast(timeout_ms);

        const poll_result = posix.poll(pollfds, timeout) catch {
            self.connection_alive = false;
            self.running = false;
            return false;
        };
        if (poll_result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
            return true;
        }
        // 连接死亡时 poll 会给 POLLERR/POLLHUP（无 POLLIN）；不查它的话
        // 过程式循环会在死连接上永久等下去。
        if (poll_result > 0 and (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0) {
            self.connection_alive = false;
            self.running = false;
        }
        return false;
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
        std.debug.assert(!self.running);
        self.running = true;
    }

    /// 运行平台事件循环（阻塞）。
    ///
    /// 用 `poll()` 而不是 `wl_display_dispatch`：帧回调可以在 vsync 频率
    /// 驱动渲染，而不会阻塞在输入上。
    ///
    /// 循环在*任何*已注册窗口打开期间存活，并服务*每一个*打开的窗口。
    ///
    /// `running` 在 display 守卫*之后*置位而不是之前：没有连接就没有
    /// 循环，归属方若采样 `isRunning`，不应在无连接时被告知循环已在
    /// 跑。`defer` 与置位配对，保证每条出口——quit、最后窗口关闭、
    /// 连接死亡——最终 `running` 都是 false。
    pub fn run(self: *Self) void {
        const display = self.display orelse return;
        const fd = wayland.displayGetFd(display);
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
        std.debug.assert(!self.running);

        self.running = true;
        defer self.running = false;

        var pollfds_buf: [8]posix.pollfd = undefined;

        while (self.running) {
            pollfds_buf[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
            const pollfds = pollfds_buf[0..1];

            // 先把归属方的回合给出去，此时没有窗口回调在栈上：下面的
            // `wl_display_dispatch` 才是跑回调的地方，控制权回到这里时
            // 它已完全展开。上一迭代中 compositor/标题栏关掉的窗口会在
            // 这里被认领，也正因此下面的 `open_count` 判断看到的才是
            // 已经缩小的 registry，而不是在数尸体。
            //
            // 放在退出测试之前而不是之后：认领最后一个窗口正是结束
            // 循环的情形，而且归属方可能在这里调 `quit`。
            if (self.loop_turn_callback) |on_turn| on_turn(self);
            if (!self.running) break;

            // 没有打开窗口就没有可呈现的 surface，compositor 也无处
            // 送事件，再迭代也不可能有状态变化。停在这里不是退出策略：
            // `App.checkQuitCondition` 仍然拥有那个决定，`quit()` 也
            // 仍是归属方提前停循环的手段。
            if (self.collectLoopState().open_count == 0) break;

            self.renderOpenWindows();

            if (!self.flushDisplay(display, pollfds)) break;

            // 先派发已在队列里的事件，再决定等多久，让本次迭代的节流
            // 感知到它们。
            if (wayland.wl_display_dispatch_pending(display) < 0) {
                self.connection_alive = false;
                break;
            }

            // 帧回调在途时绝不空转。compositor 会扣住隐藏窗口的回调，
            // 所以用与其他 Wayland 客户端一样的 20Hz 兜底节奏，同时可见
            // surface 的回调一到立即唤醒。
            const pacing = self.collectLoopState();
            const timeout_ms = eventLoopPollTimeout(
                pacing.has_pending_work,
                pacing.all_waiting_for_frame,
                self.refresh_rate_mhz,
            );
            // display fd 上 poll 失败后无从得知 socket 何时可读，只能
            // 视作连接死亡，而不是盲重试，与 dispatch 失败同理。
            const poll_result = posix.poll(pollfds, timeout_ms) catch {
                self.connection_alive = false;
                break;
            };

            if (poll_result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
                if (wayland.wl_display_dispatch(display) < 0) {
                    self.connection_alive = false;
                    break;
                }
            }
        }
    }

    /// 采样每个注册窗口并折算事件循环的决策。
    ///
    /// 只读，所以直接迭代 registry map 是安全的：这一趟没有任何路径能
    /// 跑应用代码、触发 rehash。
    fn collectLoopState(self: *const Self) LoopState {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        var samples: [WindowRegistry.MAX_WINDOWS]WindowLoopState = undefined;
        var found: u32 = 0;

        var ids = self.window_registry.iterator();
        while (ids.next()) |id| {
            std.debug.assert(found < WindowRegistry.MAX_WINDOWS);
            std.debug.assert(id.isValid());

            const window = self.window_registry.getTyped(LinuxWindow, id.*) orelse continue;
            samples[found] = .{
                .open = !window.isClosed(),
                .has_queued_work = window.needs_redraw or window.continuous_render or
                    window.pending_resize,
                .waiting_for_frame = window.frame_callback != null,
            };
            found += 1;
        }

        std.debug.assert(found <= self.window_registry.count());
        return foldLoopState(samples[0..found]);
    }

    /// 呈现每一个 compositor 尚未节流的打开窗口。
    ///
    /// 只在没有待决 compositor 回调时才急切渲染：`frameCallback()` 期间
    /// 请求的重绘必须排队等那次新排的回调触发，否则每个 compositor
    /// tick 提交两次动画帧。
    ///
    /// 窗口 id 在任何渲染开始前先拷出来。`renderFrame` 会跑应用的渲染
    /// 回调，回调里可能开/关窗口从而 rehash registry 的 map；若跨过
    /// 这个点还持有活迭代器就会走过已释放的桶。每个 id 在使用前立即
    /// 重新解析，而 `Window.deinit` 在释放前注销，所以本轮更早销毁的
    /// 窗口解析为 null 而不是悬垂指针。
    fn renderOpenWindows(self: *Self) void {
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        const found = self.snapshotWindowIds(&ids);
        std.debug.assert(found <= WindowRegistry.MAX_WINDOWS);

        for (ids[0..found]) |id| {
            std.debug.assert(id.isValid());

            const window = self.window_registry.getTyped(LinuxWindow, id) orelse continue;
            if (window.isClosed()) continue;

            // 无 buffer surface 可能收不到首个回调，所以用一次急切呈现
            // 完成 bootstrap。之后的帧都由在途的 compositor 回调节流。
            if (window.frame_callback == null or !window.has_presented_frame) {
                window.renderFrame();
            }
        }
    }

    /// 把所有注册窗口的 id 拷进调用方存储。
    ///
    /// 返回写入数量。上界 `MAX_WINDOWS` 同时也是 registry 自身的硬上限，
    /// 所以目标数组不可能溢出。
    fn snapshotWindowIds(
        self: *const Self,
        out: *[WindowRegistry.MAX_WINDOWS]WindowId,
    ) u32 {
        std.debug.assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        var found: u32 = 0;
        var ids = self.window_registry.iterator();
        while (ids.next()) |id| {
            std.debug.assert(found < WindowRegistry.MAX_WINDOWS);
            std.debug.assert(id.isValid());
            out[found] = id.*;
            found += 1;
        }

        std.debug.assert(found == self.window_registry.count());
        return found;
    }

    /// poll 前先把出口请求缓冲清掉。
    ///
    /// 只在连接已死返回 false，那时 `connection_alive` 已清、调用方必须
    /// 退出循环。写缓冲满（`EAGAIN`）最多等 `flush_attempts_max` 次；
    /// 超限后返回 true 让调用方完成本次迭代再重试，而不是在一帧之内
    /// 无限期阻塞。
    fn flushDisplay(self: *Self, display: *wayland.Display, pollfds: []posix.pollfd) bool {
        std.debug.assert(pollfds.len == 1);
        std.debug.assert(pollfds[0].events == posix.POLL.IN);

        var attempts: u32 = 0;
        while (attempts < flush_attempts_max) : (attempts += 1) {
            if (wayland.wl_display_flush(display) >= 0) return true;

            // EAGAIN 表示写缓冲满，等可写再试（Linux 上 EAGAIN ==
            // EWOULDBLOCK）。其他错误一律致命。
            const errno_val = std.c._errno().*;
            if (errno_val != @backingInt(posix.E.AGAIN)) {
                self.connection_alive = false;
                return false;
            }

            pollfds[0].events = posix.POLL.OUT;
            _ = posix.poll(pollfds, -1) catch {
                pollfds[0].events = posix.POLL.IN;
                return true;
            };
            pollfds[0].events = posix.POLL.IN;
        }

        std.debug.assert(attempts == flush_attempts_max);
        return true;
    }

    /// 跑事件循环的单次迭代（非阻塞）
    /// 派发已从 socket 读到的积压事件。
    ///
    /// 门禁是连接存活而不是 `running`：这是调用方替代 `run` 自搭循环的
    /// 原语之一，`isRunning` 为 false 时也必须能工作。
    pub fn poll(self: *Self) bool {
        if (!self.connection_alive) return false;
        const display = self.display orelse return false;

        // 刷出出口请求
        _ = wayland.wl_display_flush(display);

        // 派发积压事件（已在队列里的）
        if (wayland.wl_display_dispatch_pending(display) < 0) {
            self.connection_alive = false;
            return false;
        }

        return true;
    }

    /// 阻塞等事件再派发。
    ///
    /// 连接断开后返回 false。与 `poll` 一样不依赖 `running`，
    /// 自管循环不用进 `run` 也能用。
    pub fn dispatch(self: *Self) bool {
        if (!self.connection_alive) return false;
        const display = self.display orelse return false;

        // 这里会阻塞到事件可用为止
        if (wayland.wl_display_dispatch(display) < 0) {
            self.connection_alive = false;
            return false;
        }

        return true;
    }

    /// 带超时等事件再派发。
    /// 连续渲染用它——不会像 dispatch() 那样无限阻塞，帧回调可以以
    /// vsync 频率驱动渲染。
    /// timeout_ms：-1 = 永久阻塞，0 = 非阻塞，>0 = 最多等这么久
    ///
    /// 连接断开后返回 false。与 `poll` 一样不依赖 `running`，
    /// 自管循环不用进 `run` 也能用。
    pub fn dispatchWithTimeout(self: *Self, timeout_ms: i32) bool {
        std.debug.assert(timeout_ms >= -1);
        if (!self.connection_alive) return false;
        const display = self.display orelse return false;

        // 先刷出出口请求
        while (true) {
            const flush_result = wayland.wl_display_flush(display);
            if (flush_result >= 0) break;
            // EAGAIN 表示写缓冲满（Linux 上 EAGAIN == EWOULDBLOCK）
            const errno_val = std.c._errno().*;
            if (errno_val == @backingInt(posix.E.AGAIN)) {
                // poll 可写性
                var pollfds = [_]posix.pollfd{
                    .{ .fd = wayland.displayGetFd(display), .events = posix.POLL.OUT, .revents = 0 },
                };
                _ = posix.poll(&pollfds, -1) catch {
                    self.connection_alive = false;
                    return false;
                };
            } else {
                self.connection_alive = false;
                return false;
            }
        }

        // 派发已积压的事件
        if (wayland.wl_display_dispatch_pending(display) < 0) {
            self.connection_alive = false;
            return false;
        }

        // 带超时 poll 新事件
        var pollfds = [_]posix.pollfd{
            .{ .fd = wayland.displayGetFd(display), .events = posix.POLL.IN, .revents = 0 },
        };
        const poll_result = posix.poll(&pollfds, timeout_ms) catch {
            self.connection_alive = false;
            return false;
        };

        // 有事件到达就派发
        if (poll_result > 0 and (pollfds[0].revents & posix.POLL.IN) != 0) {
            if (wayland.wl_display_dispatch(display) < 0) {
                self.connection_alive = false;
                return false;
            }
        }

        return true;
    }

    /// 把积压请求冲给服务端
    pub fn flush(self: *Self) void {
        if (self.display) |display| {
            _ = wayland.wl_display_flush(display);
        }
    }

    /// 请求平台退出。
    ///
    /// 让 `run` 循环在下一个条件测试处停止。不碰连接：断连是 `deinit`
    /// 的职责，调用方自管循环之后照常派发。
    pub fn quit(self: *Self) void {
        // `run` 只在有 display 时启动，且只有 `deinit` 会丢 display，
        // 所以还活着的循环一定有连接对象可停。
        if (self.running) std.debug.assert(self.display != null);

        self.running = false;
    }

    /// 循环是否应继续：`start()` 之后、`quit()` / 连接死亡之前为 true。
    ///
    /// 过程式循环拿它当 while 条件；它是循环生命周期信号，不是
    /// 存活/可用性信号——那些用 `isConnected`。
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// compositor 连接是否还能收发。
    ///
    /// 这才是用 `poll`/`dispatch` 自管循环的调用方该测的东西：
    /// 按契约这类循环里 `isRunning` 全程为 false。
    pub fn isConnected(self: *const Self) bool {
        if (self.connection_alive) std.debug.assert(self.display != null);

        return self.connection_alive;
    }

    /// 取 Wayland display 指针（供 wgpu 建 surface 等）
    pub fn getDisplay(self: *Self) ?*anyopaque {
        return @ptrCast(self.display);
    }

    /// 取建 surface 用的 compositor
    pub fn getCompositor(self: *Self) ?*wayland.Compositor {
        return self.compositor;
    }

    /// 取窗口管理用的 XDG WM base
    pub fn getXdgWmBase(self: *Self) ?*wayland.XdgWmBase {
        return self.xdg_wm_base;
    }

    /// 取 decoration manager（不支持时为 null）
    pub fn getDecorationManager(self: *Self) ?*wayland.ZxdgDecorationManagerV1 {
        return self.decoration_manager;
    }

    /// 取 viewporter（HiDPI 支持，可能为 null）
    pub fn getViewporter(self: *Self) ?*wayland.WpViewporter {
        return self.viewporter;
    }

    /// 取当前缩放系数
    pub fn getScaleFactor(self: *const Self) f64 {
        return @floatFromInt(self.scale_factor);
    }

    fn ensureCursorShapeDevice(self: *Self) void {
        if (self.cursor_shape_device != null) std.debug.assert(self.pointer != null);
        if (self.cursor_shape_device != null) std.debug.assert(self.cursor_shape_manager != null);
        if (self.cursor_shape_device != null) return;

        const manager = self.cursor_shape_manager orelse return;
        const pointer = self.pointer orelse return;
        self.cursor_shape_device = wayland.cursorShapeManagerGetPointer(manager, pointer);
        std.debug.assert(self.cursor_shape_manager != null);
        std.debug.assert(self.pointer != null);
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        if (self.cursor_shape_device != null) std.debug.assert(self.pointer != null);
        if (self.cursor_shape_device != null) std.debug.assert(self.cursor_shape_manager != null);
        if (self.cursor_shape == shape) return;
        const serial = self.pointer_enter_serial orelse return;
        const device = self.cursor_shape_device orelse return;

        const protocol_shape: u32 = switch (shape) {
            .default => 1,
            .text => 9,
            .pointer => 4,
        };
        wayland.cursorShapeDeviceSetShape(device, serial, protocol_shape);
        self.cursor_shape = shape;
    }

    // =========================================================================
    // Wayland 回调
    // =========================================================================

    fn registryGlobal(
        data: ?*anyopaque,
        registry: *wayland.Registry,
        name: u32,
        iface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        const interface_name = std.mem.span(iface);

        // Debug：列出所有可用协议（调试时自行打开注释）
        // std.debug.print("Wayland global: {s} (name={d}, version={d})\n", .{ interface_name, name, version });

        if (std.mem.eql(u8, interface_name, wayland.WL_COMPOSITOR_INTERFACE_NAME)) {
            self.compositor = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.wl_compositor_interface,
                @min(version, 6),
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.XDG_WM_BASE_INTERFACE_NAME)) {
            self.xdg_wm_base = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.xdg_wm_base_interface,
                @min(version, 6),
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.ZXDG_DECORATION_MANAGER_V1_INTERFACE_NAME)) {
            self.decoration_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.zxdg_decoration_manager_v1_interface,
                @min(version, 1),
            )));
        } else if (std.mem.eql(u8, interface_name, wayland.WL_SEAT_INTERFACE_NAME)) {
            self.seat = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.wl_seat_interface,
                @min(version, 8),
            )));

            if (self.seat) |seat| {
                // 用模块级静态 listener
                _ = wayland.seatAddListener(seat, &seat_listener, self);
            }
        } else if (std.mem.eql(u8, interface_name, wayland.ZWP_TEXT_INPUT_MANAGER_V3_INTERFACE_NAME)) {
            self.text_input_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.zwp_text_input_manager_v3_interface,
                @min(version, 1),
            )));

            // manager 与 seat 齐了就创建 text input 对象
            if (self.text_input_manager != null and self.seat != null and self.text_input == null) {
                self.text_input = wayland.zwpTextInputManagerV3GetTextInput(self.text_input_manager.?, self.seat.?);
                if (self.text_input) |ti| {
                    wayland.zwpTextInputV3AddListener(ti, &text_input_listener, self);
                }
            }
        } else if (std.mem.eql(u8, interface_name, wayland.WP_VIEWPORTER_INTERFACE_NAME)) {
            self.viewporter = wayland.bindViewporter(registry, name, version);
        } else if (std.mem.eql(u8, interface_name, wayland.WP_CURSOR_SHAPE_MANAGER_V1_INTERFACE_NAME)) {
            self.cursor_shape_manager = @ptrCast(@alignCast(wayland.registryBind(
                registry,
                name,
                &wayland.wp_cursor_shape_manager_v1_interface,
                @min(version, 2),
            )));
            self.ensureCursorShapeDevice();
        } else if (std.mem.eql(u8, interface_name, wayland.WL_OUTPUT_INTERFACE_NAME)) {
            // 只绑第一个 output（要刷新率）
            if (self.output == null) {
                self.output = @ptrCast(@alignCast(wayland.registryBind(
                    registry,
                    name,
                    wayland.getOutputInterface(),
                    @min(version, 4),
                )));
                if (self.output) |output| {
                    _ = wayland.outputAddListener(output, &output_listener, self);
                }
            }
        } else if (std.mem.eql(u8, interface_name, dnd.WL_DATA_DEVICE_MANAGER_INTERFACE_NAME)) {
            self.dnd_state.bindManager(registry, name, version);
            // data device 的装配推迟到 setupListeners() 的 roundtrip 完成之后
        }
    }

    fn registryGlobalRemove(
        data: ?*anyopaque,
        registry: *wayland.Registry,
        name: u32,
    ) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
        // 需要时再处理 global 移除
    }

    // =========================================================================
    // Output listener 回调
    // =========================================================================

    fn outputGeometry(
        data: ?*anyopaque,
        output: *wayland.Output,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: [*:0]const u8,
        model: [*:0]const u8,
        transform: i32,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        _ = x;
        _ = y;
        _ = physical_width;
        _ = physical_height;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
        // 几何信息只是参考，我们只关心 mode 和 scale
    }

    fn outputMode(
        data: ?*anyopaque,
        output: *wayland.Output,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ) callconv(.c) void {
        _ = output;
        _ = width;
        _ = height;
        const self: *Self = @ptrCast(@alignCast(data));

        // WL_OUTPUT_MODE_CURRENT（0x1）：只认当前显示模式
        const WL_OUTPUT_MODE_CURRENT: u32 = 0x1;
        if ((flags & WL_OUTPUT_MODE_CURRENT) != 0 and refresh > 0) {
            self.refresh_rate_mhz = refresh;
            std.debug.print("Display refresh rate: {}mHz ({d:.1}Hz)\n", .{
                refresh,
                @as(f64, @floatFromInt(refresh)) / 1000.0,
            });
        }
    }

    fn outputScale(
        data: ?*anyopaque,
        output: *wayland.Output,
        factor: i32,
    ) callconv(.c) void {
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));

        if (factor > 0) {
            self.scale_factor = factor;
        }
    }

    fn outputDone(
        data: ?*anyopaque,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        // 所有 output 属性都已送达
    }

    fn outputName(
        data: ?*anyopaque,
        output: *wayland.Output,
        name: [*:0]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        _ = name;
        // output 名字只是参考
    }

    fn outputDescription(
        data: ?*anyopaque,
        output: *wayland.Output,
        description: [*:0]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = output;
        _ = description;
        // output 描述只是参考
    }

    fn xdgWmBasePing(
        data: ?*anyopaque,
        xdg_wm_base: *wayland.XdgWmBase,
        serial: u32,
    ) callconv(.c) void {
        _ = data;
        wayland.xdgWmBasePong(xdg_wm_base, serial);
    }

    fn seatName(
        data: ?*anyopaque,
        seat: *wayland.Seat,
        name: [*:0]const u8,
    ) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
        // seat 名字只是参考，不用它做事
    }

    fn seatCapabilities(
        data: ?*anyopaque,
        seat: *wayland.Seat,
        caps: wayland.SeatCapability,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));

        // 处理指针
        if (caps.pointer and self.pointer == null) {
            self.pointer = wayland.seatGetPointer(seat);
            if (self.pointer) |ptr| {
                // 用模块级静态 listener
                _ = wayland.pointerAddListener(ptr, &pointer_listener, self);
            }
            self.ensureCursorShapeDevice();
        } else if (!caps.pointer and self.pointer != null) {
            if (self.cursor_shape_device) |device| {
                wayland.cursorShapeDeviceDestroy(device);
                self.cursor_shape_device = null;
            }
            wayland.pointerDestroy(self.pointer.?);
            self.pointer = null;
            self.pointer_enter_serial = null;
            self.cursor_shape = null;
        }

        // 处理键盘
        if (caps.keyboard and self.keyboard == null) {
            self.keyboard = wayland.seatGetKeyboard(seat);
            if (self.keyboard) |kb| {
                // 用模块级静态 listener
                _ = wayland.keyboardAddListener(kb, &keyboard_listener, self);
            }
        } else if (!caps.keyboard and self.keyboard != null) {
            wayland.keyboardDestroy(self.keyboard.?);
            self.keyboard = null;
        }

        // 处理触摸
        if (caps.touch and self.touch == null) {
            std.debug.print("touch: seat advertises touch capability, acquiring device\n", .{});
            self.touch = wayland.seatGetTouch(seat);
            if (self.touch) |t| {
                _ = wayland.touchAddListener(t, &touch_listener, self);
            }
        } else if (!caps.touch and self.touch != null) {
            wayland.touchDestroy(self.touch.?);
            self.touch = null;
        }

        // seat 与 manager 现在都有了就创建 text input
        if (self.text_input_manager != null and self.text_input == null) {
            self.text_input = wayland.zwpTextInputManagerV3GetTextInput(self.text_input_manager.?, seat);
            if (self.text_input) |ti| {
                wayland.zwpTextInputV3AddListener(ti, &text_input_listener, self);
            }
        }
    }

    fn pointerEnter(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        serial: u32,
        surface: *wayland.Surface,
        surface_x: wayland.Fixed,
        surface_y: wayland.Fixed,
    ) callconv(.c) void {
        _ = pointer;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data));
        self.last_pointer_serial = serial;
        self.pointer_enter_serial = serial;
        self.pointer_x = wayland.fixedToDouble(surface_x);
        self.pointer_y = wayland.fixedToDouble(surface_y);
        self.cursor_shape = null;
        self.setCursorShape(.default);

        // 派发 mouse_entered 给 active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );
            const event = linux_input.mouseEnteredEvent(self.pointer_x, self.pointer_y, modifiers);
            _ = window.handleInput(event);
        }
    }

    fn pointerLeave(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        serial: u32,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = pointer;
        _ = serial;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data));
        self.pointer_enter_serial = null;
        self.cursor_shape = null;

        // 派发 mouse_exited 给 active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );
            const event = linux_input.mouseExitedEvent(self.pointer_x, self.pointer_y, modifiers);
            _ = window.handleInput(event);
        }
    }

    fn pointerMotion(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        time: u32,
        surface_x: wayland.Fixed,
        surface_y: wayland.Fixed,
    ) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));
        self.pointer_x = wayland.fixedToDouble(surface_x);
        self.pointer_y = wayland.fixedToDouble(surface_y);

        // 派发 mouse_moved / mouse_dragged 给 active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );

            const event = if (window.pressed_button) |button|
                linux_input.mouseDraggedEvent(self.pointer_x, self.pointer_y, button, modifiers)
            else
                linux_input.mouseMovedEvent(self.pointer_x, self.pointer_y, modifiers);

            _ = window.handleInput(event);
        }
    }

    fn pointerButton(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        serial: u32,
        time: u32,
        button: u32,
        state: wayland.PointerButtonState,
    ) callconv(.c) void {
        _ = pointer;
        const self: *Self = @ptrCast(@alignCast(data));

        // 记下 serial，供交互式移动/缩放用
        self.last_pointer_serial = serial;

        const button_bit: u32 = switch (button) {
            wayland.BTN_LEFT => 1,
            wayland.BTN_RIGHT => 2,
            wayland.BTN_MIDDLE => 4,
            else => 0,
        };

        const modifiers = linux_input.modifiersFromFlags(
            self.modifier_shift,
            self.modifier_ctrl,
            self.modifier_alt,
            self.modifier_super,
        );

        if (state == .pressed) {
            self.pointer_buttons |= button_bit;

            // 派发 mouse_down 给 active window
            if (self.active_window) |window| {
                // 记连击数，供双击/三连击检测
                const click_count = window.click_tracker.recordClick(
                    time,
                    self.pointer_x,
                    self.pointer_y,
                    button,
                );

                const event = linux_input.mouseDownEvent(
                    self.pointer_x,
                    self.pointer_y,
                    button,
                    click_count,
                    modifiers,
                );
                const handled = window.handleInput(event);

                // 没有服务端装饰时自己做窗口管理，
                // 仅在应用没处理该事件时兜底。
                if (!handled and !window.has_server_decorations and button == wayland.BTN_LEFT) {
                    const border_width: f64 = 8.0;
                    const title_bar_height: f64 = 32.0;

                    // 先看缩放边缘
                    if (window.getResizeEdge(self.pointer_x, self.pointer_y, border_width)) |edge| {
                        window.startResize(edge);
                    } else if (window.isInTitleBar(self.pointer_y, title_bar_height)) {
                        // 在标题栏区域则发起移动
                        window.startMove();
                    }
                }
            }
        } else {
            self.pointer_buttons &= ~button_bit;

            // 派发 mouse_up 给 active window
            if (self.active_window) |window| {
                const event = linux_input.mouseUpEvent(
                    self.pointer_x,
                    self.pointer_y,
                    button,
                    modifiers,
                );
                _ = window.handleInput(event);
            }
        }
    }

    fn pointerAxis(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        time: u32,
        axis: wayland.PointerAxis,
        value: wayland.Fixed,
    ) callconv(.c) void {
        _ = pointer;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));

        // axis 值 → delta
        const delta = wayland.fixedToDouble(value);

        // 派发 scroll 事件给 active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );

            // Wayland 的水平/垂直滚动是分开的事件
            const delta_x: f64 = if (axis == .horizontal_scroll) delta else 0;
            const delta_y: f64 = if (axis == .vertical_scroll) delta else 0;

            const event = linux_input.scrollEvent(
                self.pointer_x,
                self.pointer_y,
                delta_x,
                delta_y,
                modifiers,
            );
            _ = window.handleInput(event);
        }
    }

    fn pointerFrame(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        // frame 事件标记一组指针事件的结束
    }

    fn pointerAxisSource(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis_source: wayland.PointerAxisSource,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis_source;
    }

    fn pointerAxisStop(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        time: u32,
        axis: wayland.PointerAxis,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
    }

    fn pointerAxisDiscrete(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis: wayland.PointerAxis,
        discrete: i32,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }

    fn pointerAxisValue120(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis: wayland.PointerAxis,
        value120: i32,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = value120;
    }

    fn pointerAxisRelativeDirection(
        data: ?*anyopaque,
        pointer: *wayland.Pointer,
        axis: wayland.PointerAxis,
        direction: wayland.PointerAxisRelativeDirection,
    ) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = direction;
    }

    // =========================================================================
    // 触摸回调
    // =========================================================================

    fn touchDown(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        serial: u32,
        time: u32,
        surface: *wayland.Surface,
        id: i32,
        x: wayland.Fixed,
        y: wayland.Fixed,
    ) callconv(.c) void {
        _ = touch;
        _ = serial;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));
        const px = wayland.fixedToDouble(x);
        const py = wayland.fixedToDouble(y);
        std.debug.print("touch: down id={d} pos=({d:.1},{d:.1})\n", .{ id, px, py });

        // 找拥有此 surface 的窗口；找不到就退回 active window。
        var iter = self.window_registry.iterator();
        while (iter.next()) |window_id| {
            const window = self.window_registry.getTyped(LinuxWindow, window_id.*) orelse continue;
            if (window.wl_surface == surface) {
                self.touch_window = window;
                break;
            }
        }
        if (self.touch_window == null) {
            std.debug.print("touch: surface lookup failed, using active_window\n", .{});
            self.touch_window = self.active_window;
        }

        if (self.touch_window) |window| {
            const event = linux_input.touchDownEvent(id, px, py);
            _ = window.handleInput(event);
        } else {
            std.debug.print("touch: no window to dispatch to\n", .{});
        }
    }

    fn touchUp(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        serial: u32,
        time: u32,
        id: i32,
    ) callconv(.c) void {
        _ = touch;
        _ = serial;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));

        if (self.touch_window) |window| {
            // up 事件复用最近一次已知位置——协议在 up 上不重复坐标，
            // 只有 down 和 motion 带。
            const event = linux_input.touchUpEvent(id, 0, 0);
            _ = window.handleInput(event);
        }
    }

    fn touchMotion(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        time: u32,
        id: i32,
        x: wayland.Fixed,
        y: wayland.Fixed,
    ) callconv(.c) void {
        _ = touch;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));

        if (self.touch_window) |window| {
            const event = linux_input.touchMovedEvent(id, wayland.fixedToDouble(x), wayland.fixedToDouble(y));
            _ = window.handleInput(event);
        }
    }

    fn touchFrame(
        data: ?*anyopaque,
        touch: *wayland.Touch,
    ) callconv(.c) void {
        _ = data;
        _ = touch;
        // frame 标记同一逻辑时刻的一批触摸事件结束。无需动作——
        // 事件都是即时派发的。
    }

    fn touchCancel(
        data: ?*anyopaque,
        touch: *wayland.Touch,
    ) callconv(.c) void {
        _ = touch;
        const self: *Self = @ptrCast(@alignCast(data));

        if (self.touch_window) |window| {
            _ = window.handleInput(linux_input.touchCancelledEvent());
        }
        self.touch_window = null;
    }

    fn touchShape(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        id: i32,
        major: wayland.Fixed,
        minor: wayland.Fixed,
    ) callconv(.c) void {
        _ = data;
        _ = touch;
        _ = id;
        _ = major;
        _ = minor;
        // 接触形状（椭圆）尚未进入事件模型。
    }

    fn touchOrientation(
        data: ?*anyopaque,
        touch: *wayland.Touch,
        id: i32,
        orientation: wayland.Fixed,
    ) callconv(.c) void {
        _ = data;
        _ = touch;
        _ = id;
        _ = orientation;
        // 接触方向（角度）尚未进入事件模型。
    }

    fn keyboardEnter(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: u32,
        surface: *wayland.Surface,
        keys: *anyopaque,
    ) callconv(.c) void {
        _ = keyboard;
        _ = surface;
        _ = keys;
        const self: *Self = @ptrCast(@alignCast(data));

        // 重新拿到键盘焦点，重置按键重复追踪
        if (self.active_window) |window| {
            window.key_repeat_tracker.reset();
        }

        // 键盘焦点进入时为 IME 开启文本输入
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Enable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    fn keyboardLeave(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: u32,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = keyboard;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data));

        // 失焦时重置按键重复与连击追踪
        if (self.active_window) |window| {
            window.key_repeat_tracker.reset();
            window.click_tracker.reset();
        }

        // 键盘焦点离开时关闭文本输入
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Disable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    fn keyboardKeymap(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: wayland.KeyboardKeymapFormat,
        fd: i32,
        _: u32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
        // 关掉 fd——还没接 xkbcommon。
        // 完整实现应该 mmap 这块再解析 keymap。
        // std.posix.close 在 Zig 0.16 已移除（见 release notes 的
        // "posix and os.windows removals"）；Linux 上链接了 libc，
        // 直接调 libc 符号。
        _ = std.c.close(fd);
        // keymap 已收到——完整实现应用 xkbcommon 解析
    }

    fn keyboardRepeatInfo(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        _: i32,
        _: i32,
    ) callconv(.c) void {
        _ = data;
        _ = keyboard;
        // 收到 repeat 信息——将来可拿来做按键重复处理
    }

    fn keyboardKey(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        serial: u32,
        time: u32,
        key: u32,
        state: wayland.KeyState,
    ) callconv(.c) void {
        _ = keyboard;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data));
        self.last_key_serial = serial;

        const modifiers = linux_input.modifiersFromFlags(
            self.modifier_shift,
            self.modifier_ctrl,
            self.modifier_alt,
            self.modifier_super,
        );

        if (state == .pressed) {
            // 是否为 repeat
            var is_repeat = false;
            if (self.active_window) |window| {
                is_repeat = window.key_repeat_tracker.checkAndPress(key);
            }

            // 派发 key_down 给 active window
            if (self.active_window) |window| {
                const event = linux_input.keyDownEvent(key, modifiers, is_repeat);
                const handled = window.handleInput(event);

                // 应用没处理才走内置快捷键。
                // 两 个快捷键都是关闭焦点窗口，而不是清 `running`，与
                // `Window.close` 处理 `xdg_toplevel.close` 的口径一致。
                // 在这里停循环等于复活"单窗口"假设，还会绕过应用的关闭否决。
                if (!handled) {
                    // Alt+F4 关闭
                    if (key == linux_input.evdev.KEY_F4 and self.modifier_alt) {
                        std.debug.print("Alt+F4 pressed - closing window\n", .{});
                        window.close();
                        return;
                    }

                    // Ctrl+Q 关闭
                    if (key == linux_input.evdev.KEY_Q and self.modifier_ctrl) {
                        std.debug.print("Ctrl+Q pressed - closing window\n", .{});
                        window.close();
                        return;
                    }
                }

                // 可打印字符生成 text_input 事件。
                // 按住 Ctrl 或 Alt/Super 时跳过（那是快捷键，不是文本输入）。
                if (!self.modifier_ctrl and !self.modifier_alt and !self.modifier_super) {
                    if (linux_input.evdevKeyToChar(key, self.modifier_shift)) |char| {
                        // 在栈上造单字符字符串
                        var char_buf: [1]u8 = .{char};
                        const text_event = linux_input.textInputEvent(&char_buf);
                        _ = window.handleInput(text_event);
                    }
                }
            }
        } else {
            // 键释放
            if (self.active_window) |window| {
                window.key_repeat_tracker.release(key);

                const event = linux_input.keyUpEvent(key, modifiers);
                _ = window.handleInput(event);
            }
        }
    }

    fn keyboardModifiers(
        data: ?*anyopaque,
        keyboard: *wayland.Keyboard,
        serial: u32,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) callconv(.c) void {
        _ = keyboard;
        _ = serial;
        _ = mods_latched;
        _ = mods_locked;
        _ = group;
        const self: *Self = @ptrCast(@alignCast(data));

        // 用 XKB 位掩码更新修饰键状态
        self.modifier_shift = (mods_depressed & linux_input.xkb_mod.SHIFT) != 0;
        self.modifier_ctrl = (mods_depressed & linux_input.xkb_mod.CTRL) != 0;
        self.modifier_alt = (mods_depressed & linux_input.xkb_mod.ALT) != 0;
        self.modifier_super = (mods_depressed & linux_input.xkb_mod.SUPER) != 0;

        // 派发 modifiers_changed 给 active window
        if (self.active_window) |window| {
            const modifiers = linux_input.modifiersFromFlags(
                self.modifier_shift,
                self.modifier_ctrl,
                self.modifier_alt,
                self.modifier_super,
            );
            const event = linux_input.modifiersChangedEvent(modifiers);
            _ = window.handleInput(event);
        }
    }

    // =========================================================================
    // 文件拖放回调（wl_data_device,接收端）
    // =========================================================================
    //
    // 顺序假设:合成器按 `data_offer → offer(mime)* → enter → motion* →
    // (leave | drop)` 在同一批次送达,所以 `beginDrag` 时 mime 已可知;
    // 进入/移动/放下都以 `offer_has_uri_list` 门槛(与 Windows 后端
    // `offersFileDrop` 的 CF_HDROP 前置检查同一语义)。
    // selection 槽必须挂 no-op(不只是理论上):这台 UI 上任何一次别的
    // 应用改剪贴板都会送 selection 事件,空槽在 wl 静态派发表里就是
    // NUll 调用。

    const dnd_device_listener = dnd.WlDataDeviceListener{
        .data_offer = dndDataOffer,
        .enter = dndEnter,
        .leave = dndLeave,
        .motion = dndMotion,
        .drop = dndDrop,
        .selection = dndSelectionIgnored,
    };

    fn dndDataOffer(data: ?*anyopaque, _: *dnd.WlDataDevice, offer: *dnd.WlDataOffer) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        self.dnd_state.trackOffer(offer);
    }

    fn dndSelectionIgnored(data: ?*anyopaque, _: *dnd.WlDataDevice, _: ?*dnd.WlDataOffer) callconv(.c) void {
        _ = @as(*Self, @ptrCast(@alignCast(data)));
        // 剪贴板能力已删,选区变化与我们无关,但事件槽不能空。
    }

    fn dndEnter(
        data: ?*anyopaque,
        _: *dnd.WlDataDevice,
        serial: u32,
        surface: ?*wayland.Surface,
        x: i32,
        y: i32,
        offer: ?*dnd.WlDataOffer,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        const offer_ptr = offer orelse return;
        self.dnd_state.beginDrag(offer_ptr, serial, x, y);
        self.dnd_x = @floatFromInt(x);
        self.dnd_y = @floatFromInt(y);

        // 窗口定位:surface 精确匹配,拿不到就回退 active_window(与
        // touch 回调同一兜底)。
        const window = self.dndWindowForSurf(surface) orelse self.active_window;
        self.dnd_target_window = window;
        if (window) |w| {
            if (!w.file_drop_enabled) {
                // 拒绝:覆盖 beginDrag 里的 accept/set_actions,合成器
                // 显示“不可放下”光标,不派发事件。
                self.dnd_state.refuseDrag(offer_ptr, serial);
            } else if (self.dnd_state.offer_has_uri_list) {
                _ = w.handleInput(.{ .file_drop = .{
                    .phase = .entered,
                    .paths = &.{},
                    .position = .{ .x = self.dnd_x, .y = self.dnd_y },
                    .modifiers = self.dndModifiers(),
                } });
            }
        }
    }

    fn dndLeave(data: ?*anyopaque, _: *dnd.WlDataDevice) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        if (self.dnd_state.dnd_offer != null and self.dnd_state.offer_has_uri_list) {
            if (self.dnd_target_window) |window| {
                _ = window.handleInput(.{ .file_drop = .{
                    .phase = .exited,
                    .paths = &.{},
                    .position = .{ .x = self.dnd_x, .y = self.dnd_y },
                    .modifiers = self.dndModifiers(),
                } });
            }
        }
        self.dnd_state.endDrag();
        self.dnd_target_window = null;
    }

    fn dndMotion(
        data: ?*anyopaque,
        _: *dnd.WlDataDevice,
        _: u32,
        x: i32,
        y: i32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        self.dnd_x = @floatFromInt(x);
        self.dnd_y = @floatFromInt(y);
        if (self.dnd_state.dnd_offer != null and self.dnd_state.offer_has_uri_list) {
            if (self.dnd_target_window) |window| {
                if (window.file_drop_enabled) {
                    _ = window.handleInput(.{ .file_drop = .{
                        .phase = .moved,
                        .paths = &.{},
                        .position = .{ .x = self.dnd_x, .y = self.dnd_y },
                        .modifiers = self.dndModifiers(),
                    } });
                }
            }
        }
    }

    fn dndDrop(data: ?*anyopaque, _: *dnd.WlDataDevice) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        const window = self.dnd_target_window orelse {
            self.dnd_state.endDrag();
            return;
        };
        const accept_drop = window.file_drop_enabled;
        if (!accept_drop or self.dnd_state.dnd_offer == null or !self.dnd_state.offer_has_uri_list) {
            self.dnd_state.endDrag();
            self.dnd_target_window = null;
            return;
        }

        // receive 是异步的:同步读到 EOF(GLFW 同款取舍,见 dnd.zig)。
        const uri_bytes = self.dnd_state.receiveUriList(self.allocator) orelse {
            self.dnd_state.endDrag();
            self.dnd_target_window = null;
            return;
        };
        defer self.allocator.free(uri_bytes);

        dnd.parseUriList(uri_bytes, &self.dnd_state.parsed);
        if (self.dnd_state.parsed.count > 0) {
            // 切片数组放本帧:handleInput → 用户回调同步执行,回调返回前
            // 本帧存活(与 Windows 后端 `drop_target` 同一契约)。
            var slices: [dnd.ParsedPaths.max_paths][]const u8 = undefined;
            const paths = self.dnd_state.parsed.buildSlices(&slices);
            _ = window.handleInput(.{ .file_drop = .{
                .phase = .dropped,
                .paths = paths,
                .position = .{ .x = self.dnd_x, .y = self.dnd_y },
                .modifiers = self.dndModifiers(),
            } });
        }

        // 事务收尾:finish 通知 source(move 语义需要),再销毁 offer。
        if (self.dnd_state.dnd_offer) |offer| dnd.dataOfferFinish(offer);
        self.dnd_state.endDrag();
        self.dnd_target_window = null;
    }

    fn dndWindowForSurf(self: *Self, surface: ?*wayland.Surface) ?*LinuxWindow {
        const s = surface orelse return null;
        var iter = self.window_registry.iterator();
        while (iter.next()) |window_id| {
            const window = self.window_registry.getTyped(LinuxWindow, window_id.*) orelse continue;
            if (window.wl_surface == s) return window;
        }
        return null;
    }

    fn dndModifiers(self: *Self) input.Modifiers {
        return linux_input.modifiersFromFlags(
            self.modifier_shift,
            self.modifier_ctrl,
            self.modifier_alt,
            self.modifier_super,
        );
    }

    // =========================================================================
    // Text Input V3 回调（IME 支持）
    // =========================================================================

    fn textInputEnter(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = text_input;
        _ = surface;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // 该 surface 的文本输入现已激活
        if (self.active_window) |window| {
            window.ime_active = true;
        }
    }

    fn textInputLeave(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        surface: *wayland.Surface,
    ) callconv(.c) void {
        _ = text_input;
        _ = surface;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // 文本输入停用
        if (self.active_window) |window| {
            window.ime_active = false;
            window.clearMarkedText();
        }
    }

    fn textInputPreeditString(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        text: ?[*:0]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        _ = cursor_begin;
        _ = cursor_end;

        // 存预编辑文本——done 事件时统一应用
        if (text) |t| {
            self.ime_preedit_text = std.mem.span(t);
        } else {
            self.ime_preedit_text = null;
        }
    }

    fn textInputCommitString(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        text: ?[*:0]const u8,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // 存上屏文本——done 事件时统一应用
        if (text) |t| {
            self.ime_commit_text = std.mem.span(t);
        } else {
            self.ime_commit_text = null;
        }
    }

    fn textInputDeleteSurroundingText(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        before_length: u32,
        after_length: u32,
    ) callconv(.c) void {
        _ = text_input;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        // 存删除信息——done 事件时统一应用
        self.ime_delete_before = before_length;
        self.ime_delete_after = after_length;
    }

    fn textInputDone(
        data: ?*anyopaque,
        text_input: *wayland.ZwpTextInputV3,
        serial: u32,
    ) callconv(.c) void {
        _ = text_input;
        _ = serial;

        const self: *Self = @ptrCast(@alignCast(data orelse return));

        const window = self.active_window orelse return;

        // 应用累积的 IME 状态
        // 先处理 delete_surrounding_text
        if (self.ime_delete_before > 0 or self.ime_delete_after > 0) {
            // TODO: surrounding text 删除尚未实现，现在只记账
            self.ime_delete_before = 0;
            self.ime_delete_after = 0;
        }

        // 处理上屏文本（最终文本）
        if (self.ime_commit_text) |commit_text| {
            window.setInsertedText(commit_text);
            window.clearMarkedText();
            const event = linux_input.textInputEvent(window.inserted_text);
            _ = window.handleInput(event);
            self.ime_commit_text = null;
        }

        // 处理预编辑文本（composing 中）
        if (self.ime_preedit_text) |preedit_text| {
            window.setMarkedText(preedit_text);
            const event = linux_input.compositionEvent(window.marked_text);
            _ = window.handleInput(event);
            self.ime_preedit_text = null;
        } else if (self.ime_commit_text == null) {
            // 空预编辑且无上屏：组合被取消
            if (window.hasMarkedText()) {
                window.clearMarkedText();
                const event = linux_input.compositionEvent("");
                _ = window.handleInput(event);
            }
        }
    }

    // =========================================================================
    // IME 公开控制函数
    // =========================================================================

    /// 为 active window 开启文本输入
    pub fn enableTextInput(self: *Self) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Enable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    /// 关闭文本输入
    pub fn disableTextInput(self: *Self) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3Disable(ti);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    /// 设置 IME 候选窗定位用的光标矩形
    pub fn setImeCursorRect(self: *Self, x: i32, y: i32, width: i32, height: i32) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3SetCursorRectangle(ti, x, y, width, height);
            wayland.zwpTextInputV3Commit(ti);
        }
    }

    /// 设置 IME 内容类型提示
    pub fn setContentType(self: *Self, hint: wayland.ZwpTextInputV3ContentHint, purpose: wayland.ZwpTextInputV3ContentPurpose) void {
        if (self.text_input) |ti| {
            wayland.zwpTextInputV3SetContentType(ti, hint, purpose);
            wayland.zwpTextInputV3Commit(ti);
        }
    }
};

// 处于 `initInPlace` 离开状态的平台，只是没有连接。
//
// `initInPlace` 自身要求 compositor，所以无 compositor 可达的两条状态
// 迁移直接由它起始的字段默认值驱动。第三条——`run` 入口把 `running`
// 置 true——headless 下根本到不了：没 socket `run` 在 display 守卫就
// 返回，有 socket 则阻塞在 `poll`。它由与置位配对的 `defer`（任何退出
// 路径都逃不掉清零）和 `deinit` 的 `assert(!self.running)`（泄漏会在
// 下一次拆除炸出来）一起把守。
fn disconnectedPlatform() LinuxPlatform {
    return .{
        .window_registry = WindowRegistry.init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
}

test "isRunning is false before run and stays false across quit" {
    var plat = disconnectedPlatform();
    defer plat.window_registry.deinit();

    try std.testing.expect(!plat.isRunning());

    // `run` 之前调 `quit` 是合法的，不能凭空捏造一个循环去停。
    plat.quit();
    try std.testing.expect(!plat.isRunning());
}

// 这个改动修的 bug：一个 `running` 标志同时回答"阻塞循环还活着"和
// "socket 可用"，于是用 `dispatch` 自管循环的调用方每次调用都被拒绝。
// 把从前不可表达的状态——已连接但未在跑——钉下来，因为那正是这类
// 循环每一迭代的样子。
test "connection liveness is independent of loop state" {
    var plat = disconnectedPlatform();
    defer plat.window_registry.deinit();

    try std.testing.expect(!plat.isConnected());
    // 未连接：派发原语直接拒绝，不碰 socket。
    try std.testing.expect(!plat.poll());
    try std.testing.expect(!plat.dispatch());
    try std.testing.expect(!plat.dispatchWithTimeout(0));

    // 代指一条活连接。绝不解引用：两个谓词只读标志，
    // 此状态下也不会调那些原语。
    plat.display = @ptrFromInt(@alignOf(usize));
    plat.connection_alive = true;

    try std.testing.expect(plat.isConnected());
    try std.testing.expect(!plat.isRunning());
}

test "event loop waits instead of spinning for compositor frame" {
    try std.testing.expectEqual(@as(i32, HIDDEN_FRAME_POLL_MS), eventLoopPollTimeout(true, true, 240_000));
    try std.testing.expectEqual(@as(i32, 0), eventLoopPollTimeout(true, false, 240_000));
    try std.testing.expectEqual(@as(i32, 4), eventLoopPollTimeout(false, false, 240_000));
}

// 无活要干、无回调在途的窗口，开或关都行。
fn idleWindowLoopState(open: bool) WindowLoopState {
    return .{ .open = open, .has_queued_work = false, .waiting_for_frame = false };
}

// 循环必须扛得住"非最后一个窗口被关掉"，这正是修这个问题的全部意义：
// `run()` 测的是 `open_count`，所以直接用以前会把整个进程杀死的
// 双窗口情形来驱动它。
test "loop state counts open windows, not registry entries" {
    const open = idleWindowLoopState(true);
    const closed = idleWindowLoopState(false);

    try std.testing.expectEqual(@as(u32, 2), foldLoopState(&.{ open, open }).open_count);

    // 两个窗口关了一个：仍在注册，但循环继续跑。
    try std.testing.expectEqual(@as(u32, 1), foldLoopState(&.{ open, closed }).open_count);

    // 都关了且都还没被认领：循环必须仍可退出，否则一个关闭未认领的
    // 窗口会让它永远活着。
    try std.testing.expectEqual(@as(u32, 0), foldLoopState(&.{ closed, closed }).open_count);
    try std.testing.expectEqual(@as(u32, 0), foldLoopState(&.{}).open_count);
}

// 已关闭的窗口对节流不可见。它的 `needs_redraw` 和待决 `wl_callback`
// 都是归属方还没认领的陈旧状态，随便是哪一个都会让循环 0ms 空转，
// 或以兜底节奏替一个再也画不出来的窗口维持心跳。
test "loop state ignores closed windows when pacing" {
    const closed_busy = WindowLoopState{
        .open = false,
        .has_queued_work = true,
        .waiting_for_frame = true,
    };
    const open_idle = WindowLoopState{
        .open = true,
        .has_queued_work = false,
        .waiting_for_frame = false,
    };

    const state = foldLoopState(&.{ closed_busy, open_idle });
    try std.testing.expectEqual(@as(u32, 1), state.open_count);
    try std.testing.expect(!state.has_pending_work);
    try std.testing.expect(!state.all_waiting_for_frame);
}

// 节流状态是各打开窗口的 AND：一个兄弟闲等 compositor 回调，不能把
// 超时推到 20Hz 兜底而另一个窗口还有活要干。单窗口的两行把退化行为
// 钉在原有结果上。
test "loop state pacing across sibling windows" {
    const waiting = WindowLoopState{
        .open = true,
        .has_queued_work = true,
        .waiting_for_frame = true,
    };
    const ready = WindowLoopState{
        .open = true,
        .has_queued_work = true,
        .waiting_for_frame = false,
    };

    // 单窗口、在等回调：与原有单窗口行为一致。
    const one_waiting = foldLoopState(&.{waiting});
    try std.testing.expect(one_waiting.all_waiting_for_frame);
    try std.testing.expectEqual(@as(i32, HIDDEN_FRAME_POLL_MS), eventLoopPollTimeout(
        one_waiting.has_pending_work,
        one_waiting.all_waiting_for_frame,
        240_000,
    ));

    // 两个窗口、一个还需要服务：不退回兜底等待。
    const mixed = foldLoopState(&.{ waiting, ready });
    try std.testing.expect(mixed.has_pending_work);
    try std.testing.expect(!mixed.all_waiting_for_frame);
    try std.testing.expectEqual(@as(i32, 0), eventLoopPollTimeout(
        mixed.has_pending_work,
        mixed.all_waiting_for_frame,
        240_000,
    ));

    // 所有打开窗口都被 compositor 节流：退回定时等待。
    const all_waiting = foldLoopState(&.{ waiting, waiting });
    try std.testing.expect(all_waiting.all_waiting_for_frame);
    try std.testing.expectEqual(@as(i32, HIDDEN_FRAME_POLL_MS), eventLoopPollTimeout(
        all_waiting.has_pending_work,
        all_waiting.all_waiting_for_frame,
        240_000,
    ));
}

// 容量边界：fold 必须能恰好吞下满载 registry，因为 `collectLoopState`
// 的栈采样缓冲就是按 `MAX_WINDOWS` 定尺寸的，registry 也不会超出它。
test "loop state folds a full registry" {
    var samples: [WindowRegistry.MAX_WINDOWS]WindowLoopState = undefined;
    for (&samples) |*sample| {
        sample.* = .{ .open = true, .has_queued_work = false, .waiting_for_frame = true };
    }

    const full = foldLoopState(&samples);
    try std.testing.expectEqual(WindowRegistry.MAX_WINDOWS, full.open_count);
    try std.testing.expect(full.all_waiting_for_frame);

    // 最后一个打开窗口之后：关掉最后一条记录只减计数，不动其他。
    samples[WindowRegistry.MAX_WINDOWS - 1].open = false;
    const one_closed = foldLoopState(&samples);
    try std.testing.expectEqual(WindowRegistry.MAX_WINDOWS - 1, one_closed.open_count);
}
