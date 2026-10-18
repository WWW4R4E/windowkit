//! LinuxWindow —— Linux/Wayland 窗口实现。
//!
//! 基于 Wayland 的 XDG shell 协议创建并管理窗口。
//! 渲染由依赖方持有：本文件只负责窗口生命周期、输入、IME 与 vsync 节拍，
//! 每帧通过 `on_render` 回调把绘制交给调用方（句柄见 `nativeHandles()`）。

const std = @import("std");
const wayland = @import("wayland.zig");
const LinuxPlatform = @import("platform.zig").LinuxPlatform;
const interface_mod = @import("../interface.zig");
const WindowId = interface_mod.WindowId;
const geometry = @import("../../geometry.zig");
const Size = geometry.Size(f64);
const input = @import("../../input/events.zig");
const linux_input = @import("input.zig");
const native_handles = @import("../native_handles.zig");

const NativeHandles = native_handles.NativeHandles;
const FramebufferSize = native_handles.FramebufferSize;

const Allocator = std.mem.Allocator;
const WindowOptions = interface_mod.WindowOptions;

// 静态 listener：必须在 Wayland 对象的整个生命周期内持续存活
const surface_listener = wayland.SurfaceListener{
    .enter = Window.surfaceEnter,
    .leave = Window.surfaceLeave,
    .preferred_buffer_scale = Window.surfacePreferredScale,
    .preferred_buffer_transform = Window.surfacePreferredTransform,
};

const decoration_listener = wayland.ZxdgToplevelDecorationV1Listener{
    .configure = Window.decorationConfigure,
};

const xdg_surface_listener = wayland.XdgSurfaceListener{
    .configure = Window.xdgSurfaceConfigure,
};

const toplevel_listener = wayland.XdgToplevelListener{
    .configure = Window.xdgToplevelConfigure,
    .close = Window.xdgToplevelClose,
    .configure_bounds = Window.xdgToplevelConfigureBounds,
    .wm_capabilities = Window.xdgToplevelWmCapabilities,
};

// 帧回调 listener：必须静态，才能跨 scheduleFrame() 调用存活
const frame_callback_listener = wayland.CallbackListener{
    .done = Window.frameCallback,
};

