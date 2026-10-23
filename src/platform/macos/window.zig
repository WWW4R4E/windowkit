//! macOS 窗口实现，与 vsync 同步的渲染节拍
//!
//! AppKit 窗口 + CVDisplayLink 节拍 + 输入/IME。渲染由依赖方持有：
//! 每个 vsync 通过 `on_render` 回调交给调用方，`CAMetalLayer` 经
//! `nativeHandles()` 交出（窗口层继续同步它的 contentsScale / drawableSize）。

const std = @import("std");
const assert = std.debug.assert;
const Mutex = @import("../mutex.zig").Mutex;
const objc = @import("objc");
const geometry = @import("../../geometry.zig");
const platform = @import("platform.zig");
const input_view = @import("input_view.zig");
const input = @import("../../input/events.zig");
const display_link = @import("display_link.zig");
const appkit = @import("appkit.zig");
const interface_mod = @import("../interface.zig");
const WindowId = interface_mod.WindowId;
const GlassStyle = interface_mod.GlassStyle;
const WindowOptions = interface_mod.WindowOptions;
const native_handles = @import("../native_handles.zig");

const NativeHandles = native_handles.NativeHandles;
const FramebufferSize = native_handles.FramebufferSize;

/// 窗口标题的最大字节数，不含 NUL 终止符。
///
/// 与 Linux 后端上限一致：同一个应用在两个后端都能装下标题。
/// AppKit 本身没有限制，但承载标题的自有存储需要一个明确上限。
pub const title_bytes_max: usize = 255;

const NSRect = appkit.NSRect;
const NSSize = appkit.NSSize;
const DisplayLink = display_link.DisplayLink;

