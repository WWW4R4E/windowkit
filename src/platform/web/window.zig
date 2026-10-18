//! WebWindow — 基于浏览器 canvas 的 `PlatformWindow`。
//!
//! 浏览器就是窗口管理器：只有一个 canvas，脚本关不掉它，帧经
//! `requestAnimationFrame` 到达。因此下面的每个方法要么转发到某个
//! JS 导入，要么记录窗口自己可观察的状态。它不能做的是把调用方的
//! 意图默默丢掉——本文件的旧版有十三个空方法体和五个 `anytype`
//! setter，导致共享边界漂移，`getScaleFactor` 曾在这里返回
//! `f32`、别处却是 `f64`。

const std = @import("std");
const imports = @import("imports.zig");
const geometry = @import("../../geometry.zig");
const input = @import("../../input/mod.zig");
const composition_buffer = @import("composition_buffer.zig");
const interface = @import("../interface.zig");
const platform_mod = @import("platform.zig");
const native_handles = @import("../native_handles.zig");

const NativeHandles = native_handles.NativeHandles;
const FramebufferSize = native_handles.FramebufferSize;

const WindowId = interface.WindowId;
const WebPlatform = platform_mod.WebPlatform;

pub const WebWindow = struct {
    allocator: std.mem.Allocator,

    /// 持有的平台对象。留着它，`deinit` 就能自己注销，调用方不必
    /// 记得是哪个注册表发的 `window_id`。
    platform: *WebPlatform,

    /// CSS 像素表示的逻辑 canvas 尺寸，由 `updateSize` 刷新。
    size: geometry.Size(f64),

    /// `devicePixelRatio`，保持宿主的原始宽度：JS `Number` 本就是
    /// IEEE-754 双精度，契约又是 `f64`，这条路径上不做任何转换。
    scale_factor: f64,

    background_color: geometry.Color,
    background_opacity: f64,
    glass_style: interface.GlassStyle,
    glass_corner_radius: f64,

    /// 请求过的光标。目前没有能应用它的 JS 导入，所以记录而不是丢弃；
    /// 见 `setCursorShape`。
    cursor_shape: interface.CursorShape,

    /// 应用是否要求深色外观。web 没有宿主级外观开关可推送；
    /// 见 `setAppearance`。
    dark_appearance: bool,

    /// 框架上一次交来的 preedit 字节长度。web 上这些字节没有宿主去处
    /// （浏览器的隐藏输入框持有 IME 缓冲），但长度正是 `hasMarkedText`
    /// 要上报的内容。
    marked_text_len: u32,

    closed: bool,

    /// 宿主回调。web 的帧循环目前直接排空 JS 环形缓冲，没人调用这些
    /// 回调，所以现在存下来不改变任何行为。仍然存是因为"收下回调再
    /// 丢弃"是对调用方意图的沉默背离；而且将来统一事件路径时可以直接
    /// 复用原生后端同样的接线，不动调用点。
    on_input: ?InputCallback = null,
    on_render: ?RenderCallback = null,
    on_close: ?CloseCallback = null,
    on_resize: ?ResizeCallback = null,
    on_post_input: ?PostInputCallback = null,

    user_data: ?*anyopaque = null,

    /// 本窗口在平台 `WindowRegistry` 中的唯一标识。
    window_id: WindowId = .invalid,

    const Self = @This();

    // =========================================================================
    // 回调类型
    // =========================================================================

    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;
    pub const RenderCallback = *const fn (*Self) void;
    pub const CloseCallback = *const fn (*Self) bool;
    pub const ResizeCallback = *const fn (*Self, f64, f64) void;
    pub const PostInputCallback = *const fn (*Self) void;

    // =========================================================================
    // 生命周期
    // =========================================================================

    /// 创建窗口并注册到 `plat`。
    ///
    /// `options` 以 const 指针跨边界：结构体远超按值传递的 16 字节
    /// 阈值，而 WASM 的栈只有 1 MiB，得护着。
    pub fn init(
        allocator: std.mem.Allocator,
        plat: *WebPlatform,
        options: *const interface.WindowOptions,
    ) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);
        std.debug.assert(options.background_opacity >= 0.0);
        std.debug.assert(options.background_opacity <= 1.0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.platform = plat;
        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = 1.0;
        self.background_color = options.background_color;
        self.background_opacity = options.background_opacity;
        self.glass_style = options.glass_style;
        self.glass_corner_radius = options.glass_corner_radius;
        self.cursor_shape = .default;
        self.dark_appearance = false;
        self.marked_text_len = 0;
        self.closed = false;
        self.on_input = null;
        self.on_render = null;
        self.on_close = null;
        self.on_resize = null;
        self.on_post_input = null;
        self.user_data = null;
        self.window_id = .invalid;

        // WASM 启动时 canvas 已经存在，所以直接采用它的真实尺寸，
        // 而不是按请求尺寸先渲染一帧。
        self.updateSize();
        self.setTitle(options.title);

        // 注册放最后：它把 `self` 发布到注册表，所以每个字段此时都
        // 必须已是最终值。
        self.window_id = try plat.registerWindow(self);

        // 单一的 canvas 永远是聚焦 surface，但仍然显式发布：每个后端
        // 都用一行可见代码声明这条策略，而不是从 `WindowRegistry`
        // 继承隐式的"先注册者得焦点"——那曾让各后端对
        // `getActiveWindowId` 的答案不一致。
        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(!self.closed);
        std.debug.assert(plat.getActiveWindowId().? == self.window_id);
        return self;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.window_id.isValid());

        self.platform.unregisterWindow(self.window_id);
        self.window_id = .invalid;

        std.debug.assert(!self.window_id.isValid());
        self.allocator.destroy(self);
    }

    // =========================================================================
    // 标识
    // =========================================================================

    /// 拥有本窗口的平台。
    ///
    /// 契约钉死的方法，让共享代码能拿到宿主而不必拼每个后端的字段名；
    /// 见 `contract.verifyWindowLifecycle`。
    pub fn getPlatform(self: *Self) *WebPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn getWindowId(self: *const Self) WindowId {
        std.debug.assert(!self.closed or self.window_id.isValid());
        return self.window_id;
    }

    // =========================================================================
    // 几何
    // =========================================================================

    /// 向宿主重读 canvas 尺寸与 DPI。
    ///
    /// 仅 Web 需要此轮询：原生后端靠宿主事件得知 resize，
    /// 浏览器则约定每帧轮询一次。
    pub fn updateSize(self: *Self) void {
        const canvas_width = imports.getCanvasWidth();
        const canvas_height = imports.getCanvasHeight();
        std.debug.assert(canvas_width <= size_px_max);
        std.debug.assert(canvas_height <= size_px_max);

        self.size.width = @floatFromInt(canvas_width);
        self.size.height = @floatFromInt(canvas_height);

        // 宿主报 0 或负值就是谎报；退回 1.0，
        // 免得一个负刻度传下去除出无穷。
        const ratio: f64 = imports.getDevicePixelRatio();
        self.scale_factor = if (ratio > 0.0) ratio else 1.0;

        std.debug.assert(self.scale_factor > 0.0);
    }

    pub fn width(self: *const Self) u32 {
        std.debug.assert(self.size.width >= 0.0);
        std.debug.assert(self.size.width <= @as(f64, size_px_max));
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        std.debug.assert(self.size.height >= 0.0);
        std.debug.assert(self.size.height <= @as(f64, size_px_max));
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        std.debug.assert(self.size.width >= 0.0);
        std.debug.assert(self.size.height >= 0.0);
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        std.debug.assert(self.scale_factor > 0.0);
        std.debug.assert(self.scale_factor <= scale_factor_max);
        return self.scale_factor;
    }

    // =========================================================================
    // 原生句柄 / 帧缓冲尺寸（依赖方自持渲染）
    // =========================================================================

    /// Web 没有可转发的原生对象：canvas 由宿主页面唯一持有，WebGPU /
    /// WebGL 的 context 在 JS 侧创建并 `configure`。
    pub fn nativeHandles(self: *const Self) NativeHandles {
        _ = self;
        return .{ .web = .{} };
    }

    /// 帧缓冲物理像素尺寸 = `canvas.width/height`（backing store，WebGPU
    /// `configure({ size })` 认的就是它），与 `width()`/`height()` 的 CSS
    /// 像素在 DPR ≠ 1 时不同。
    pub fn framebufferSize(self: *const Self) FramebufferSize {
        _ = self;
        return .{
            .width_px = imports.getCanvasPixelWidth(),
            .height_px = imports.getCanvasPixelHeight(),
        };
    }

    // =========================================================================
    // 渲染（帧节拍）
    // =========================================================================

    /// 派发一次 `on_render`，由宿主每帧经 `WebPlatform.frameTick()` 调用。
    ///
    /// web 的时钟属于宿主（`requestAnimationFrame` 链在 JS 手里），windowkit
    /// 不可能自己挂帧回调，所以派发点暴露给宿主的 `frame()`。这是
    /// `setRenderCallback` 在 web 上真正被触发的唯一路径。
    pub fn renderFrame(self: *Self) void {
        if (self.closed) return;
        if (self.on_render) |callback| callback(self);
    }

    // =========================================================================
    // 窗口属性
    // =========================================================================

    /// 文件拖放:Web 后端不支持(`capabilities.file_drop` 为 false——浏览器
    /// 给的是 `File` 对象,拿不到真实路径),此方法只为四平台 API 同形而设,
    /// 是 no-op。
    pub fn setFileDropEnabled(self: *Self, enabled: bool) void {
        _ = self;
        _ = enabled;
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        std.debug.assert(title.len <= title_bytes_max);
        std.debug.assert(!self.closed);

        imports.setDocumentTitle(title.ptr, @intCast(title.len));
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        std.debug.assert(color.a >= 0.0);
        std.debug.assert(color.a <= 1.0);

        self.background_color = color;
    }

    /// 记录请求的外观。
    ///
    /// 事实说明：这里没有宿主侧开关。浏览器的 `prefers-color-scheme`
    /// 由 OS 决定，应用的界面由应用自己画，所以这个标记存下来供应用
    /// 的帧回调查询，而非转发给宿主。
    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(!self.closed);

        self.dark_appearance = dark;

        std.debug.assert(self.dark_appearance == dark);
    }

    /// 记录请求的光标。
    ///
    /// 本后端 `capabilities.custom_cursors` 为 false：CSS 能表达全部
    /// 三种形状，但 `imports.zig` 没有 `setCanvasCursor` 绑定，JS 宿主
    /// 无法消费该请求。能力位就是契约表达"操作不受支持"的方式，所以
    /// 在导入落地之前必须保持 false。形状照旧存下来而不丢弃，
    /// 剩下的步骤只有接上那个导入。
    pub fn setCursorShape(self: *Self, shape: interface.CursorShape) void {
        std.debug.assert(!self.closed);

        self.cursor_shape = shape;

        std.debug.assert(self.cursor_shape == shape);
    }

    /// 记录玻璃/毛玻璃请求。
    ///
    /// 统一重映射为规范的 `interface.GlassStyle`（此前本后端自持一个
    /// tag 顺序不同的枚举，曾使运行时 `@enumFromInt` 的桥接不健全）。
    /// Web 确实能用 `backdrop-filter` 表达 `blur` 与 `vibrancy`，所以
    /// 存储并经 `getClearColor` 反映，而不是丢弃——但 CSS 真正应用
    /// 之前 `capabilities.glass_effects` 保持 false。
    pub fn setGlassStyle(
        self: *Self,
        style: interface.GlassStyle,
        opacity: f64,
        corner_radius: f64,
    ) void {
        std.debug.assert(opacity >= 0.0);
        std.debug.assert(opacity <= 1.0);
        std.debug.assert(corner_radius >= 0.0);

        self.glass_style = style;
        self.background_opacity = opacity;
        self.glass_corner_radius = corner_radius;
    }

    /// 帧缓冲实际清屏色。
    ///
    /// 用推导而非缓存，这样后置的 `setBackgroundColor` 或
    /// `setGlassStyle` 不可能让它与 `glass_style` 矛盾。
    pub fn getClearColor(self: *const Self) geometry.Color {
        if (self.glass_style.needsTransparentClear()) {
            std.debug.assert(self.glass_style != .none);
            return geometry.Color.transparent;
        }

        std.debug.assert(self.glass_style == .none);
        return self.background_color;
    }

    // =========================================================================
    // 指针状态
    // =========================================================================

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        std.debug.assert(self.size.width >= 0.0);

        const position: geometry.Point(f64) = .{
            .x = @floatCast(imports.getMouseX()),
            .y = @floatCast(imports.getMouseY()),
        };

        std.debug.assert(!std.math.isNan(position.x));
        return position;
    }

    /// 仅 Web 的原始访问器。保留它们是因为 JS 事件桥以 `f32` 上报 CSS
    /// 像素，部分调用点想拿未拓宽的原值。
    pub fn getMouseX(self: *const Self) f32 {
        std.debug.assert(!self.closed);
        return imports.getMouseX();
    }

    pub fn getMouseY(self: *const Self) f32 {
        std.debug.assert(!self.closed);
        return imports.getMouseY();
    }

    pub fn isMouseInside(self: *const Self) bool {
        std.debug.assert(self.size.width >= 0.0);
        std.debug.assert(self.size.height >= 0.0);
        return imports.isMouseInCanvas();
    }

    // =========================================================================
    // 宿主控制
    // =========================================================================

    /// 向宿主要一帧。
    ///
    /// 可以连续调用：浏览器会把同一帧内的重复 `requestAnimationFrame`
    /// 合并。
    pub fn requestRender(self: *Self) void {
        std.debug.assert(self.window_id.isValid());

        if (self.closed) return;
        imports.requestAnimationFrame();
    }

    /// 事实说明：这里只有一个 canvas，标签页激活时浏览器自然给它焦点，
    /// 没有可"置顶"的东西。保留为 no-op 是因为契约要求此方法存在。
    pub fn focus(self: *Self) void {
        std.debug.assert(self.window_id.isValid());
        std.debug.assert(!self.closed);
    }

    /// 标记窗口已关闭。
    ///
    /// 事实说明：页面不能关掉不是自己打开的标签页，所以
    /// `capabilities.can_close_window` 为 false，宿主无法真的履行
    /// 这个请求。宿主能做到的是停工，所以置位并让 `isClosed` 如实上报。
    /// 曾几何时此方法什么都不做、`isClosed` 也不存在，
    /// 调用方无从得知请求被忽略。
    pub fn close(self: *Self) void {
        std.debug.assert(self.window_id.isValid());

        self.closed = true;

        std.debug.assert(self.isClosed());
    }

    pub fn isClosed(self: *const Self) bool {
        std.debug.assert(self.closed or self.window_id.isValid());
        return self.closed;
    }

    // =========================================================================
    // IME 桥
    // =========================================================================

    /// 记录框架正在显示的 preedit 长度。
    ///
    /// 事实说明：字节推不出去。浏览器隐藏的 input 元素持有组合缓冲，
    /// preedit 由消费方基于 `composition_buffer` 自绘。但长度是真实
    /// 状态，`hasMarkedText` 要从它作答。
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        std.debug.assert(text.len <= composition_buffer.BUFFER_SIZE);
        std.debug.assert(!self.closed);

        self.marked_text_len = @intCast(text.len);
    }

    pub fn clearMarkedText(self: *Self) void {
        std.debug.assert(!self.closed);

        self.marked_text_len = 0;

        std.debug.assert(self.marked_text_len == 0);
    }

    /// 事实说明：提交的文本经 JS 文本环形缓冲（`text_buffer.zig`）
    /// 到达，不走这里，宿主没有承接点。保留它是为了与原生后端
    /// API 对照。
    pub fn setInsertedText(self: *Self, text: []const u8) void {
        std.debug.assert(text.len <= composition_buffer.BUFFER_SIZE);
        std.debug.assert(!self.closed);
    }

    /// 是否有组合（preedit）在途。
    ///
    /// 有条件时优先答浏览器自己的组合状态（web 上的权威），否则退回
    /// 框架上报的 preedit 长度，覆盖 `setMarkedText` 到下一次
    /// `compositionupdate` 之间的窗口期。
    pub fn hasMarkedText(self: *const Self) bool {
        const buffer = @as(
            *const volatile composition_buffer.CompositionBuffer,
            &composition_buffer.g_composition_buffer,
        );
        if (buffer.isActive()) {
            std.debug.assert(buffer.len <= composition_buffer.BUFFER_SIZE);
            return true;
        }

        std.debug.assert(self.marked_text_len <= composition_buffer.BUFFER_SIZE);
        return self.marked_text_len > 0;
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        std.debug.assert(w >= 0.0);
        std.debug.assert(h >= 0.0);
        std.debug.assert(!self.closed);

        imports.setImeCursorPosition(x, y, w, h);
    }

    // =========================================================================
    // 回调
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        std.debug.assert(!self.closed);

        self.on_input = callback;

        std.debug.assert(self.on_input == callback);
    }

    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        std.debug.assert(!self.closed);

        self.on_render = callback;

        std.debug.assert(self.on_render == callback);
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        std.debug.assert(!self.closed);

        self.on_close = callback;

        std.debug.assert(self.on_close == callback);
    }

    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        std.debug.assert(!self.closed);

        self.on_resize = callback;

        std.debug.assert(self.on_resize == callback);
    }

    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        std.debug.assert(!self.closed);

        self.on_post_input = callback;

        std.debug.assert(self.on_post_input == callback);
    }

    // =========================================================================
    // 用户数据
    // =========================================================================

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        std.debug.assert(self.window_id.isValid() or !self.closed);

        self.user_data = data;

        std.debug.assert(self.user_data == data);
    }

    /// 取回调用方的上下文指针。
    ///
    /// 五个静态回调全靠它找到自己的 owner；无条件返回 null（旧实现）
    /// 会在共享事件路径落地时悄悄废掉全部回调。
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        comptime std.debug.assert(@sizeOf(T) > 0);
        comptime std.debug.assert(@alignOf(T) > 0);

        const data = self.user_data orelse return null;
        std.debug.assert(std.mem.isAligned(@intFromPtr(data), @alignOf(T)));
        return @ptrCast(@alignCast(data));
    }

    // =========================================================================
    // 上限
    // =========================================================================

    /// 我们接受的 canvas 最大边长（CSS 像素）。浏览器的 backing store
    /// 上限远低于此；设界是为了让宿主的脏值触发断言，而不是算出一串
    /// 莫名其妙的 `@intFromFloat`。
    const size_px_max: u32 = 32_768;

    /// 超过此值的 `devicePixelRatio` 意味着宿主在谎报。
    ///
    /// 取 8 而不是更紧的界，是因为各层必须一致：macOS 的
    /// `getScaleFactor` 断言同一个 8.0，共享代码的 `SCALE_FACTOR_MAX`
    /// 钉在最宽松的后端界上。这里若更严，宿主报 5x 时这个后端放行、
    /// 但从未碰宿主的共享代码会 panic——本注释过去引用的 4.0 正是
    /// 因为这样才被抬高。
    const scale_factor_max: f64 = 8.0;

    /// 文档标题是宿主可见字符串，不是无限长的数据。
    const title_bytes_max: usize = 1024;
};