pub const Window = struct {
    allocator: Allocator,
    platform: *LinuxPlatform,

    // Wayland 对象
    wl_surface: ?*wayland.Surface = null,
    xdg_surface: ?*wayland.XdgSurface = null,
    xdg_toplevel: ?*wayland.XdgToplevel = null,
    decoration: ?*wayland.ZxdgToplevelDecorationV1 = null,
    frame_callback: ?*wayland.Callback = null,
    viewport: ?*wayland.WpViewport = null,

    // 窗口状态。
    //
    // 带 `_px` 后缀是因为 `width`/`height` 已被契约的访问器方法占用，而 Zig
    // 把字段和声明放进同一个结构体命名空间。两者都是*逻辑*像素；乘
    // `scale_factor` 得到物理交换链尺寸。
    width_px: u32 = 800,
    height_px: u32 = 600,
    /// 逻辑像素尺寸（与其他平台 API 保持一致）
    size: Size = .{ .width = 800, .height = 600 },
    scale_factor: f64 = 1.0,
    configured: bool = false,
    closed: bool = false,

    /// 拖放开关(初始值来自 `options.file_drop`;false 时平台侧对
    /// `wl_data_offer.accept` 发 null mime + 无动作,合成器显示“不可放下”)。
    file_drop_enabled: bool = true,

    /// 本窗口在 WindowRegistry 中的唯一标识。
    /// 创建后由 WindowRegistry.register() 填写。
    window_id: WindowId = .invalid,

    pending_resize: bool = false,
    pending_width: u32 = 0,
    pending_height: u32 = 0,

    // 输入状态
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_inside: bool = false,

    // 装饰状态
    has_server_decorations: bool = false,

    // 窗口自身没有渲染器：帧节拍只负责派发 `on_render`，绘制与呈现由
    // 依赖方凭 `nativeHandles()` 自行完成。
    background_color: geometry.Color = geometry.Color.rgba(0.2, 0.2, 0.25, 1.0),

    /// 应用层请求的半透明玻璃样式。
    ///
    /// 只记录、渲染时不用：Wayland 没有可移植的窗口模糊协议，所以
    /// `LinuxPlatform.capabilities.glass_effects` 才是 false。仅
    /// `getClearColor` 会看它——好让确实会合成 surface 背后内容的
    /// compositor 有东西能透出来。
    glass_style: interface_mod.GlassStyle = .none,

    /// 最近一次 `setAppearance` 请求的外观。仅作参考，见该函数说明。
    dark_appearance: bool = false,

    needs_redraw: bool = true,
    /// 已向 `on_render` 派发过首帧。`renderOpenWindows` 靠它完成 bootstrap：
    /// 无 buffer surface 收不到首个 frame callback，要用一次急切渲染开链。
    has_presented_frame: bool = false,

    /// 立即模式 UI 需要：以 vsync 频率连续排帧。隐藏窗口拿不到 compositor
    /// 帧回调时，由平台事件循环自行节流。
    continuous_render: bool = true,

    // 标题存储。`xdg_toplevel.set_title` 收 C 字符串，所以缓冲区是
    // `title_bytes_max` 载荷字节加一个 NUL 终止符。
    title_buf: [title_bytes_max + 1]u8 = undefined,
    title_len: usize = 0,

    // =========================================================================
    // IME (Input Method Editor) State
    // =========================================================================

    /// IME 的预编辑（composing）文本
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,

    /// IME 上屏（committed）文本
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,

    /// IME 当前是否对该窗口激活
    ime_active: bool = false,

    /// 窗口坐标下的 IME 光标矩形（候选窗定位用）
    ime_cursor_rect: geometry.RectF = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 20 } },

    // =========================================================================
    // 输入状态与回调
    // =========================================================================

    /// 连击（双击/三击）检测追踪器
    click_tracker: linux_input.ClickTracker = .{},

    /// 按键重复触发追踪器
    key_repeat_tracker: linux_input.KeyRepeatTracker = .{},

    /// 当前按下的鼠标键（拖动检测用）
    pressed_button: ?input.MouseButton = null,

    /// 输入事件回调。返回 true 表示已处理。
    on_input: ?InputCallback = null,

    /// 需要绘制的帧都会调用一次。
    on_render: ?RenderCallback = null,

    /// 窗口即将关闭时调用。返回 false 可阻止关闭。
    on_close: ?CloseCallback = null,

    /// 窗口尺寸变化时调用。
    on_resize: ?ResizeCallback = null,

    /// 输入处理完成后调用。
    /// 适合做可能进入嵌套事件循环的操作（如模态对话框）。
    on_post_input: ?PostInputCallback = null,

    /// 回调用用户数据指针
    user_data: ?*anyopaque = null,

    /// 输入回调类型：返回 true 表示事件已处理
    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;

    /// 渲染回调类型：每帧调用一次，绘制本身归依赖方
    pub const RenderCallback = *const fn (*Self) void;

    /// 关闭回调：窗口即将关闭时调用，返回 false 可阻止关闭。
    pub const CloseCallback = *const fn (*Self) bool;

    /// 缩放回调：窗口尺寸变化时调用
    pub const ResizeCallback = *const fn (*Self, f64, f64) void;

    /// 输入后回调：输入处理完成后调用。
    /// 适合做嵌套事件循环的操作（模态对话框等）。
    pub const PostInputCallback = *const fn (*Self) void;

    const Self = @This();

    /// `setTitle` 接受的最长标题字节数。
    ///
    /// 原因：标题内联存储（初始化后不再另行分配），且要以 C 字符串交给
    /// compositor，所以缓冲区比它多一个字节放终止符。
    pub const title_bytes_max: usize = 255;

    pub fn init(allocator: Allocator, plat: *LinuxPlatform, options: *const WindowOptions) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // 缩放系数初值取自平台（之后还可能被 surface 事件更新）
        const initial_scale = plat.getScaleFactor();

        self.* = Self{
            .allocator = allocator,
            .platform = plat,
            .width_px = @intFromFloat(options.width),
            .height_px = @intFromFloat(options.height),
            .size = .{ .width = options.width, .height = options.height },
            .scale_factor = initial_scale,
            .background_color = options.background_color,
            .glass_style = options.glass_style,
            .file_drop_enabled = options.file_drop,
        };

        // 存标题。契约与 `setTitle` 相同：超长是程序员错误，assert 之外
        // 的截断是为了让 release 构建也不越界。
        std.debug.assert(options.title.len <= title_bytes_max);
        const title_len = @min(options.title.len, title_bytes_max);
        @memcpy(self.title_buf[0..title_len], options.title[0..title_len]);
        self.title_buf[title_len] = 0;
        self.title_len = title_len;

        // 在创建任何 Wayland 对象之前就注册，之后每条错误路径都经由
        // 同一个 errdefer 回滚，而不是另开一个退出口径。
        self.window_id = try plat.registerWindow(self);
        errdefer {
            plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }

        // 创建 Wayland surface
        const compositor = plat.getCompositor() orelse return error.NoCompositor;
        self.wl_surface = wayland.compositorCreateSurface(compositor) orelse return error.FailedToCreateSurface;
        errdefer {
            if (self.wl_surface) |s| wayland.surfaceDestroy(s);
            self.wl_surface = null;
        }

        // 挂 surface listener（用模块级静态 listener）
        _ = wayland.surfaceAddListener(self.wl_surface.?, &surface_listener, self);

        // 创建 XDG surface
        const xdg_wm_base = plat.getXdgWmBase() orelse return error.NoXdgWmBase;
        self.xdg_surface = wayland.xdgWmBaseGetXdgSurface(xdg_wm_base, self.wl_surface.?) orelse return error.FailedToCreateXdgSurface;
        errdefer {
            if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
            self.xdg_surface = null;
        }

        // 挂 XDG surface listener（用模块级静态 listener）
        _ = wayland.xdgSurfaceAddListener(self.xdg_surface.?, &xdg_surface_listener, self);

        // 创建 XDG toplevel
        self.xdg_toplevel = wayland.xdgSurfaceGetToplevel(self.xdg_surface.?) orelse return error.FailedToCreateToplevel;
        errdefer {
            if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
            self.xdg_toplevel = null;
        }

        // 挂 toplevel listener（用模块级静态 listener）
        _ = wayland.xdgToplevelAddListener(self.xdg_toplevel.?, &toplevel_listener, self);

        // 设置窗口属性
        wayland.xdgToplevelSetTitle(self.xdg_toplevel.?, @ptrCast(&self.title_buf));
        wayland.xdgToplevelSetAppId(self.xdg_toplevel.?, "windowkit");

        // 大小约束
        if (options.min_size) |min| {
            wayland.xdgToplevelSetMinSize(
                self.xdg_toplevel.?,
                @intFromFloat(min.width),
                @intFromFloat(min.height),
            );
        }
        if (options.max_size) |max| {
            wayland.xdgToplevelSetMaxSize(
                self.xdg_toplevel.?,
                @intFromFloat(max.width),
                @intFromFloat(max.height),
            );
        }

        // 有服务端装饰协议就优先请求
        if (plat.getDecorationManager()) |dm| {
            std.debug.print("Decoration manager available, requesting server-side decorations...\n", .{});
            self.decoration = wayland.zxdgDecorationManagerV1GetToplevelDecoration(dm, self.xdg_toplevel.?);
            if (self.decoration) |dec| {
                // 挂 listener 接收装饰模式应答
                _ = wayland.zxdgToplevelDecorationV1AddListener(dec, &decoration_listener, self);
                wayland.zxdgToplevelDecorationV1SetMode(dec, .server_side);
            }
        } else {
            std.debug.print("WARNING: No decoration manager available - window will have no title bar!\n", .{});
            std.debug.print("Your compositor may not support xdg-decoration-unstable-v1 protocol.\n", .{});
        }

        // commit surface，触发 configure 事件
        wayland.surfaceCommit(self.wl_surface.?);

        // 等首次 configure 完成——期间 preferred_buffer_scale 回调可能更新 scale_factor
        _ = wayland.wl_display_roundtrip(plat.display.?);

        // 上方创建的 decoration 的 errdefer（可能为 null）
        errdefer {
            if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
            self.decoration = null;
        }

        // HiDPI 缩放使用 viewport（GPU 后端的首选方案，优于 set_buffer_scale：
        // 按物理分辨率渲染、按逻辑尺寸显示）
        if (plat.getViewporter()) |viewporter| {
            self.viewport = wayland.viewporterGetViewport(viewporter, self.wl_surface.?);
            if (self.viewport) |vp| {
                // destination 设为逻辑尺寸，compositor 负责把 buffer 缩放过去
                wayland.viewportSetDestination(
                    vp,
                    @intCast(self.width_px),
                    @intCast(self.height_px),
                );
            }
        } else {
            // 退路：走 buffer scale（set_buffer_scale 在部分 compositor 上
            // 缩放逻辑有误，viewport 则完全绕开）
            const scale_int: i32 = @intFromFloat(self.scale_factor);
            wayland.surfaceSetBufferScale(self.wl_surface.?, scale_int);
        }

        // 上方创建的 viewport 的 errdefer（可能为 null）
        errdefer {
            if (self.viewport) |vp| wayland.viewportDestroy(vp);
            self.viewport = null;
        }

        // 窗口几何设为逻辑尺寸（用户看到的）
        wayland.xdgSurfaceSetWindowGeometry(
            self.xdg_surface.?,
            0,
            0,
            @intCast(self.width_px),
            @intCast(self.height_px),
        );

        // 提交窗口几何与 viewport 状态并 roundtrip：viewport 生效前，指针
        // 坐标映射不到（正确的）逻辑坐标空间，HiDPI 依赖这一步完成。
        wayland.surfaceCommit(self.wl_surface.?);
        _ = wayland.wl_display_roundtrip(plat.display.?);

        // 新映射的窗口接管焦点。`setActiveWindowId` 还会顺带得到 Wayland
        // 输入分发需要的 `*LinuxWindow`，所以只发 id 就能让两处记录保持一致。
        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(self.wl_surface != null);
        return self;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // 先注销平台持有的引用，再销毁任何 Wayland 对象，避免队列里的
        // 事件被派发进半销毁的窗口。`.invalid` 让第二次 deinit 在这里
        // 变成空操作，而不是撞上 registry 的有效性断言。
        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        if (self.platform.active_window == self) {
            // 要重选而不是清空：`active_window` 是所有 Wayland 指针、键盘和
            // IME 事件的路由目标，其他窗口还开着时置 null 会让输入无家可归。
            // 上面的注销已经把它从候选里移除了。
            self.platform.reelectActiveWindow();
        }
        if (self.platform.touch_window == self) self.platform.touch_window = null;
        std.debug.assert(self.platform.active_window != self);

        // 销毁 viewport
        if (self.viewport) |vp| {
            wayland.viewportDestroy(vp);
            self.viewport = null;
        }

        // 取消未完成的帧回调
        if (self.frame_callback) |cb| {
            wayland.callbackDestroy(cb);
        }

        // 逆序销毁 Wayland 对象
        if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
        if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
        if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
        if (self.wl_surface) |s| wayland.surfaceDestroy(s);

        std.debug.assert(!self.window_id.isValid());
        self.allocator.destroy(self);
    }

    // =========================================================================
    // 公开接口
    // =========================================================================

    /// 窗口宽度（逻辑像素）。
    pub fn width(self: *const Self) u32 {
        return self.width_px;
    }

    /// 窗口高度（逻辑像素）。
    pub fn height(self: *const Self) u32 {
        return self.height_px;
    }

    /// 窗口宽度（逻辑像素，`width` 的便捷别名）
    pub fn widthPx(self: *const Self) u32 {
        return self.width_px;
    }

    /// 窗口高度（逻辑像素，`height` 的便捷别名）
    pub fn heightPx(self: *const Self) u32 {
        return self.height_px;
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return .{
            .width = @floatFromInt(self.width_px),
            .height = @floatFromInt(self.height_px),
        };
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        return self.scale_factor;
    }

    // =========================================================================
    // 原生句柄 / 帧缓冲尺寸（依赖方自持渲染）
    // =========================================================================

    /// 交给依赖方的 Wayland 原生对象：`vkCreateWaylandSurfaceKHR` /
    /// `wgpuInstanceCreateSurface` 等凭它建自己的 surface。
    ///
    /// 只在窗口存活期内有效：`deinit` 之后 surface 已销毁。
    pub fn nativeHandles(self: *const Self) NativeHandles {
        const display = self.platform.getDisplay();
        std.debug.assert(display != null);
        std.debug.assert(self.wl_surface != null);

        return .{ .wayland = .{
            .display = display.?,
            .surface = @ptrCast(self.wl_surface.?),
        } };
    }

    /// 帧缓冲物理像素尺寸（swapchain 只认这个值）。
    ///
    /// 注意字段名 `width_px` 带误导性：Wayland 的 `configure` 给的是**逻辑**
    /// 像素，物理尺寸要乘 `scale_factor` —— 这里就是那一步换算。
    pub fn framebufferSize(self: *const Self) FramebufferSize {
        const scale = self.scale_factor;
        const w: f64 = @floatFromInt(self.width_px);
        const h: f64 = @floatFromInt(self.height_px);

        return .{
            .width_px = @intFromFloat(@round(w * scale)),
            .height_px = @intFromFloat(@round(h * scale)),
        };
    }

       /// 运行时开关文件拖放(初始值来自 `options.file_drop`)。
    pub fn setFileDropEnabled(self: *Self, enabled: bool) void {
        self.file_drop_enabled = enabled;
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        std.debug.assert(title.len <= title_bytes_max);
        std.debug.assert(self.title_buf.len == title_bytes_max + 1);

        const len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buf[0..len], title[0..len]);
        // NUL 终止,除此之外不清零:终止符之后的尾巴永远不会被读，
        // `xdgToplevelSetTitle` 也是遇首个零即停。
        self.title_buf[len] = 0;
        self.title_len = len;

        std.debug.assert(self.title_len <= title_bytes_max);

        if (self.xdg_toplevel) |tl| {
            wayland.xdgToplevelSetTitle(tl, @ptrCast(&self.title_buf));
        }
    }

    // =========================================================================
    // 窗口操作
    // =========================================================================

    /// 请求焦点。
    ///
    /// Wayland 的激活权完全在 compositor：客户端无法自提窗口，请求被拒也
    /// 没有协议错误可报。没有 `xdg-activation-v1` 就没有可发的请求，所以
    /// 这里只排一次重绘，别的什么都不做。
    ///
    /// 调用方（如 `WindowHandle.focus`）随后会自行发布新的 active window id，
    /// 二者各管各的记录，保持一致。`capabilities` 尚无 `can_raise_window`
    /// 之类的位来表达无法提窗这一事实。
    pub fn focus(self: *Self) void {
        std.debug.assert(!self.closed);

        self.requestRender();

        std.debug.assert(self.needs_redraw);
    }

    /// 程序主动关闭窗口。
    ///
    /// 否决回调先跑，可能拒绝关闭。否则窗口记 `closed = true`、停止出帧
    /// 后返回。刻意不在这里做拆除，也不允许它停掉宿主循环。
    ///
    /// 拆除不能在这做：`close()` 会在本窗口自己的输入派发过程中被调到，
    /// 而正在派发的对象活在拆除会释放的 `WindowContext` 里。归属的 `App`
    /// 会从安全点认领窗口（`App.drainClosedWindows` 轮询 `isClosed()`），
    /// 最后一个窗口没了是否退出由 `App.checkQuitCondition` 决定。
    pub fn close(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // 幂等：`App.closeWindowById` 和 compositor 都可能走到这里，
        // 重复触发否决回调会把应用问两遍。
        if (self.closed) return;

        if (self.on_close) |callback| {
            if (!callback(self)) return; // 应用拒绝了关闭。
        }

        self.markClosed();

        std.debug.assert(self.isClosed());
    }

    /// 记下关闭状态并停止出帧。
    ///
    /// 程序式的 `close()` 和 compositor 发起的 `xdg_toplevel.close` 共用
    /// 此路径，标题栏点击和应用调用收敛为同一次状态迁移。
    ///
    /// 未完成的 `wl_callback` 留着不销毁：它的销毁只归 `deinit`；等它触发时
    /// `renderFrame` 会立即返回，而 `continuous_render` 与 `needs_redraw`
    /// 都不会再请求后续帧，回调链自然退役。
    fn markClosed(self: *Self) void {
        std.debug.assert(!self.closed);
        std.debug.assert(self.window_id.isValid());

        self.closed = true;
        self.needs_redraw = false;
        self.continuous_render = false;

        // 已关闭的窗口在归属方认领前保持注册，但不再是合法的输入目标，
        // 所以焦点必须现在移交，而不是等到拆除。`reelectActiveWindow`
        // 会跳过已关闭窗口，不会把它重新选上。
        if (self.platform.active_window == self) self.platform.reelectActiveWindow();

        std.debug.assert(self.closed);
        std.debug.assert(self.platform.active_window != self);
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
    }

    /// 记录请求的亮/暗外观。
    ///
    /// 仅作参考：Wayland 没有服务端外观协议，主题归桌面环境所有，没法
    /// 告诉 compositor。留着这个标志而不是丢弃，让应用请求过的值仍可
    /// 观测，而不是悄悄变成空操作。
    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(@intFromPtr(self) != 0);
        self.dark_appearance = dark;
        std.debug.assert(self.dark_appearance == dark);
    }

    /// 帧缓冲实际清屏色。
    ///
    /// 依赖方在自己的帧回调里读它（玻璃窗口要透明清屏）。
    ///
    /// 玻璃样式需要透明清屏，宿主合成的背景才能透过。Wayland 自己产不出
    /// 模糊（见 `glass_style`），所以本后端上透明清屏就是效果的全部，
    /// 且只有 compositor 认 surface 的 alpha 时才可见。
    pub fn getClearColor(self: *const Self) geometry.Color {
        std.debug.assert(self.background_color.a >= 0.0);
        std.debug.assert(self.background_color.a <= 1.0);

        if (self.glass_style.needsTransparentClear()) return geometry.Color.transparent;
        return self.background_color;
    }

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return .{
            .x = self.mouse_x,
            .y = self.mouse_y,
        };
    }

    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    /// 取本窗口在 WindowRegistry 的唯一 id。
    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    /// 本窗口所属的平台。
    ///
    /// 按契约固定下来，让共享代码不用点名每个后端的字段名；
    /// 见 `contract.verifyWindowLifecycle`。
    pub fn getPlatform(self: *Self) *LinuxPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn requestRender(self: *Self) void {
        // 已关闭的窗口不会再出帧（`renderFrame` 立即返回），在这里挂起
        // `wl_callback` 只会启动一条每 vsync 自我重排、产出的帧全被丢弃的
        // 链。`setBackgroundColor` 这类 setter 在关闭与认领之间仍可能命中
        // 已关闭窗口，所以必须在入口拦而不只在调用点拦。
        if (self.closed) return;

        self.needs_redraw = true;
        self.scheduleFrame();

        std.debug.assert(self.needs_redraw);
        std.debug.assert(!self.closed);
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.platform.pointer == null or self.platform.seat != null);
        std.debug.assert(self.platform.cursor_shape_device == null or self.platform.pointer != null);
        self.platform.setCursorShape(shape);
    }

    // =========================================================================
    // IME 支持
    // =========================================================================

    /// 设置 IME 预编辑（composing）文本
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        if (text.len > self.marked_text_buffer.len) {
            @memcpy(self.marked_text_buffer[0..], text[0..self.marked_text_buffer.len]);
            self.marked_text = self.marked_text_buffer[0..self.marked_text_buffer.len];
        } else {
            @memcpy(self.marked_text_buffer[0..text.len], text);
            self.marked_text = self.marked_text_buffer[0..text.len];
        }
    }

    /// 清空预编辑文本（组合结束或取消）
    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    /// 设置 IME 上屏文本（拷入窗口私有的 buffer）
    pub fn setInsertedText(self: *Self, text: []const u8) void {
        if (text.len > self.inserted_text_buffer.len) {
            @memcpy(self.inserted_text_buffer[0..], text[0..self.inserted_text_buffer.len]);
            self.inserted_text = self.inserted_text_buffer[0..self.inserted_text_buffer.len];
        } else {
            @memcpy(self.inserted_text_buffer[0..text.len], text);
            self.inserted_text = self.inserted_text_buffer[0..text.len];
        }
    }

    /// 设置 IME 光标矩形（TextInput 在渲染时调用）
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        self.ime_cursor_rect = geometry.RectF.init(x, y, w, h);

        // 同步更新平台侧的文本输入光标矩形
        self.platform.setImeCursorRect(
            @intFromFloat(x),
            @intFromFloat(y),
            @intFromFloat(w),
            @intFromFloat(h),
        );
    }

    /// 是否有正在进行的 IME 组合
    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    /// 为本窗口开启 IME 输入
    pub fn enableIme(self: *Self) void {
        self.platform.enableTextInput();
    }

    /// 为本窗口关闭 IME 输入
    pub fn disableIme(self: *Self) void {
        self.platform.disableTextInput();
    }

    // =========================================================================
    // 输入回调管理
    // =========================================================================

    /// 设置输入回调
    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        self.on_input = callback;
    }

    /// 设置渲染回调
    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        self.on_render = callback;
    }

    /// 设置关闭回调。回调返回 false 可阻止窗口关闭。
    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    /// 设置缩放回调
    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        self.on_resize = callback;
    }

    /// 设置输入后回调（输入处理完成后调用）
    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        self.on_post_input = callback;
    }

    /// 设置用户数据指针
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    /// 取用户数据指针（类型转换）
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    // =========================================================================
    // 输入处理
    // =========================================================================

    /// 处理输入事件并派发给回调。
    /// 注意：Wayland 的 Y 轴朝下（顶部为 0），恰好与 windowkit 的输入坐标
    /// 约定一致。
    /// 依赖方的 swapchain 通常用负高度 viewport 翻转 Y 轴到 OpenGL/Metal 兼容的
    /// NDC 坐标，所以窗口层与输入分发都不做坐标翻转。
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        // 记录鼠标位置与是否在窗口内
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |m| {
                self.mouse_x = m.position.x;
                self.mouse_y = m.position.y;
            },
            .mouse_entered => |m| {
                self.mouse_x = m.position.x;
                self.mouse_y = m.position.y;
                self.mouse_inside = true;
            },
            .mouse_exited => |m| {
                self.mouse_x = m.position.x;
                self.mouse_y = m.position.y;
                self.mouse_inside = false;
            },
            else => {},
        }

        // 记录按下的键，供拖动检测用
        switch (event) {
            .mouse_down => |m| {
                self.pressed_button = m.button;
            },
            .mouse_up => {
                self.pressed_button = null;
            },
            else => {},
        }

        // 派发给用户回调
        var handled = false;
        if (self.on_input) |callback| {
            handled = callback(self, event);
        }

        // 输入处理完再调 post-input 回调。
        // 这里适合做会进入嵌套事件循环的操作（模态对话框）。
        if (self.on_post_input) |post_callback| {
            post_callback(self);
        }

        // 输入后请求重绘
        self.requestRender();
        return handled;
    }

    /// 从平台取当前修饰键状态
    pub fn getModifiers(self: *const Self) input.Modifiers {
        return linux_input.modifiersFromFlags(
            self.platform.modifier_shift,
            self.platform.modifier_ctrl,
            self.platform.modifier_alt,
            self.platform.modifier_super,
        );
    }

    // =========================================================================
    // 交互式窗口操作（供客户端装饰使用）
    // =========================================================================

    /// 发起交互式移动。
    /// 应在指针按下时调用（如标题栏区域）。此后 compositor 接管移动，
    /// 直到按键释放。
    pub fn startMove(self: *Self) void {
        const toplevel = self.xdg_toplevel orelse return;
        const seat = self.platform.seat orelse return;
        const serial = self.platform.last_pointer_serial;

        wayland.xdgToplevelMove(toplevel, seat, serial);
    }

    /// 发起交互式缩放。
    /// 应在指针按下时调用（如窗口边缘）。compositor 接管缩放直到松开。
    pub fn startResize(self: *Self, edge: wayland.ResizeEdge) void {
        const toplevel = self.xdg_toplevel orelse return;
        const seat = self.platform.seat orelse return;
        const serial = self.platform.last_pointer_serial;

        wayland.xdgToplevelResize(toplevel, seat, serial, edge);
    }

    /// 判断鼠标最近哪个缩放边，不在任何边缘（内容区内）返回 null。
    pub fn getResizeEdge(self: *const Self, x: f64, y: f64, border_width: f64) ?wayland.ResizeEdge {
        const w: f64 = @floatFromInt(self.width_px);
        const h: f64 = @floatFromInt(self.height_px);

        const near_left = x < border_width;
        const near_right = x >= w - border_width;
        const near_top = y < border_width;
        const near_bottom = y >= h - border_width;

        if (near_top and near_left) return .top_left;
        if (near_top and near_right) return .top_right;
        if (near_bottom and near_left) return .bottom_left;
        if (near_bottom and near_right) return .bottom_right;
        if (near_top) return .top;
        if (near_bottom) return .bottom;
        if (near_left) return .left;
        if (near_right) return .right;

        return null;
    }

    /// 判断点是否在"标题栏"区域（拖动窗口用的窗口顶部）。
    /// 客户端装饰场景下即窗口顶部 N 像素。
    pub fn isInTitleBar(self: *const Self, y: f64, title_bar_height: f64) bool {
        _ = self;
        return y < title_bar_height;
    }

    /// 请求下一个 vsync 的帧回调
    fn scheduleFrame(self: *Self) void {
        if (self.frame_callback != null) return; // 已排过
        if (self.wl_surface == null) return;

        self.frame_callback = wayland.surfaceFrame(self.wl_surface.?);
        if (self.frame_callback) |cb| {
            // 必须用静态 listener——局部变量传进去就成了悬垂指针！
            _ = wayland.callbackAddListener(cb, &frame_callback_listener, self);
        }
        wayland.surfaceCommit(self.wl_surface.?);
    }

    /// 绘制当前帧
    pub fn renderFrame(self: *Self) void {
        // 已关闭的窗口保持注册直到归属方认领，但绝不能再出帧——归属方的
        // 渲染资源可能已经在拆了。这里还顺手退役在途的帧回调，不让它驱动
        // 僵尸渲染链（见 `markClosed`）。
        if (self.closed) return;
        if (!self.configured) return;
        if (!self.needs_redraw and !self.pending_resize) return;

        // 先清请求位再进入应用代码，这样应用在构建动画时调用的
        // requestRender() 能活到下一帧。
        self.needs_redraw = false;

        // 处理待处理的 resize
        if (self.pending_resize) {
            const old_width = self.size.width;
            const old_height = self.size.height;

            self.width_px = self.pending_width;
            self.height_px = self.pending_height;
            self.size = .{
                .width = @floatFromInt(self.pending_width),
                .height = @floatFromInt(self.pending_height),
            };
            // 为 HiDPI 缩放更新 viewport 目标尺寸
            if (self.viewport) |vp| {
                wayland.viewportSetDestination(
                    vp,
                    @intCast(self.width_px),
                    @intCast(self.height_px),
                );
            } else if (self.wl_surface) |surface| {
                // 退回 buffer scale
                const scale_int: i32 = @intFromFloat(self.scale_factor);
                wayland.surfaceSetBufferScale(surface, scale_int);
            }
            if (self.xdg_surface) |xdg| {
                wayland.xdgSurfaceSetWindowGeometry(
                    xdg,
                    0,
                    0,
                    @intCast(self.width_px),
                    @intCast(self.height_px),
                );
            }
            // 提交 surface 状态（viewport、geometry）。交换链本身
            // 归依赖方：它在 `on_resize` 里凭 `framebufferSize()` 重建。
            if (self.wl_surface) |surface| {
                wayland.surfaceCommit(surface);
            }
            self.pending_resize = false;
            // 尺寸实际变了才通知
            const size_changed = (old_width != self.size.width or old_height != self.size.height);
            if (size_changed) {
                if (self.on_resize) |callback| {
                    callback(self, self.size.width, self.size.height);
                }
            }
        }

        // 帧回调：依赖方在这里录命令并 present。窗口层只做节拍与首帧信号
        // ——`has_presented_frame` 表示"已向 on_render 派发过首帧"，
        // `renderOpenWindows` 靠它完成无 buffer surface 的首帧 bootstrap。
        if (self.on_render) |callback| {
            callback(self);
        }
        self.has_presented_frame = true;
    }

    // =========================================================================
    // Wayland 回调
    // =========================================================================

    fn surfaceEnter(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = surface;
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));
        // 窗口在 workspaces/显示器之间移动时 output 归属变化可能改变
        // 缩放/配置状态，所以重建一次布局。
        self.requestRender();
    }

    fn surfaceLeave(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = surface;
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));
        self.requestRender();
    }

    fn surfacePreferredScale(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        factor: i32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        const new_scale: f64 = @floatFromInt(factor);
        if (self.scale_factor != new_scale) {
            self.scale_factor = new_scale;
            // 使用 viewport 时 buffer scale 无需更新——变的只是依赖方渲染的
            // 物理尺寸（framebufferSize），viewport 目标尺寸仍是逻辑像素
            if (self.viewport == null) {
                // 退路：把 buffer scale 告知 compositor
                wayland.surfaceSetBufferScale(surface, factor);
            }
            // 触发 resize，让依赖方按新 scale 重建交换链
            self.pending_resize = true;
            self.pending_width = self.width_px;
            self.pending_height = self.height_px;
        }
        self.requestRender();
    }

    fn surfacePreferredTransform(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        transform: u32,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = transform;
        // 变换只是信息性的，暂不处理
    }

    fn xdgSurfaceConfigure(
        data: ?*anyopaque,
        xdg_surface: *wayland.XdgSurface,
        serial: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));

        // 应答 configure
        wayland.xdgSurfaceAckConfigure(xdg_surface, serial);

        // 应用积压的尺寸变化
        if (self.pending_width > 0 and self.pending_height > 0) {
            self.pending_resize = true;
        }

        self.configured = true;
        self.requestRender();
    }

    // 参数带 `_px` 后缀：`width`/`height` 是本结构的声明，参数不能遮蔽。
    fn xdgToplevelConfigure(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width_px: i32,
        height_px: i32,
        states: *anyopaque,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        _ = states;
        const self: *Self = @ptrCast(@alignCast(data));

        // 宽高为 0 表示可以自选尺寸
        if (width_px > 0 and height_px > 0) {
            self.pending_width = @intCast(width_px);
            self.pending_height = @intCast(height_px);
        } else {
            self.pending_width = self.width_px;
            self.pending_height = self.height_px;
        }
    }

    fn xdgToplevelConfigureBounds(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width_px: i32,
        height_px: i32,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = width_px;
        _ = height_px;
        // configure_bounds 只是信息——compositor 建议的最大尺寸，
        // 暂不强制执行
    }

    fn xdgToplevelWmCapabilities(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        capabilities: *anyopaque,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = capabilities;
        // wm_capabilities 告知 compositor 支持哪些能力，暂不处理
    }

    /// compositor 要求该 toplevel 关闭（标题栏按钮、窗口菜单或会话请求）。
    ///
    /// 经由 `close()` 走：compositor 请求与程序关闭跑同一套否决与状态
    /// 迁移，应用无法区分两者。销毁窗口会让调用我们的 Wayland 派发
    /// 站在悬垂对象上，在这里退出则会殃及所有其他窗口。
    fn xdgToplevelClose(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        const self: *Self = @ptrCast(@alignCast(data));
        std.debug.assert(@intFromPtr(self) != 0);

        self.close();

        // 这里没有拆除任何东西：`window_id` 只在 `deinit` 里失效，所以
        // 断言窗口仍在注册、归属方仍能按 id 解析到它。
        std.debug.assert(self.window_id.isValid());
    }

    fn decorationConfigure(
        data: ?*anyopaque,
        decoration: *wayland.ZxdgToplevelDecorationV1,
        mode: wayland.ZxdgToplevelDecorationV1Mode,
    ) callconv(.c) void {
        _ = decoration;
        const self: *Self = @ptrCast(@alignCast(data));

        switch (mode) {
            .server_side => {
                std.debug.print("Compositor will provide window decorations (server-side)\n", .{});
                self.has_server_decorations = true;
            },
            .client_side => {
                std.debug.print("WARNING: Compositor requires client-side decorations (not implemented)\n", .{});
                std.debug.print("Window will have no title bar - cannot move/resize/close with mouse\n", .{});
                self.has_server_decorations = false;
            },
            .undefined => {
                std.debug.print("WARNING: Decoration mode undefined\n", .{});
                self.has_server_decorations = false;
            },
        }
    }

    fn frameCallback(
        data: ?*anyopaque,
        callback: *wayland.Callback,
        callback_data: u32,
    ) callconv(.c) void {
        _ = callback_data;
        const self: *Self = @ptrCast(@alignCast(data));

        // 销毁回调对象
        wayland.callbackDestroy(callback);
        self.frame_callback = null;

        // DEBUG：帧率统计。Wayland 帧回调跑在主事件线程，拿不到窗口
        // 指针之外的状态，所以借单线程全局 `Io` 读时间。
        const static = struct {
            var count: u32 = 0;
            var last_print_ms: i64 = 0;
        };
        static.count += 1;
        const fps_io = std.Io.Threaded.global_single_threaded.io();
        const now_ms = std.Io.Timestamp.now(fps_io, .awake).toMilliseconds();
        if (now_ms - static.last_print_ms > 1000) {
            std.debug.print("Wayland frame callbacks/sec: {}\n", .{static.count});
            static.count = 0;
            static.last_print_ms = now_ms;
        }

        // 连续模式：总是渲染，保证动画流畅、渲染回调每次都触发
        if (self.continuous_render) {
            self.needs_redraw = true;
        }

        // 绘制当前帧
        self.renderFrame();

        // 请求下一帧:连续模式总是排(vsync 驱动),按需模式仅在
        // needs_redraw 仍为真时排。
        if (self.continuous_render or self.needs_redraw) {
            self.scheduleFrame();
        }
    }
};