pub const Window = struct {
    allocator: std.mem.Allocator,

    /// 所属平台。保留引用，`deinit` 时可以直接用它把本窗口从注册表撤下，
    /// 调用方不必记得成对操作。
    plat: *platform.MacPlatform,

    ns_window: objc.Object,
    ns_view: objc.Object,
    /// 窗口层创建的 CAMetalLayer：`nativeHandles()` 交出，缩放/DPR 变化时
    /// 由窗口层同步 contentsScale 与 drawableSize；像素格式等配置归依赖方。
    metal_layer: objc.Object,
    display_link: ?DisplayLink,
    size: geometry.Size(f64),
    scale_factor: f64,
    /// NUL 结尾的窗口标题自有存储。
    ///
    /// 曾经是借用切片，`.ptr` 直接传给
    /// `-[NSString stringWithUTF8String:]`。该 API 要求 NUL 结尾的 C 字符串，
    /// 恰好没带终止符的切片会被越界读取；借用指针还可能指向栈缓冲，
    /// 调用方返回后字段就悬垂了。改为固定长度自有存储解决这两个问题，
    /// 与 Linux / 测试后端一致。
    title_buf: [title_bytes_max + 1]u8,
    title_len: u16,
    background_color: geometry.Color,
    needs_render: std.atomic.Value(bool),
    delegate: ?objc.Object = null,

    /// 本窗口在平台 `WindowRegistry` 中的唯一标识。
    /// 由 `init` 分配；`deinit` 重置为 `.invalid`，防止二次销毁时
    /// 注销一个已被重用的 ID。
    window_id: WindowId = .invalid,

    /// 窗口关闭后置位，无论走 `close()` 还是用户点标题栏关闭按钮。
    /// 宿主轮询此标志来移除自己的引用，避免与 delegate 回调竞争。
    closed: bool = false,
    // 玻璃效果支持（macOS 26.0+，不可用时回退模糊）
    glass_effect_view: ?objc.Object = null,
    glass_style: GlassStyle = .none,
    background_opacity: f64 = 1.0,
    glass_corner_radius: f64 = 16.0,

    /// 拖放开关(初始值来自 `options.file_drop`;false 时 dragging Entered/
    /// Updated 回 NSDragOperationNone → 光标显示“不可放下”,不派发事件)。
    file_drop_enabled: bool = true,

    /// 序列化渲染回调与所有其他触碰窗口共享状态的代码：
    /// DisplayLink 线程执行 `on_render` 时持有、`handleResize` 同步渲染时
    /// 持有、主线程分发输入时持有。保护的共享状态是 `size`、`scale_factor`、
    /// `background_color` —— 核心保证：输入回调与渲染回调不并发执行。
    render_mutex: Mutex = .{},

    /// live resize 进行中的标记。
    /// live resize 期间主线程同步渲染，DisplayLink 回调完全跳过渲染。
    in_live_resize: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 置位表示本线程正持 `render_mutex` 执行渲染回调（DisplayLink 线程，
    /// 或 live-resize 中的 `handleResize`）。`os_unfair_lock` 不可递归，
    /// 任何会取这把锁的窗口方法在加锁前必须先查这个标记。
    render_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    benchmark_mode: bool = true,

    /// 当前鼠标位置（每次鼠标事件时更新）
    mouse_position: geometry.Point(f64) = .{ .x = 0, .y = 0 },
    /// 鼠标是否在窗口内
    mouse_inside: bool = false,

    /// 通过 `NSCursor.set()` 应用到 OS 层的最后一个指针图标。缓存了起来，
    /// 使每帧的 `setCursorShape` 调用（见消费方 frame 代码）在悬停元素
    /// 未变化的常见情形下直接短路。
    cursor_shape: ?interface_mod.CursorShape = null,

    // IME（输入法）状态
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,
    pending_key_event: ?objc.c.id = null,
    /// view 坐标系下的 IME 光标矩形（用于候选窗定位）
    ime_cursor_rect: appkit.NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 1, .height = 20 },
    },
    /// NSProcessInfo activity token，防止 ProMotion 降频
    activity_token: ?objc.Object = null,

    // =========================================================================
    // 回调
    // =========================================================================

    /// 输入事件回调。返回 true 表示已处理。
    on_input: ?InputCallback = null,

    /// 每帧渲染回调。
    /// 依赖方在这里录命令并 present；拿不到 renderer 之类的任何窗口层对象——
    /// 只有窗口自己（`nativeHandles()` / `framebufferSize()`）。
    on_render: ?RenderCallback = null,

    /// 窗口即将关闭时调用。返回 false 可阻止关闭。
    on_close: ?CloseCallback = null,

    /// 窗口尺寸变化时调用。
    on_resize: ?ResizeCallback = null,

    /// 输入处理完成、互斥锁释放之后调用。
    /// 适合可能启动嵌套事件循环的操作（如模态对话框）。
    on_post_input: ?PostInputCallback = null,

    /// 回调用用户数据指针
    user_data: ?*anyopaque = null,

    // =========================================================================
    // 便捷访问器（调用方无需自行转换）
    // =========================================================================

    /// 取渲染用的有效清屏色。
    /// 玻璃效果激活时返回透明，让玻璃透出来；
    /// 否则返回配置的背景色。
    pub fn getClearColor(self: *const Self) geometry.Color {
        return switch (self.glass_style) {
            // 无论哪种，framebuffer 都要清成透明，宿主背景才能透出来。
            .blur, .glass_regular, .glass_clear => geometry.Color.transparent,
            .none => self.background_color,
        };
    }

    /// 窗口宽度（逻辑像素）
    pub fn width(self: *const Self) u32 {
        return @intFromFloat(self.size.width);
    }

    /// 窗口高度（逻辑像素）
    pub fn height(self: *const Self) u32 {
        return @intFromFloat(self.size.height);
    }

    // =========================================================================
    // 原生句柄 / 帧缓冲尺寸（依赖方自持渲染）
    // =========================================================================

    /// 交给依赖方的 AppKit 对象。`metal_layer` 是窗口层创建的 CAMetalLayer：
    /// `nextDrawable` / `currentDrawable` 由依赖方自己取，窗口层只负责随
    /// 缩放与 DPR 变化同步 `contentsScale` 和 `drawableSize`。
    ///
    /// 只在窗口存活期内有效：`deinit` 之后对象已 release。
    pub fn nativeHandles(self: *const Self) NativeHandles {
        assert(self.ns_window.value != null);
        assert(self.ns_view.value != null);
        assert(self.metal_layer.value != null);

        return .{ .appkit = .{
            .ns_window = @ptrCast(self.ns_window.value.?),
            .ns_view = @ptrCast(self.ns_view.value.?),
            .metal_layer = @ptrCast(self.metal_layer.value.?),
        } };
    }

    /// 帧缓冲物理像素尺寸 —— 直接读 `CAMetalLayer.drawableSize`，即渲染
    /// 实际使用的后端缓冲，而不是 `size × scale` 的再计算（依赖方若自行
    /// 改过 drawableSize，这里读到的就是真实值）。
    pub fn framebufferSize(self: *const Self) FramebufferSize {
        assert(self.metal_layer.value != null);
        const drawable_size: NSSize = self.metal_layer.msgSend(NSSize, "drawableSize", .{});

        return .{
            .width_px = @intFromFloat(@round(drawable_size.width)),
            .height_px = @intFromFloat(@round(drawable_size.height)),
        };
    }

    // =========================================================================
    // 类型
    // =========================================================================

    /// 输入回调：返回 true 表示事件已处理
    pub const InputCallback = *const fn (*Window, input.InputEvent) bool;

    /// 渲染回调：每帧绘制前调用
    pub const RenderCallback = *const fn (*Window) void;

    /// 关闭回调：窗口即将关闭时调用。返回 false 可阻止关闭。
    pub const CloseCallback = *const fn (*Window) bool;

    /// 尺寸回调：窗口尺寸变化时调用
    pub const ResizeCallback = *const fn (*Window, f64, f64) void;

    /// post-input 回调：输入处理完、互斥锁释放后调用。
    /// 适合会跑嵌套事件循环的操作（模态对话框等）。
    pub const PostInputCallback = *const fn (*Window) void;

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        plat: *platform.MacPlatform,
        options: *const WindowOptions,
    ) !*Self {
        assert(@intFromPtr(plat) != 0);
        assert(options.width >= 1);
        assert(options.height >= 1);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        initFields(self, allocator, plat, options);

        // 先注册进注册表，再碰 AppKit：delegate 和 input view 都会捕获
        // `self`，且下面的 `center` 期间就可能触发回调，所以窗口必须
        // 在那之前就能按 ID 查到。
        self.window_id = try plat.registerWindow(self);
        errdefer plat.unregisterWindow(self.window_id);
        assert(self.window_id.isValid());

        try self.createNSWindow(options);

        // delegate 必须在 ns_view 创建之后再安装，否则早期的 delegate
        // 回调会崩（例如 windowDidChangeBackingProperties 可能在 center()
        // 期间触发，其 handleResize 依赖 ns_view）。
        const window_delegate = @import("window_delegate.zig");
        self.delegate = try window_delegate.create(self);
        self.ns_window.msgSend(void, "setDelegate:", .{self.delegate.?.value});

        // 按需设置玻璃/透明效果
        if (options.background_opacity < 1.0) {
            try self.setupGlassEffect(
                options.glass_style,
                options.background_opacity,
                options.glass_corner_radius,
            );
        }

        // 开启 mouseMoved 追踪
        try self.setupTrackingArea();

        // Metal layer 定尺寸之前必须先拿到 Retina 缩放系数，
        // 否则首帧的 drawable 分辨率不对。
        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});
        assert(self.scale_factor > 0.0);

        try self.setupMetalLayer();

        if (options.use_display_link) try self.startDisplayLink();

        // 窗口置 key 并可见，然后标记首帧渲染。
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        self.requestRender();

        // 新置前的窗口会取得焦点。每个后端都显式发布这一策略——
        // “首个窗口胜出”不该埋在 `WindowRegistry` 里，那曾导致
        // macOS 与 Linux 对 `getActiveWindowId` 的判断不一致。
        plat.setActiveWindowId(self.window_id);

        assert(!self.closed);
        assert(self.plat.getWindow(self.window_id) != null);
        assert(self.plat.getActiveWindowId().? == self.window_id);
        return self;
    }

    /// 在任何 AppKit 对象存在之前把所有字段置于确定状态。
    ///
    /// `noinline` + 出指针初始化：`Window` 带两个 256 字节 IME 缓冲，
    /// 绝不能在调用方栈帧上构造再拷贝。
    noinline fn initFields(
        self: *Self,
        allocator: std.mem.Allocator,
        plat: *platform.MacPlatform,
        options: *const WindowOptions,
    ) void {
        assert(@intFromPtr(self) != 0);
        assert(options.width >= 1);

        // AppKit 句柄（ns_window/ns_view/metal_layer）在 `init` 真正创建
        // 之前保持 `undefined`；早期 delegate 回调可能观察到的所有字段
        // 都在这里初始化。
        self.* = .{
            .allocator = allocator,
            .plat = plat,
            .ns_window = undefined,
            .ns_view = undefined,
            .metal_layer = undefined,
            .display_link = null,
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            // 清零而不从 `options.title` 预填：`init` 在 NSWindow 存在后
            // 调一次 `setTitle`，那是唯一负责拷贝和 NUL 结尾的地方。
            .title_buf = @splat(0),
            .title_len = 0,
            .background_color = options.background_color,
            .needs_render = std.atomic.Value(bool).init(true),
            .glass_style = options.glass_style,
            .background_opacity = options.background_opacity,
            .glass_corner_radius = options.glass_corner_radius,
            .file_drop_enabled = options.file_drop,
        };

        assert(self.window_id == .invalid);
        assert(!self.closed);
    }

    /// 创建并配置 `NSWindow` 与内容 view。
    ///
    /// 从 `init` 拆出来控制行数。顺序很关键：内容 view 必须先于 delegate
    /// 安装而存在，因为 delegate 回调会解引用它。
    fn createNSWindow(self: *Self, options: *const WindowOptions) !void {
        assert(options.width >= 1);
        assert(options.height >= 1);

        const NSWindow = objc.getClass("NSWindow") orelse return error.ClassNotFound;

        // Titled | closable | miniaturizable | resizable。
        const style_mask: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);

        const content_rect = NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = options.width, .height = options.height },
        };

        const window_alloc = NSWindow.msgSend(objc.Object, "alloc", .{});
        self.ns_window = window_alloc.msgSend(
            objc.Object,
            "initWithContentRect:styleMask:backing:defer:",
            .{
                content_rect,
                style_mask,
                @as(u64, 2), // NSBackingStoreBuffered
                false,
            },
        );
        if (self.ns_window.value == null) return error.WindowCreationFailed;

        if (options.titlebar_transparent) {
            self.ns_window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
        }

        // 内容延伸到标题栏下，实现全幅效果。
        if (options.full_size_content) {
            const current_mask = self.ns_window.msgSend(u64, "styleMask", .{});
            const full_size_content_mask: u64 = 1 << 15; // NSWindowStyleMaskFullSizeContentView
            self.ns_window.msgSend(void, "setStyleMask:", .{current_mask | full_size_content_mask});
        }

        self.setTitle(options.title);

        if (options.min_size) |min| {
            self.ns_window.msgSend(void, "setMinSize:", .{
                NSSize{ .width = min.width, .height = min.height },
            });
        }

        if (options.max_size) |max| {
            self.ns_window.msgSend(void, "setMaxSize:", .{
                NSSize{ .width = max.width, .height = max.height },
            });
        }

        if (options.centered) {
            self.ns_window.msgSend(void, "center", .{});
        }

        const view_frame: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        self.ns_view = try input_view.create(view_frame, self);
        self.ns_window.msgSend(void, "setContentView:", .{self.ns_view.value});
        assert(self.ns_view.value != null);
    }

    /// 启动 CVDisplayLink，使渲染与 vsync 同节拍。
    fn startDisplayLink(self: *Self) !void {
        assert(self.display_link == null);
        assert(self.activity_token == null);

        self.display_link = try DisplayLink.init();
        errdefer {
            self.display_link.?.deinit();
            self.display_link = null;
        }

        try self.display_link.?.setCallback(displayLinkCallback, @ptrCast(self));
        try self.display_link.?.start();

        const refresh_rate = self.display_link.?.getRefreshRate();
        std.debug.print("DisplayLink started at {d:.1}Hz\n", .{refresh_rate});

        // 未声明对延迟敏感时，macOS 会把 ProMotion 面板从 120Hz 节流到 60Hz。
        self.activity_token = beginHighPerformanceActivity();
        assert(self.display_link != null);
    }

    // =========================================================================
    // 回调设置器
    // =========================================================================

    /// 设置输入回调。`null` 表示清除。
    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        assert(self.window_id.isValid());
        self.on_input = callback;
        assert((self.on_input == null) == (callback == null));
    }

    /// 设置渲染回调。`null` 表示清除。
    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        assert(self.window_id.isValid());
        self.on_render = callback;
        assert((self.on_render == null) == (callback == null));
    }

    /// 设置关闭回调。回调返回 false 可阻止窗口关闭。
    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        assert(self.window_id.isValid());
        self.on_close = callback;
        assert((self.on_close == null) == (callback == null));
    }

    /// 设置尺寸回调。`null` 表示清除。
    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        assert(self.window_id.isValid());
        self.on_resize = callback;
        assert((self.on_resize == null) == (callback == null));
    }

    /// 设置 post-input 回调（互斥锁释放后调用）。`null` 表示清除。
    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        assert(self.window_id.isValid());
        self.on_post_input = callback;
        assert((self.on_post_input == null) == (callback == null));
    }

    /// 设置用户数据指针
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        assert(self.window_id.isValid());
        self.user_data = data;
        assert((self.user_data == null) == (data == null));
    }

    /// 取用户数据指针
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }

    /// 取本窗口所在显示器的 backing 缩放系数。
    ///
    /// 统一用 `f64`：平台原生的精度差异不再挤进共享调用方。
    pub fn getScaleFactor(self: *const Self) f64 {
        assert(self.scale_factor > 0.0);
        assert(self.scale_factor <= 8.0);
        return self.scale_factor;
    }

    // =========================================================================
    // IME 支持
    // =========================================================================

    /// 为 IME 设置 marked（合成中）文本
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        if (text.len > self.marked_text_buffer.len) {
            @memcpy(self.marked_text_buffer[0..], text[0..self.marked_text_buffer.len]);
            self.marked_text = self.marked_text_buffer[0..self.marked_text_buffer.len];
        } else {
            @memcpy(self.marked_text_buffer[0..text.len], text);
            self.marked_text = self.marked_text_buffer[0..text.len];
        }
    }

    /// 清除 marked 文本（合成结束或取消）
    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    /// 为 IME 设置上屏文本（拷贝进窗口自有缓冲）
    pub fn setInsertedText(self: *Self, text: []const u8) void {
        if (text.len > self.inserted_text_buffer.len) {
            @memcpy(self.inserted_text_buffer[0..], text[0..self.inserted_text_buffer.len]);
            self.inserted_text = self.inserted_text_buffer[0..self.inserted_text_buffer.len];
        } else {
            @memcpy(self.inserted_text_buffer[0..text.len], text);
            self.inserted_text = self.inserted_text_buffer[0..text.len];
        }
    }

    /// 设置 IME 光标矩形（渲染时由 TextInput 调用）
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        self.ime_cursor_rect = .{
            .origin = .{ .x = @floatCast(x), .y = @floatCast(y) },
            .size = .{ .width = @floatCast(w), .height = @floatCast(h) },
        };
    }

    /// 是否有活跃的 IME 合成
    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    // =========================================================================
    // 输入处理
    // =========================================================================
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        // 跟踪鼠标位置
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
            // 持 render_mutex 分发输入：DisplayLink 线程可能正在执行应用的
            // 渲染回调（同样持锁），两边都要碰窗口共享状态（size/背景色），
            // 锁保证输入回调与渲染回调不并发执行——应用自己的数据也因此
            // 不需要在两个回调之间额外加锁。
            self.render_mutex.lock();
            handled = callback(self, event);
            self.render_mutex.unlock();

            // 互斥锁释放之后再调 post-input 回调——
            // 这才是嵌套事件循环（模态对话框）安全运行的时机。
            if (self.on_post_input) |post_callback| {
                post_callback(self);
            }
        }
        self.requestRender();
        return handled;
    }

    /// 当前鼠标位置
    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return self.mouse_position;
    }

    /// 鼠标是否在窗口内
    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    /// 取本窗口的唯一标识。
    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    /// 本窗口所属的平台。
    ///
    /// 契约固定这一访问点，共享代码取宿主时不用拼每个后端的字段名 ——
    /// 本后端存 `plat`，其余后端存 `platform`。见 `contract.verifyWindowLifecycle`。
    pub fn getPlatform(self: *Self) *platform.MacPlatform {
        assert(@intFromPtr(self.plat) != 0);
        return self.plat;
    }

    // =========================================================================
    // 窗口生命周期
    // =========================================================================

    pub fn deinit(self: *Self) void {
        assert(self.ns_window.value != null);

        // 先从注册表撤下，AppKit 对象销毁期间谁也查不到这个窗口。
        // 之后置 `.invalid`，二次 `deinit` 变成 no-op 而不是注销旧 ID。
        if (self.window_id.isValid()) {
            self.plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        assert(!self.window_id.isValid());

        self.closed = true;

        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.release();
        }
        // 清理玻璃效果 view
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            self.glass_effect_view = null;
        }

        // 关闭 DisplayLink 之前结束高性能 activity
        if (self.activity_token) |token| {
            endHighPerformanceActivity(token);
            self.activity_token = null;
        }

        if (self.display_link) |*dl| {
            dl.deinit();
        }
        // 依赖方必须在窗口 deinit 前销毁自己的渲染资源（CAMetalLayer /
        // drawable 引用本窗口的 NSView），这里只关窗口对象。
        self.ns_window.msgSend(void, "close", .{});
        self.allocator.destroy(self);
    }

    /// delegate 触发的窗口尺寸变化
    pub fn handleResize(self: *Self) void {
        const old_width = self.size.width;
        const old_height = self.size.height;
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const new_width = bounds.size.width;
        const new_height = bounds.size.height;

        if (new_width < 1 or new_height < 1) {
            return;
        }

        const new_scale = self.ns_window.msgSend(f64, "backingScaleFactor", .{});

        if (new_width == self.size.width and
            new_height == self.size.height and
            new_scale == self.scale_factor)
        {
            return;
        }

        // 取 render 互斥锁，DisplayLink 线程可能正在读 size/scale。
        self.render_mutex.lock();
        defer self.render_mutex.unlock();

        // 持锁期间置渲染进行中标记：下面的同步渲染会调 on_render 回调，
        // 回调里任何再取这把锁的窗口方法必须先查 `render_in_progress`，
        // 因为 `os_unfair_lock` 不可递归。
        self.render_in_progress.store(true, .release);
        defer self.render_in_progress.store(false, .release);

        self.size.width = new_width;
        self.size.height = new_height;
        self.scale_factor = new_scale;

        self.metal_layer.msgSend(void, "setContentsScale:", .{new_scale});

        // drawableSize 由窗口层同步：CAMetalLayer 是窗口层创建并经
        // `nativeHandles()` 暴露出去的，依赖方只管取 drawable。
        const drawable_size = NSSize{
            .width = new_width * new_scale,
            .height = new_height * new_scale,
        };
        self.metal_layer.msgSend(void, "setDrawableSize:", .{drawable_size});

        self.requestRender();

        // 尺寸真的变了才通知调用方
        const size_changed = (old_width != new_width or old_height != new_height);
        if (size_changed) {
            if (self.on_resize) |callback| {
                callback(self, new_width, new_height);
            }
        }

        // live resize 期间要保证视觉平滑，同步渲染：
        // DisplayLink 在 live-resize 期间被跳过（见 `displayLinkCallback`），
        // 所以这里同步派发 on_render —— 依赖方在此重建 swapchain/渲染目标。
        if (self.in_live_resize.load(.acquire)) {
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();

            if (self.on_render) |callback| {
                callback(self);
            }
        }
    }

    /// 处理关闭请求。返回 true 可以继续关，false 取消。
    pub fn handleClose(self: *Self) bool {
        // 先调用户回调 —— 返回 false 即可阻止关闭
        if (self.on_close) |callback| {
            if (!callback(self)) {
                return false; // 用户阻止了关闭
            }
        }

        // 继续关闭流程。
        if (self.display_link) |*dl| {
            dl.stop();
        }
        self.closed = true;
        assert(self.isClosed());
        return true;
    }

    pub fn handleFocusChange(self: *Self, focused: bool) void {
        _ = focused;
        self.requestRender();
    }

    pub fn handleLiveResizeStart(self: *Self) void {
        self.in_live_resize.store(true, .release);
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{true});
    }

    pub fn handleLiveResizeEnd(self: *Self) void {
        self.in_live_resize.store(false, .release);
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{false});
        self.requestRender();
    }

    pub fn isInLiveResize(self: *const Self) bool {
        return self.in_live_resize.load(.acquire);
    }

    // =========================================================================
    // 窗口操作
    // =========================================================================

    /// 聚焦本窗口（置前并设为 key window）。
    pub fn focus(self: *Self) void {
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
    }

    /// 程序化关闭本窗口。
    ///
    /// 会走关闭回调，回调可否决。之后窗口被销毁。
    pub fn close(self: *Self) void {
        assert(self.ns_window.value != null);
        if (self.closed) return;

        // `performClose:` 会经 `windowShouldClose:`，所以关闭回调仍有
        // 否决机会；`closed` 在 `handleClose` 里、否决被驳回后才置位。
        self.ns_window.msgSend(void, "performClose:", .{@as(?*anyopaque, null)});
    }

    /// 关闭流程是否已走完。
    pub fn isClosed(self: *const Self) bool {
        assert(self.ns_window.value != null);
        // 未关闭的窗口必然还在注册；注销只发生在关闭之后的 `deinit`。
        if (!self.closed) assert(self.window_id.isValid());
        return self.closed;
    }

    // =========================================================================
    // 渲染
    // =========================================================================

    /// 请求在下个 vsync 渲染
    pub fn requestRender(self: *Self) void {
        self.needs_render.store(true, .release);
    }

    /// 手动渲染（DisplayLink 关闭时用）
    ///
    /// 同步派发一次 `on_render`。与 DisplayLink 路径同一条契约：渲染回调
    /// 持 `render_mutex` 执行；回调内重入（已持锁）时直接派发，
    /// 因为 `os_unfair_lock` 不可递归。
    pub fn render(self: *Self) void {
        if (self.closed) return;

        if (self.render_in_progress.load(.acquire)) {
            if (self.on_render) |callback| callback(self);
            return;
        }

        self.render_mutex.lock();
        defer self.render_mutex.unlock();
        self.render_in_progress.store(true, .release);
        defer self.render_in_progress.store(false, .release);

        if (self.on_render) |callback| callback(self);
    }

    /// 运行时开关文件拖放(初始值来自 `options.file_drop`)。
    pub fn setFileDropEnabled(self: *Self, enabled: bool) void {
        self.file_drop_enabled = enabled;
    }

    pub fn setTitle(self: *Self, new_title: []const u8) void {
        assert(self.ns_window.value != null);
        assert(self.title_buf.len == title_bytes_max + 1);

        // 截断而非报错：超长标题只是显示问题，AppKit 本来也会截断显示。
        // Debug 下断言兜底，release 下靠截断保证拷贝不越界。
        assert(new_title.len <= title_bytes_max);
        const len = @min(new_title.len, title_bytes_max);

        @memcpy(self.title_buf[0..len], new_title[0..len]);

        // 清零整个尾部而不只写终止符：缓冲会被多次 `setTitle` 复用，
        // 不清尾的话上一个标题的字节会留在 NUL 之后可读。
        @memset(self.title_buf[len..], 0);
        self.title_len = @intCast(len);

        assert(self.title_buf[self.title_len] == 0);

        const NSString = objc.getClass("NSString") orelse return;
        const ns_title = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*:0]const u8, @ptrCast(&self.title_buf))},
        );

        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    /// 当前标题，借用窗口自有存储。
    pub fn title(self: *const Self) []const u8 {
        assert(self.title_len <= title_bytes_max);
        return self.title_buf[0..self.title_len];
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
    }

    /// 设置标题栏/系统 UI 的显示模式（亮色或暗色）。
    pub fn setAppearance(self: *Self, dark: bool) void {
        const NSAppearance = objc.getClass("NSAppearance") orelse return;
        const NSString = objc.getClass("NSString") orelse return;

        // 亮色用 NSAppearanceNameAqua，暗色用 NSAppearanceNameDarkAqua；
        // 从 NUL 结尾的 C 字符串字面量构造 NSString
        const appearance_name: [*:0]const u8 =
            if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua";
        const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{appearance_name});
        const appearance_ptr =
            NSAppearance.msgSend(?*anyopaque, "appearanceNamed:", .{ns_name.value});

        if (appearance_ptr) |ptr| {
            const appearance = objc.Object.fromId(ptr);
            self.ns_window.msgSend(void, "setAppearance:", .{appearance.value});
        }
    }

    /// 设置 OS 层鼠标指针图标（不是 `TextInput` 绘制的文本光标，
    /// 见 `interface.CursorShape`）。
    ///
    /// `NSCursor.set()` 是压栈语义而非直接替换，但消费方每帧传入的是
    /// 完全解析后的 shape（与 Linux `wp_cursor_shape_manager_v1` 路径
    /// 同构），且本层带形态缓存去重，因此同时最多只有一个自有的
    /// cursor 在栈上。
    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.ns_window.value != null);
        std.debug.assert(self.ns_view.value != null);
        if (self.cursor_shape) |current| {
            if (current == shape) return;
        }

        const NSCursor = objc.getClass("NSCursor") orelse return;
        const cursor = switch (shape) {
            .default => NSCursor.msgSend(objc.Object, "arrowCursor", .{}),
            .text => NSCursor.msgSend(objc.Object, "IBeamCursor", .{}),
            .pointer => NSCursor.msgSend(objc.Object, "pointingHandCursor", .{}),
        };
        std.debug.assert(cursor.value != null);

        cursor.msgSend(void, "set", .{});
        self.cursor_shape = shape;
    }

    /// 运行时切换玻璃效果样式。
    pub fn setGlassStyle(self: *Self, style: GlassStyle, opacity: f64, corner_radius: f64) void {
        assert(self.ns_window.value != null);
        assert(opacity >= 0.0 and opacity <= 1.0);
        assert(corner_radius >= 0.0);

        // 先移除已有的玻璃效果
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            self.glass_effect_view = null;
        }

        // 更新保存的值
        self.glass_style = style;
        self.background_opacity = opacity;
        self.glass_corner_radius = corner_radius;

        if (style == .none) {
            // 恢复不透明窗口
            self.ns_window.msgSend(void, "setOpaque:", .{true});
            const NSColor = objc.getClass("NSColor") orelse return;
            const bg = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
                @as(f64, self.background_color.r),
                @as(f64, self.background_color.g),
                @as(f64, self.background_color.b),
                @as(f64, 1.0),
            });
            self.ns_window.msgSend(void, "setBackgroundColor:", .{bg.value});
        } else {
            // 窗口改为非不透明
            self.ns_window.msgSend(void, "setOpaque:", .{false});

            // 背景色设成近乎透明
            const NSColor = objc.getClass("NSColor") orelse return;
            const transparent_bg = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
                @as(f64, 1.0),
                @as(f64, 1.0),
                @as(f64, 1.0),
                @as(f64, 0.001),
            });
            self.ns_window.msgSend(void, "setBackgroundColor:", .{transparent_bg.value});

            // 应用新玻璃效果。
            switch (style) {
                .glass_regular, .glass_clear => {
                    if (!self.setupLiquidGlass(style, corner_radius)) {
                        self.setupTraditionalBlur();
                    }
                },
                .blur => self.setupTraditionalBlur(),
                .none => unreachable,
            }
        }

        self.requestRender();
    }

    // =========================================================================
    // 私有辅助函数
    // =========================================================================

    fn setupTrackingArea(self: *Self) !void {
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const NSTrackingArea = objc.getClass("NSTrackingArea") orelse return error.ClassNotFound;

        const opts = appkit.NSTrackingAreaOptions;
        const options = opts.mouse_moved |
            opts.mouse_entered_and_exited |
            opts.active_in_key_window |
            opts.in_visible_rect;

        const tracking_area = NSTrackingArea.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
            bounds,
            options,
            self.ns_view.value,
            @as(objc.c.id, @ptrFromInt(0)),
        });

        self.ns_view.msgSend(void, "addTrackingArea:", .{tracking_area.value});
    }

    fn setupMetalLayer(self: *Self) !void {
        const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ClassNotFound;
        self.metal_layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});

        // 配置 layer。
        // 80 = MTLPixelFormatBGRA8Unorm。
        self.metal_layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)});
        self.metal_layer.msgSend(void, "setContentsScale:", .{self.scale_factor});
        self.metal_layer.msgSend(void, "setDisplaySyncEnabled:", .{false});
        self.metal_layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, 3)});

        // Metal layer 允许透明穿透
        self.metal_layer.msgSend(void, "setOpaque:", .{false});

        self.ns_view.msgSend(void, "setWantsLayer:", .{true});
        self.ns_view.msgSend(void, "setLayer:", .{self.metal_layer});

        const drawable_size = NSSize{
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
        };
        self.metal_layer.msgSend(void, "setDrawableSize:", .{drawable_size});
    }

    fn setupGlassEffect(self: *Self, style: GlassStyle, opacity: f64, corner_radius: f64) !void {
        _ = opacity; // 透明度由玻璃层 tint 决定，不靠窗口背景
        assert(self.ns_window.value != null);
        assert(corner_radius >= 0.0);
        if (style == .none) return;

        // 窗口改为非不透明，让透明色生效
        self.ns_window.msgSend(void, "setOpaque:", .{false});

        // 窗口背景设成近乎透明；
        // 真正的视觉背景由玻璃效果提供
        const NSColor = objc.getClass("NSColor") orelse return error.ClassNotFound;
        const transparent_bg = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
            @as(f64, 1.0),
            @as(f64, 1.0),
            @as(f64, 1.0),
            @as(f64, 0.001), // 近乎透明，玻璃效果透出来
        });
        self.ns_window.msgSend(void, "setBackgroundColor:", .{transparent_bg.value});

        // 优先尝试 liquid glass（macOS 26.0+），不可用则回退传统模糊
        switch (style) {
            .glass_regular, .glass_clear => {
                if (!self.setupLiquidGlass(style, corner_radius)) {
                    // liquid glass 不可用，回退传统模糊
                    self.setupTraditionalBlur();
                }
            },
            .blur => {
                self.setupTraditionalBlur();
            },
            .none => unreachable, // 前面已返回。
        }
    }

    fn setupLiquidGlass(self: *Self, style: GlassStyle, corner_radius: f64) bool {
        assert(style == .glass_regular or style == .glass_clear);
        assert(corner_radius >= 0.0);

        // NSGlassEffectView 仅 macOS 26.0+（Tahoe）可用
        const NSGlassEffectView = objc.getClass("NSGlassEffectView") orelse {
            std.debug.print("NSGlassEffectView not available (requires macOS 26.0+)\n", .{});
            return false;
        };

        // 取内容 view 的 superview（窗口的内容容器）
        const content_view: objc.Object = self.ns_window.msgSend(objc.Object, "contentView", .{});
        const superview: objc.Object = content_view.msgSend(objc.Object, "superview", .{});
        if (superview.value == null) {
            std.debug.print("Could not get content view superview for glass effect\n", .{});
            return false;
        }

        const bounds: NSRect = superview.msgSend(NSRect, "bounds", .{});

        // 创建并配置玻璃效果 view
        const glass_alloc = NSGlassEffectView.msgSend(objc.Object, "alloc", .{});
        const glass_view = glass_alloc.msgSend(objc.Object, "initWithFrame:", .{bounds});

        // style：0 = regular，1 = clear
        const style_value: i64 = switch (style) {
            .glass_regular => 0,
            .glass_clear => 1,
            else => 0,
        };
        glass_view.msgSend(void, "setStyle:", .{style_value});

        // 设置圆角
        glass_view.msgSend(void, "setCornerRadius:", .{corner_radius});

        // 根据 background_color 和 opacity 计算 tint。
        // background_color 全透明时（默认），用深灰兜底。
        const NSColor = objc.getClass("NSColor") orelse return false;

        // 计算有效 tint：RGB 来自 background_color，alpha 用 background_opacity；
        // 颜色全透明（默认）时 RGB 兜底深灰
        const tint_r: f64 = if (self.background_color.a > 0.001) self.background_color.r else 0.1;
        const tint_g: f64 = if (self.background_color.a > 0.001) self.background_color.g else 0.1;
        const tint_b: f64 = if (self.background_color.a > 0.001) self.background_color.b else 0.1;
        const tint_a: f64 = @max(0.001, self.background_opacity); // 保证一点最小不透明度

        const tint_color = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
            tint_r,
            tint_g,
            tint_b,
            tint_a,
        });
        glass_view.msgSend(void, "setTintColor:", .{tint_color.value});

        // 自动随窗口缩放铺满。
        // NSViewWidthSizable | NSViewHeightSizable = 2 | 16 = 18
        glass_view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 18)});

        // 放到内容 view 的下面一层。
        // NSWindowBelow = -1
        superview.msgSend(void, "addSubview:positioned:relativeTo:", .{
            glass_view.value,
            @as(i64, -1), // NSWindowBelow
            content_view.value,
        });

        self.glass_effect_view = glass_view;
        std.debug.print(
            "Liquid glass enabled (style: {}, tint: rgba({d:.2},{d:.2},{d:.2},{d:.2}))\n",
            .{ style, tint_r, tint_g, tint_b, tint_a },
        );
        return true;
    }

    fn setupTraditionalBlur(self: *Self) void {
        // 使用私有 CGS API 做背景模糊（Terminal.app、Ghostty 同款），
        // 可用 macOS 版本范围更广
        const window_number = self.ns_window.msgSend(usize, "windowNumber", .{});
        const blur_radius: c_int = 20; // 合理的默认模糊半径

        const result = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            window_number,
            blur_radius,
        );

        if (result == 0) {
            std.debug.print("Traditional background blur enabled (radius: {})\n", .{blur_radius});
        } else {
            std.debug.print("Failed to enable background blur (error: {})\n", .{result});
        }
    }

    // 私有 CoreGraphics 接口：背景模糊（Terminal.app、Ghostty 等使用）
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;
};

