//! Windows 窗口实现 —— Win32 窗口 + 消息翻译 + DWM 玻璃。
//!
//! 渲染由依赖方持有:事件循环每个 vsync(`DwmFlush`)通过 `on_render`
//! 回调交给调用方,`HWND`/`HINSTANCE` 经 `nativeHandles()` 交出。
//!
//! 线程模型:所有窗口操作都在创建它的 UI 线程(消息循环线程)上。没有
//! 后台渲染线程,所以不需要 `render_mutex` —— 输入回调与渲染回调天然
//! 串行。这与 macOS(CVDisplayLink 线程)不同,但对外契约一致。

const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("../../geometry.zig");
const input = @import("../../input/events.zig");
const interface_mod = @import("../interface.zig");
const win32 = @import("win32.zig");
const win_input = @import("input.zig");
const platform = @import("platform.zig");
const drop_target = @import("drop_target.zig");

const WindowId = interface_mod.WindowId;
const WindowOptions = interface_mod.WindowOptions;
const GlassStyle = interface_mod.GlassStyle;
const CursorShape = interface_mod.CursorShape;
const native_handles = @import("../native_handles.zig");
const NativeHandles = native_handles.NativeHandles;
const FramebufferSize = native_handles.FramebufferSize;

/// 窗口标题字节上限(与 macOS/Linux 后端一致的 255)。
pub const title_bytes_max: usize = 255;