// =============================================================================
// DisplayLink 回调
// =============================================================================

/// CVDisplayLink 回调 —— 跑在高优先级后台线程。
///
/// 线程安全：该回调运行在 CVDisplayLink 线程上，而非主线程；
/// 对窗口共享状态的一切访问必须经 render_mutex 同步。
///
/// render_mutex 保护：size、scale_factor、background_color。
/// on_render 回调在持锁状态下调用，防止竞争。
fn displayLinkCallback(
    dl: display_link.CVDisplayLinkRef,
    in_now: *const display_link.CVTimeStamp,
    in_output_time: *const display_link.CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) display_link.CVReturn {
    _ = dl;
    _ = in_now;
    _ = in_output_time;
    _ = flags_in;
    _ = flags_out;

    const window: *Window = @ptrCast(@alignCast(user_info orelse return .success));

    // live resize 期间跳过渲染
    if (window.in_live_resize.load(.acquire)) {
        return .success;
    }

    // `benchmark_mode`（默认 true）等价于"每 vsync 都渲染"，与 Linux 的
    // `continuous_render` 同为连续渲染默认；`requestRender` 是显式驱动。
    const explicit_render = window.needs_render.swap(false, .acq_rel);
    const should_render = window.benchmark_mode or explicit_render;

    // DEBUG：统计回调频次。CVDisplayLink 回调跑在专用 vsync 线程上，
    // 那里没有持有 `*Window` 以外的东西，这里直接用单线程全局 `Io` ——
    // 与渲染互斥锁同一个逃生通道。`std.Io` 是一组指向进程级 vtable 的
    // 指针，无分配无开销。
    const static = struct {
        var count: u32 = 0;
        var last_print_ms: i64 = 0;
    };
    static.count += 1;
    const dl_io = std.Io.Threaded.global_single_threaded.io();
    const now_ms = std.Io.Timestamp.now(dl_io, .awake).toMilliseconds();
    if (now_ms - static.last_print_ms > 1000) {
        // 需要时取消注释追踪回调频率:
        // std.debug.print(
        //     "DisplayLink callbacks/sec: {}, should_render: {}, explicit: {}\n",
        //     .{ static.count, should_render, explicit_render },
        // );
        static.count = 0;
        static.last_print_ms = now_ms;
    }

    if (!should_render) {
        return .success;
    }

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // 获取渲染互斥锁，保证对全部渲染状态的线程安全访问
    window.render_mutex.lock();
    defer window.render_mutex.unlock();

    // 置渲染进行中标记
    window.render_in_progress.store(true, .release);
    defer window.render_in_progress.store(false, .release);

    // 调用依赖方的渲染回调：录制命令与 present 都归它。
    // 注意：持锁状态下调用，回调不得调用任何会再取该锁的 Window 方法。
    if (window.on_render) |callback| {
        callback(window);
    }

    // 派发完渲染回调即返回：绘制与呈现归依赖方（凭 `nativeHandles()` 的
    // CAMetalLayer 取 drawable），窗口层只负责节拍与线程安全。
    return .success;
}