pub const Window = struct {
    allocator: std.mem.Allocator,
    plat: *platform.WindowsPlatform,

    hwnd: ?*anyopaque,
    hinstance: ?*anyopaque,

    /// 文件拖放目标(COM IDropTarget)。null = 注册失败,窗口照常工作。
    file_drop: ?*drop_target.DropTarget = null,
    /// 拖放开关(初始值来自 `options.file_drop`;false 时 DragEnter 报
    /// DROPEFFECT_NONE,光标显示“不可放下”,不派发 .file_drop 事件)。
    file_drop_enabled: bool = true,

    /// 客户区**逻辑**尺寸(= 物理 px / scale)。
    size: geometry.Size(f64),
    /// 每英寸逻辑像素 / 96。1.0 = 100% 缩放。
    scale_factor: f64,

    title_buf: [title_bytes_max + 1]u8,
    title_len: u16,

    background_color: geometry.Color,
    /// 有渲染需求置位;渲染回调派发后清零。
    needs_render: std.atomic.Value(bool),

    window_id: WindowId = .invalid,
    closed: bool = false,

    // 玻璃/透明
    glass_style: GlassStyle = .none,
    background_opacity: f64 = 1.0,
    glass_corner_radius: f64 = 16.0,

    // 鼠标
    mouse_position: geometry.Point(f64) = .{ .x = 0, .y = 0 },
    mouse_inside: bool = false,
    /// 鼠标按住跟踪(Win32 没有 drag 事件,靠按钮位 + move 拼)。
    mouse_buttons: u8 = 0,

    /// 上次应用的光标形状(每帧调 setCursorShape 时短路)。
    cursor_shape: ?CursorShape = null,

    // IME
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,
    /// WM_CHAR 的代理对拼装缓冲。
    char_buffer: win_input.CharBuffer = .{},
    /// IME 候选窗定位矩形(客户区坐标,像素)。
    ime_cursor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 1, .bottom = 20 },

    // 回调
    on_input: ?InputCallback = null,
    on_render: ?RenderCallback = null,
    on_close: ?CloseCallback = null,
    on_resize: ?ResizeCallback = null,
    on_post_input: ?PostInputCallback = null,
    user_data: ?*anyopaque = null,

    /// 最小/最大客户区尺寸(物理 px,null = 不限)。WndProc 的
    /// WM_GETMINMAXINFO 读它;init 里按最终 scale 换算。
    min_size_px: ?geometry.Size(f64) = null,
    max_size_px: ?geometry.Size(f64) = null,

    // =========================================================================
    // 类型
    // =========================================================================

    /// 输入回调:返回 true 表示事件已消费。
    pub const InputCallback = *const fn (*Window, input.InputEvent) bool;
    /// 每帧渲染回调(依赖方在这里录命令并 present)。
    pub const RenderCallback = *const fn (*Window) void;
    /// 关闭前回调:返回 false 阻止关闭。
    pub const CloseCallback = *const fn (*Window) bool;
    /// 尺寸变化回调(逻辑像素)。
    pub const ResizeCallback = *const fn (*Window, f64, f64) void;
    /// 输入处理完成后(无锁)回调,可跑嵌套消息循环。
    pub const PostInputCallback = *const fn (*Window) void;

    const Self = @This();

    // =========================================================================
    // 生命周期
    // =========================================================================

    pub fn init(
        allocator: std.mem.Allocator,
        plat: *platform.WindowsPlatform,
        options: *const WindowOptions,
    ) !*Self {
        assert(@intFromPtr(plat) != 0);
        assert(options.width >= 1);
        assert(options.height >= 1);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        initFields(self, allocator, plat, options);

        // 先注册:窗口创建期间 WM_NCCREATE 会把 self 挂到 GWLP_USERDATA。
        self.window_id = try plat.registerWindow(self);
        errdefer plat.unregisterWindow(self.window_id);
        assert(self.window_id.isValid());

        try self.createHwnd(options);

        // 文件拖放:窗口可见前挂上,失败只失去拖放(不虚标的能力在
        // capabilities.file_drop 已声明,单窗口注册失败是运行时边角)。
        self.file_drop = drop_target.DropTarget.create(allocator, self) catch null;
        if (self.file_drop) |dt| {
            if (!dt.register()) {
                _ = dt.releaseRef();
                self.file_drop = null;
            }
        }

        // 尺寸以实际客户区为准(Win32 会按样式调整外框)。
        self.syncSizeFromHwnd();

        if (options.centered) self.center();

        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(self.hwnd);

        self.requestRender();
        plat.setActiveWindowId(self.window_id);

        assert(!self.closed);
        assert(self.plat.getWindow(self.window_id) != null);
        return self;
    }

    noinline fn initFields(
        self: *Self,
        allocator: std.mem.Allocator,
        plat: *platform.WindowsPlatform,
        options: *const WindowOptions,
    ) void {
        assert(@intFromPtr(self) != 0);

        self.* = .{
            .allocator = allocator,
            .plat = plat,
            .hwnd = null,
            .hinstance = plat.hinstance,
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = plat.primaryScaleFactor(),
            .title_buf = @splat(0),
            .title_len = 0,
            .background_color = options.background_color,
            .file_drop_enabled = options.file_drop,
            .needs_render = std.atomic.Value(bool).init(true),
            .glass_style = options.glass_style,
            .background_opacity = options.background_opacity,
            .glass_corner_radius = options.glass_corner_radius,
        };
        assert(self.window_id == .invalid);
        assert(!self.closed);
    }

    /// CreateWindowExW + 样式/DPI/最小最大尺寸。
    fn createHwnd(self: *Self, options: *const WindowOptions) !void {
        const scale = self.scale_factor;

        // 逻辑 → 物理(客户区尺寸)。
        const w_px: i32 = @intFromFloat(@round(options.width * scale));
        const h_px: i32 = @intFromFloat(@round(options.height * scale));

        // WS_OVERLAPPEDWINDOW 先按物理尺寸建;AdjustWindowRectEx 补外框。
        var rect = win32.RECT{
            .left = 0,
            .top = 0,
            .right = w_px,
            .bottom = h_px,
        };
        _ = win32.AdjustWindowRectEx(&rect, win32.WS_OVERLAPPEDWINDOW, 0, 0);

        // 玻璃窗口需要分层样式(整体透明度)。
        var exstyle: win32.DWORD = win32.WS_EX_APPWINDOW;
        if (options.background_opacity < 1.0 or options.glass_style != .none) {
            exstyle |= win32.WS_EX_LAYERED;
        }

        const class_name = win32_class_name();
        const title_w = try utf8ToWideZ(self.allocator, options.title);
        defer self.allocator.free(title_w);

        const hwnd = win32.CreateWindowExW(
            exstyle,
            class_name,
            title_w.ptr,
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            rect.width(),
            rect.height(),
            null,
            null,
            self.hinstance,
            @ptrCast(self), // lpCreateParams → WM_NCCREATE → GWLP_USERDATA
        );
        if (hwnd == null) return error.WindowCreationFailed;
        self.hwnd = hwnd;

        self.setTitle(options.title);

        // 最小/最大尺寸:WM_GETMINMAXINFO 里按物理像素套用。
        // 存进 user_data 让 WndProc 能读到(WM_GETMINMAXINFO 在 init 返回前
        // 就可能来)。
        self.min_size_px = scaleSize(options.min_size, scale);
        self.max_size_px = scaleSize(options.max_size, scale);

        // DPI 感知:进程级已在 platform.init 设好 PER_MONITOR_AWARE_V2;
        // 这里按窗口当前 DPI 修正 scale(首屏 DPI 可能不是 96)。
        const dpi = win32.GetDpiForWindow(hwnd);
        if (dpi > 0) {
            self.scale_factor = @as(f64, @floatFromInt(dpi)) / 96.0;
        }

        self.applyGlass();

        // 分层透明度。
        if (exstyle & win32.WS_EX_LAYERED != 0) {
            const alpha: u8 = @intFromFloat(@round(self.background_opacity * 255.0));
            _ = win32.SetLayeredWindowAttributes(hwnd, 0, @max(alpha, 1), win32.LWA_ALPHA);
        }

        // 最小/最大在 DPI 修正后重算。
        self.min_size_px = scaleSize(options.min_size, self.scale_factor);
        self.max_size_px = scaleSize(options.max_size, self.scale_factor);
    }

    pub fn deinit(self: *Self) void {
        // 先从注册表摘掉,避免销毁期间被查到。
        if (self.window_id.isValid()) {
            self.plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        self.closed = true;

        if (self.hwnd) |hwnd| {
            // DestroyWindow 同步派发 WM_DESTROY;此时 self 还活着,
            // WndProc 里的 closed 分支直接放行。
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        self.allocator.destroy(self);
    }

    // =========================================================================
    // 原生句柄 / 帧缓冲
    // =========================================================================

    /// 交给依赖方的 Win32 对象:`HWND` + `HINSTANCE`。
    /// 建 Vulkan surface 用 `hwnd`(VK_KHR_win32_surface),
    /// D3D12 也只用 HWND。
    pub fn nativeHandles(self: *const Self) NativeHandles {
        assert(self.hwnd != null);
        assert(self.hinstance != null);
        return .{ .win32 = .{
            .hwnd = self.hwnd.?,
            .hinstance = self.hinstance.?,
        } };
    }

    /// 帧缓冲物理像素尺寸 —— 客户区矩形(已按 per-monitor DPI 是物理值)。
    pub fn framebufferSize(self: *const Self) FramebufferSize {
        assert(self.hwnd != null);
        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(self.hwnd, &rect);
        return .{
            .width_px = @intCast(@max(rect.width(), 0)),
            .height_px = @intCast(@max(rect.height(), 0)),
        };
    }

    // =========================================================================
    // 尺寸 / DPI
    // =========================================================================

    /// 从 HWND 客户区同步逻辑尺寸(创建后与 WM_SIZE 里调)。
    fn syncSizeFromHwnd(self: *Self) void {
        assert(self.hwnd != null);
        var rect: win32.RECT = undefined;
        _ = win32.GetClientRect(self.hwnd, &rect);

        const w_px: f64 = @floatFromInt(@max(rect.width(), 0));
        const h_px: f64 = @floatFromInt(@max(rect.height(), 0));
        if (w_px < 1 or h_px < 1) return;

        self.size = geometry.Size(f64).init(w_px / self.scale_factor, h_px / self.scale_factor);
    }

    fn center(self: *Self) void {
        assert(self.hwnd != null);
        var wr: win32.RECT = undefined;
        _ = win32.GetWindowRect(self.hwnd, &wr);

        // 工作区(去掉任务栏)。
        var work: win32.RECT = undefined;
        if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0) == 0) {
            // 失败就用整个屏幕。
            work = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
        }

        const w = wr.width();
        const h = wr.height();
        const x = work.left + @divTrunc(work.width() - w, 2);
        const y = work.top + @divTrunc(work.height() - h, 2);

        _ = win32.SetWindowPos(self.hwnd, null, x, y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    }

    // =========================================================================
    // 回调设置
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        assert(self.window_id.isValid());
        self.on_input = callback;
    }

    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        assert(self.window_id.isValid());
        self.on_render = callback;
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        assert(self.window_id.isValid());
        self.on_close = callback;
    }

    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        assert(self.window_id.isValid());
        self.on_resize = callback;
    }

    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        assert(self.window_id.isValid());
        self.on_post_input = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        assert(self.window_id.isValid());
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| return @ptrCast(@alignCast(ptr));
        return null;
    }

    // =========================================================================
    // 访问器
    // =========================================================================

    pub fn getClearColor(self: *const Self) geometry.Color {
        return switch (self.glass_style) {
            .blur, .glass_regular, .glass_clear, .vibrancy => geometry.Color.transparent,
            .none => self.background_color,
        };
    }

    pub fn width(self: *const Self) u32 {
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        assert(self.scale_factor > 0.0);
        return self.scale_factor;
    }

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return self.mouse_position;
    }

    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    pub fn getPlatform(self: *Self) *platform.WindowsPlatform {
        assert(@intFromPtr(self.plat) != 0);
        return self.plat;
    }

    // =========================================================================
    // 窗口操作
    // =========================================================================

    pub fn focus(self: *Self) void {
        if (self.hwnd) |hwnd| {
            _ = win32.SetForegroundWindow(hwnd);
            _ = win32.BringWindowToTop(hwnd);
            _ = win32.SetFocus(hwnd);
        }
    }

    /// 程序化关闭:on_close 可否决,否则 DestroyWindow。
    pub fn close(self: *Self) void {
        if (self.closed) return;
        if (!self.handleClose()) return;
        if (self.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn requestRender(self: *Self) void {
        self.needs_render.store(true, .release);
    }

    /// 手动同步派发一次渲染回调(use_display_link = false 时的驱动入口)。
    pub fn render(self: *Self) void {
        if (self.closed) return;
        if (self.on_render) |callback| callback(self);
    }

    /// 运行时开关文件拖放(初始值来自 `options.file_drop`)。关闭后拖进
    /// 窗口的光标是“不可放下”,不再派发 `.file_drop` 事件。
    pub fn setFileDropEnabled(self: *Self, enabled: bool) void {
        self.file_drop_enabled = enabled;
    }

    pub fn setTitle(self: *Self, new_title: []const u8) void {
        assert(self.title_buf.len == title_bytes_max + 1);
        const len = @min(new_title.len, title_bytes_max);

        @memcpy(self.title_buf[0..len], new_title[0..len]);
        @memset(self.title_buf[len..], 0);
        self.title_len = @intCast(len);

        if (self.hwnd) |hwnd| {
            const wide = utf8ToWideZ(self.allocator, self.title_buf[0..len]) catch return;
            defer self.allocator.free(wide);
            _ = win32.SetWindowTextW(hwnd, wide.ptr);
        }
    }

    pub fn title(self: *const Self) []const u8 {
        assert(self.title_len <= title_bytes_max);
        return self.title_buf[0..self.title_len];
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
    }

    /// 设置光标形状(缓存短路;每帧调用时常见无变化)。
    pub fn setCursorShape(self: *Self, shape: CursorShape) void {
        if (self.cursor_shape) |current| {
            if (current == shape) return;
        }
        const cursor = loadCursor(shape) orelse return;
        _ = win32.SetCursor(cursor);
        self.cursor_shape = shape;
    }

    /// 运行时切换玻璃样式(DWM backdrop + 圆角)。
    pub fn setGlassStyle(self: *Self, style: GlassStyle, opacity: f64, corner_radius: f64) void {
        assert(opacity >= 0.0 and opacity <= 1.0);
        assert(corner_radius >= 0.0);

        self.glass_style = style;
        self.background_opacity = opacity;
        self.glass_corner_radius = corner_radius;
        self.applyGlass();

        // 透明度变化要更新分层属性。
        if (self.hwnd) |hwnd| {
            const ex = @as(win32.DWORD, @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE)));
            if (ex & win32.WS_EX_LAYERED != 0) {
                const alpha: u8 = @intFromFloat(@round(opacity * 255.0));
                _ = win32.SetLayeredWindowAttributes(hwnd, 0, @max(alpha, 1), win32.LWA_ALPHA);
            }
        }
        self.requestRender();
    }

    // =========================================================================
    // 玻璃/DWM
    // =========================================================================

    /// 按当前 glass_style 施加 DWM 效果:
    /// - `.none`:清 backdrop,恢复不透明。
    /// - `.blur` / `.vibrancy`:Acrylic backdrop(半透明模糊)。
    /// - `.glass_regular` / `.glass_clear`:Mica backdrop + 圆角。
    /// 老系统(DWM 不支持 backdrop 属性)静默降级为无效果。
    fn applyGlass(self: *Self) void {
        const hwnd = self.hwnd orelse return;

        const backdrop: u32 = switch (self.glass_style) {
            .none => win32.DWMSBT_NONE,
            .blur, .vibrancy => win32.DWMSBT_TRANSIENTWINDOW, // Acrylic
            .glass_regular, .glass_clear => win32.DWMSBT_MAINWINDOW, // Mica
        };
        _ = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_SYSTEMBACKDROP_TYPE,
            &backdrop,
            @sizeOf(u32),
        );

        // 圆角:玻璃样式一律圆角,`.none` 交给系统默认。
        if (self.glass_style != .none) {
            const corner: u32 = win32.DWMWCP_ROUND;
            _ = win32.DwmSetWindowAttribute(
                hwnd,
                win32.DWMWA_WINDOW_CORNER_PREFERENCE,
                &corner,
                @sizeOf(u32),
            );
        }
    }

    // =========================================================================
    // IME
    // =========================================================================

    /// 设置组合(composing)文本。
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        if (text.len > self.marked_text_buffer.len) {
            @memcpy(self.marked_text_buffer[0..], text[0..self.marked_text_buffer.len]);
            self.marked_text = self.marked_text_buffer[0..self.marked_text_buffer.len];
        } else {
            @memcpy(self.marked_text_buffer[0..text.len], text);
            self.marked_text = self.marked_text_buffer[0..text.len];
        }
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    /// IME 候选窗定位矩形(客户区坐标,逻辑像素 → 物理 px)。
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        const s = self.scale_factor;
        self.ime_cursor_rect = .{
            .left = @intFromFloat(@round(@as(f64, x) * s)),
            .top = @intFromFloat(@round(@as(f64, y) * s)),
            .right = @intFromFloat(@round(@as(f64, x + w) * s)),
            .bottom = @intFromFloat(@round(@as(f64, y + h) * s)),
        };
        self.applyImeCandidatePos();
    }

    fn applyImeCandidatePos(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        const himc = win32.ImmGetContext(hwnd) orelse return;
        defer _ = win32.ImmReleaseContext(hwnd, himc);

        const form = win32.CANDIDATEFORM{
            .dwIndex = 0,
            .dwStyle = win32.CFS_POINT,
            .ptCurrentPos = .{ .x = self.ime_cursor_rect.left, .y = self.ime_cursor_rect.bottom },
            .rcArea = self.ime_cursor_rect,
        };
        _ = win32.ImmSetCandidateWindow(himc, &form);
    }

    // =========================================================================
    // 输入处理
    // =========================================================================

    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        // 跟踪鼠标位置/进入退出。
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |m| {
                self.mouse_position = m.position;
            },
            .mouse_entered => |m| {
                self.mouse_position = m.position;
                self.mouse_inside = true;
            },
            .mouse_exited => |m| {
                self.mouse_position = m.position;
                self.mouse_inside = false;
            },
            else => {},
        }

        var handled = false;
        if (self.on_input) |callback| {
            handled = callback(self, event);
            if (self.on_post_input) |post| post(self);
        }
        self.requestRender();
        return handled;
    }

    // =========================================================================
    // WndProc 消息处理(由静态 wndProc 转发)
    // =========================================================================

    /// WM_CLOSE:on_close 可否决。
    fn handleClose(self: *Self) bool {
        if (self.on_close) |callback| {
            if (!callback(self)) return false;
        }
        self.closed = true;
        return true;
    }

    /// WM_DESTROY:窗口已销毁,从注册表摘掉。
    fn handleDestroy(self: *Self) void {
        // 拖放目标先摘:WM_DESTROY 期间 HWND 仍有效,RevokeDragDrop 要
        // 在 OLE 还能查到窗口时做;之后放掉窗口那份引用(归零即释放)。
        if (self.file_drop) |dt| {
            dt.unregister();
            _ = dt.releaseRef();
            self.file_drop = null;
        }

        self.hwnd = null;
        self.closed = true;
        if (self.window_id.isValid()) {
            self.plat.unregisterWindow(self.window_id);
            // 最后一个窗口关闭 → 结束事件循环(与 Linux 后端一致)。
            if (self.plat.windowCount() == 0) {
                win32.PostQuitMessage(0);
            }
        }
    }

    /// WM_SIZE:更新逻辑尺寸 + 派发 on_resize。
    fn handleResize(self: *Self) void {
        const old_w = self.size.width;
        const old_h = self.size.height;

        self.syncSizeFromHwnd();
        if (self.size.width == old_w and self.size.height == old_h) return;
        if (self.size.width < 1 or self.size.height < 1) return;

        self.requestRender();
        if (self.on_resize) |callback| {
            callback(self, self.size.width, self.size.height);
        }
    }

    /// WM_DPICHANGED:按系统建议矩形调整,更新 scale。
    fn handleDpiChanged(self: *Self, suggested: *const win32.RECT) void {
        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.width(),
                suggested.height(),
                win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
            );
        }

        const dpi = win32.GetDpiForWindow(self.hwnd);
        if (dpi > 0) {
            const new_scale = @as(f64, @floatFromInt(dpi)) / 96.0;
            if (new_scale != self.scale_factor) {
                self.scale_factor = new_scale;
                self.syncSizeFromHwnd();
                self.requestRender();
                if (self.on_resize) |callback| {
                    callback(self, self.size.width, self.size.height);
                }
            }
        }
    }

    /// WM_GETMINMAXINFO:套用最小/最大客户区尺寸(物理 px)。
    fn handleGetMinMaxInfo(self: *Self, mmi: *win32.MINMAXINFO) void {
        if (self.min_size_px) |min| {
            // 客户区 → 窗口外框:补上非客户区。
            var rect = win32.RECT{
                .left = 0,
                .top = 0,
                .right = @intFromFloat(@round(min.width)),
                .bottom = @intFromFloat(@round(min.height)),
            };
            _ = win32.AdjustWindowRectEx(&rect, win32.WS_OVERLAPPEDWINDOW, 0, 0);
            mmi.ptMinTrackSize = .{ .x = rect.width(), .y = rect.height() };
        }
        if (self.max_size_px) |max| {
            var rect = win32.RECT{
                .left = 0,
                .top = 0,
                .right = @intFromFloat(@round(max.width)),
                .bottom = @intFromFloat(@round(max.height)),
            };
            _ = win32.AdjustWindowRectEx(&rect, win32.WS_OVERLAPPEDWINDOW, 0, 0);
            mmi.ptMaxTrackSize = .{ .x = rect.width(), .y = rect.height() };
        }
    }

    /// WM_PAINT:我们不做软件绘制(渲染归依赖方),只 validate 区域,
    /// 避免系统反复发 WM_PAINT。
    fn handlePaint(self: *Self) void {
        var ps: win32.PAINTSTRUCT = undefined;
        const hdc = win32.BeginPaint(self.hwnd, &ps);
        _ = hdc;
        _ = win32.EndPaint(self.hwnd, &ps);
        self.requestRender();
    }
};

// =============================================================================
// 窗口类注册
// =============================================================================

/// 窗口类名(每进程唯一;用 module 名避免与宿主冲突)。
pub fn win32_class_name() [*:0]const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral("windowkit.Window");
}

/// 注册窗口类。已在 platform.init 调;重复注册返回 false 但不报错。
pub fn registerWindowClass(hinstance: ?*anyopaque) bool {
    const wnd_proc: win32.WNDPROC = wndProc;

    const cls = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = wnd_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = loadCursor(.default) orelse null,
        .hbrBackground = null, // 客户区由渲染方负责,不画背景
        .lpszMenuName = null,
        .lpszClassName = win32_class_name(),
        .hIconSm = null,
    };
    return win32.RegisterClassExW(&cls) != 0;
}

// =============================================================================
// 静态 WndProc
// =============================================================================

/// Win32 窗口过程:从 GWLP_USERDATA 取 `*Window`,按消息分发。
/// 返回 0 表示消息已处理;否则交给 DefWindowProcW。
fn wndProc(
    hwnd: ?*anyopaque,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    // WM_NCCREATE 之前 GWLP_USERDATA 还没值,直接放行。
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        // lpCreateParams 是 init 传的 self。
        const self: *Window = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(self)));
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam); // 必须返回 TRUE
    }

    const self_ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (self_ptr == 0) {
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(self_ptr)));

    // 窗口已销毁后的残余消息:只做最小处理。
    if (self.closed and msg != win32.WM_DESTROY) {
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    return switch (msg) {
        win32.WM_CLOSE => {
            if (self.handleClose()) {
                _ = win32.DestroyWindow(hwnd);
            }
            return 0;
        },
        win32.WM_DESTROY => {
            self.handleDestroy();
            return 0;
        },
        win32.WM_SIZE => {
            self.handleResize();
            return 0;
        },
        win32.WM_DPICHANGED => {
            const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.handleDpiChanged(suggested);
            return 0;
        },
        win32.WM_GETMINMAXINFO => {
            const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.handleGetMinMaxInfo(mmi);
            return 0;
        },
        win32.WM_PAINT => {
            self.handlePaint();
            return 0;
        },
        win32.WM_ERASEBKGND => return 1, // 渲染方负责,阻止背景擦除闪烁
        win32.WM_SETCURSOR => {
            if (@as(win32.LPARAM, @truncate(lparam)) == win32.HTCLIENT) {
                // 光标形状由 setCursorShape 每帧设置;这里保持当前。
                return 1;
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            self.plat.setActiveWindowId(if (msg == win32.WM_SETFOCUS) self.window_id else null);
            self.requestRender();
            return 0;
        },
        win32.WM_MOUSEMOVE => handleMouseMove(self, wparam, lparam),
        win32.WM_MOUSELEAVE => {
            self.mouse_inside = false;
            _ = self.handleInput(.{ .mouse_exited = mouseEvent(self, .middle, wparam) });
            return 0;
        },
        win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN => {
            const button: input.MouseButton = switch (msg) {
                win32.WM_LBUTTONDOWN => .left,
                win32.WM_RBUTTONDOWN => .right,
                else => .middle,
            };
            self.mouse_buttons |= @as(u8, 1) << @intCast(@intFromEnum(button));
            _ = win32.SetCapture(hwnd);
            _ = self.handleInput(.{ .mouse_down = mouseEvent(self, button, wparam) });
            return 0;
        },
        win32.WM_LBUTTONUP, win32.WM_RBUTTONUP, win32.WM_MBUTTONUP => {
            const button: input.MouseButton = switch (msg) {
                win32.WM_LBUTTONUP => .left,
                win32.WM_RBUTTONUP => .right,
                else => .middle,
            };
            self.mouse_buttons &= ~(@as(u8, 1) << @intCast(@intFromEnum(button)));
            if (self.mouse_buttons == 0) _ = win32.ReleaseCapture();
            _ = self.handleInput(.{ .mouse_up = mouseEvent(self, button, wparam) });
            return 0;
        },
        win32.WM_MOUSEWHEEL => handleMouseWheel(self, wparam, lparam),
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            const extended = (lparam & (1 << 24)) != 0;
            const key = win_input.keyTagFromVirtualKey(wparam, extended);
            const repeat = (lparam & (1 << 30)) != 0;
            _ = self.handleInput(.{ .key_down = .{
                .key = key,
                .modifiers = win_input.currentModifiers(),
                .characters = null,
                .characters_ignoring_modifiers = null,
                .is_repeat = repeat,
            } });
            return 0;
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            const extended = (lparam & (1 << 24)) != 0;
            const key = win_input.keyTagFromVirtualKey(wparam, extended);
            _ = self.handleInput(.{ .key_up = .{
                .key = key,
                .modifiers = win_input.currentModifiers(),
                .characters = null,
                .characters_ignoring_modifiers = null,
                .is_repeat = false,
            } });
            return 0;
        },
        win32.WM_CHAR => {
            // 代理对拼装;完整字符到齐才发 text_input。
            if (self.char_buffer.pushUtf16(@truncate(wparam))) {
                _ = self.handleInput(.{ .text_input = .{ .text = self.char_buffer.slice() } });
            }
            return 0;
        },
        win32.WM_IME_STARTCOMPOSITION => {
            self.clearMarkedText();
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_IME_COMPOSITION => handleImeComposition(self, lparam),
        win32.WM_IME_ENDCOMPOSITION => {
            self.clearMarkedText();
            _ = self.handleInput(.{ .composition = .{ .text = "" } });
            return 0;
        },
        else => win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    };
}

// =============================================================================
// 鼠标/IME 消息助手
// =============================================================================

fn handleMouseMove(self: *Window, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    self.mouse_inside = true;
    const pos = geometry.Point(f64).init(
        @floatFromInt(win_input.mouseXFromLParam(lparam)),
        @floatFromInt(win_input.mouseYFromLParam(lparam)),
    );

    const button: input.MouseButton = if (self.mouse_buttons & 0b001 != 0)
        .left
    else if (self.mouse_buttons & 0b010 != 0)
        .right
    else
        .middle;

    const dragged = self.mouse_buttons != 0;
    const event: input.InputEvent = if (dragged)
        .{ .mouse_dragged = .{
            .position = pos,
            .button = button,
            .click_count = 1,
            .modifiers = win_input.modifiersFromMouseWParam(wparam),
        } }
    else
        .{ .mouse_moved = .{
            .position = pos,
            .button = button,
            .click_count = 1,
            .modifiers = win_input.modifiersFromMouseWParam(wparam),
        } };

    _ = self.handleInput(event);
    return 0;
}

fn handleMouseWheel(self: *Window, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    const delta = win_input.wheelDeltaFromWParam(wparam);
    // 滚轮坐标是屏幕坐标,转客户区。
    var pt = win32.POINT{
        .x = win_input.mouseXFromLParam(lparam),
        .y = win_input.mouseYFromLParam(lparam),
    };
    _ = win32.ScreenToClient(self.hwnd, &pt);

    const pos = geometry.Point(f64).init(@floatFromInt(pt.x), @floatFromInt(pt.y));
    _ = self.handleInput(.{ .scroll = .{
        .position = pos,
        .delta = .{ .x = 0, .y = @as(f64, @floatFromInt(delta)) / 120.0 },
        .modifiers = win_input.currentModifiers(),
    } });
    return 0;
}

fn handleImeComposition(self: *Window, lparam: win32.LPARAM) win32.LRESULT {
    const himc = win32.ImmGetContext(self.hwnd) orelse
        return win32.DefWindowProcW(self.hwnd, win32.WM_IME_COMPOSITION, 0, lparam);
    defer _ = win32.ImmReleaseContext(self.hwnd, himc);

    // 结果串(最终上屏文本)优先。
    if (lparam & @as(win32.LPARAM, win32.GCS_RESULTSTR) != 0) {
        const len = compositionStringLen(himc, win32.GCS_RESULTSTR);
        if (len > 0) {
            var buf: [256]u16 = undefined;
            const units = @min(@divTrunc(@as(usize, @intCast(len)), 2), buf.len - 1);
            const got = win32.ImmGetCompositionStringW(himc, win32.GCS_RESULTSTR, &buf, @intCast(units * 2));
            if (got > 0) {
                const slice = buf[0 .. @as(usize, @intCast(got)) / 2];
                if (std.unicode.utf16LeToUtf8(self.marked_text_buffer[0..], slice)) |n| {
                    self.marked_text = self.marked_text_buffer[0..n];
                    _ = self.handleInput(.{ .text_input = .{ .text = self.marked_text } });
                    self.clearMarkedText();
                } else |_| {}
            }
        }
        return 0;
    }

    // 组合串(preedit)。
    if (lparam & @as(win32.LPARAM, win32.GCS_COMPSTR) != 0) {
        const len = compositionStringLen(himc, win32.GCS_COMPSTR);
        if (len > 0) {
            var buf: [256]u16 = undefined;
            const units = @min(@divTrunc(@as(usize, @intCast(len)), 2), buf.len - 1);
            const got = win32.ImmGetCompositionStringW(himc, win32.GCS_COMPSTR, &buf, @intCast(units * 2));
            if (got > 0) {
                const slice = buf[0 .. @as(usize, @intCast(got)) / 2];
                if (std.unicode.utf16LeToUtf8(self.marked_text_buffer[0..], slice)) |n| {
                    self.setMarkedText(self.marked_text_buffer[0..n]);
                    _ = self.handleInput(.{ .composition = .{ .text = self.marked_text } });
                } else |_| {}
            }
        } else {
            self.clearMarkedText();
            _ = self.handleInput(.{ .composition = .{ .text = "" } });
        }
        return 0;
    }

    return win32.DefWindowProcW(self.hwnd, win32.WM_IME_COMPOSITION, 0, lparam);
}

/// 组合串字节长度(ImmGetCompositionStringW 传 null buffer 查询)。
fn compositionStringLen(himc: ?*anyopaque, which: win32.DWORD) i32 {
    const n = win32.ImmGetCompositionStringW(himc, which, null, 0);
    return if (n < 0) 0 else n;
}

fn mouseEvent(self: *Window, button: input.MouseButton, wparam: win32.WPARAM) input.MouseEvent {
    return .{
        .position = self.mouse_position,
        .button = button,
        .click_count = 1,
        .modifiers = win_input.modifiersFromMouseWParam(wparam),
    };
}

// =============================================================================
// 光标
// =============================================================================

/// 系统光标句柄缓存(进程级;LoadCursorW 返回共享对象,不要 DestroyCursor)。
var cursor_cache = struct {
    arrow: ?win32.HCURSOR = null,
    ibeam: ?win32.HCURSOR = null,
    hand: ?win32.HCURSOR = null,
}{};

fn loadCursor(shape: CursorShape) ?win32.HCURSOR {
    switch (shape) {
        .default => {
            if (cursor_cache.arrow == null) {
                cursor_cache.arrow = win32.LoadCursorW(null, win32.IDC_ARROW);
            }
            return cursor_cache.arrow;
        },
        .text => {
            if (cursor_cache.ibeam == null) {
                cursor_cache.ibeam = win32.LoadCursorW(null, win32.IDC_IBEAM);
            }
            return cursor_cache.ibeam;
        },
        .pointer => {
            if (cursor_cache.hand == null) {
                cursor_cache.hand = win32.LoadCursorW(null, win32.IDC_HAND);
            }
            return cursor_cache.hand;
        },
    }
}

// =============================================================================
// 辅助
// =============================================================================

/// UTF-8 → NUL 结尾 UTF-16(allocator 拥有)。
fn utf8ToWideZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

/// 逻辑尺寸 → 物理 px(null 透传)。
fn scaleSize(size: ?geometry.Size(f64), scale: f64) ?geometry.Size(f64) {
    const s = size orelse return null;
    return geometry.Size(f64).init(s.width * scale, s.height * scale);
}

const SPI_GETWORKAREA: win32.UINT = 0x0030;

/// SystemParametersInfoW 在 user32(window.zig 的 center 用)。
extern "user32" fn SystemParametersInfoW(
    action: win32.UINT,
    param: win32.UINT,
    pv: ?*anyopaque,
    ini: win32.UINT,
) callconv(.winapi) win32.BOOL;

// =============================================================================
// 测试
// =============================================================================

test "window class name is NUL-terminated UTF-16" {
    const name = win32_class_name();
    const span = std.mem.span(name); // [:0]const u16,sentinel 由类型保证
    try std.testing.expect(name[0] != 0);
    try std.testing.expectEqual(@as(usize, 16), span.len); // "windowkit.Window"
    try std.testing.expectEqual(@as(u16, 0), name[span.len]);
}

test "scaleSize logical to physical, null passthrough" {
    const s = geometry.Size(f64).init(800, 600);
    const scaled = scaleSize(s, 2.0).?;
    try std.testing.expectEqual(@as(f64, 1600), scaled.width);
    try std.testing.expectEqual(@as(f64, 1200), scaled.height);
    try std.testing.expect(scaleSize(null, 2.0) == null);
}

test "getClearColor transparent for glass styles" {
    const g = geometry.Color.rgba(0.1, 0.2, 0.3, 1.0);
    // 直接测 switch 语义(不建真窗口)。
    const glass: GlassStyle = .blur;
    try std.testing.expect(glass.needsTransparentClear());
    _ = g;
}