// =============================================================================
// 辅助函数
// =============================================================================

// =============================================================================
// 高性能 activity（防止 ProMotion 降频）
// =============================================================================

/// 开启高性能 activity，阻止 macOS 在 ProMotion 显示器上节流刷新率
fn beginHighPerformanceActivity() ?objc.Object {
    const NSProcessInfo = objc.getClass("NSProcessInfo") orelse return null;
    const process_info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});

    // NSActivityLatencyCritical (0xFF00000000) | NSActivityUserInitiated (0x00FFFFFF)
    // 该组合告诉 macOS 本进程需要低延迟、高优先级渲染
    const activity_options: u64 = 0xFF00000000 | 0x00FFFFFF;

    const NSString = objc.getClass("NSString") orelse return null;
    const reason = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*:0]const u8, "High frame rate rendering")},
    );

    const token = process_info.msgSend(
        objc.Object,
        "beginActivityWithOptions:reason:",
        .{ activity_options, reason }, // 直接传 `reason`，而非 `reason.value`
    );

    if (token.value == null) {
        std.debug.print("WARNING: activity token null; ProMotion throttling not prevented\n", .{});
        return null;
    }

    // token 以 autoreleased 返回，这里 retain 住
    _ = token.msgSend(objc.Object, "retain", .{});
    std.debug.print("High-performance activity started (ProMotion throttle prevention)\n", .{});
    return token;
}

/// 结束高性能 activity
fn endHighPerformanceActivity(token: objc.Object) void {
    const NSProcessInfo = objc.getClass("NSProcessInfo") orelse return;
    const process_info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});
    process_info.msgSend(void, "endActivity:", .{token.value});
}
