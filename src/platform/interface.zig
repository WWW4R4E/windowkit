//! 平台层共享的契约类型。
//!
//! windowkit 的平台抽象是编译期单态的：`platform/mod.zig` 按目标平台
//! 精确选出一个后端命名空间，所有调用点直接绑定到它的具体类型。
//! 刻意不做运行时 vtable —— 类型擦除曾造成第二份漂移的契约、且没有
//! 任何使用方，因此被移除（见 `docs/platform_interface_design.md` 决策 2）。
//!
//! 本模块存放边界两侧共同认可的类型；强制两边一致的签名检查在
//! `contract.zig`。
//!
//! ## 用法
//!
//! ```zig
//! const platform = @import("windowkit").platform;
//!
//! var plat: platform.Platform = undefined;
//! try plat.initInPlace(allocator);
//! defer plat.deinit();
//!
//! const options = platform.WindowOptions{};
//! var window = try platform.PlatformWindow.init(allocator, &plat, &options);
//! defer window.deinit();
//!
//! plat.run();
//! ```
//!
//! ## 支持的后端
//!
//! - Windows: Win32（hwnd 句柄交给依赖方的 D3D / Vulkan 渲染）
//! - macOS: AppKit（`CAMetalLayer` 句柄交给依赖方的 Metal 渲染）
//! - Linux: Wayland（`wl_display`/`wl_surface` 句柄交给依赖方的 Vulkan 渲染）

const std = @import("std");
const geometry = @import("../geometry.zig");
const window_registry = @import("window_registry.zig");

// =============================================================================
// 窗口标识
// =============================================================================

/// 窗口的唯一标识，用于跨窗口引用。
pub const WindowId = window_registry.WindowId;

/// 按 ID 追踪窗口的中央注册表。
pub const WindowRegistry = window_registry.WindowRegistry;

// =============================================================================
// 过程式事件循环内核（三后端同一契约）
// =============================================================================

/// `waitEvent` 的超时哨兵：无限期阻塞直到事件到来。
pub const wait_infinite: u32 = std.math.maxInt(u32);

// 过程式循环是第一公民，`run()` 只是它的糖。三个后端必须按同一契约实现：
//
// - **`pump()`** — 非阻塞泵一轮：排空当前就绪的事件并走完所有分派路径
//   （输入/关闭/缩放回调），然后立即返回。**不派发渲染节拍**——帧节奏
//   归调用方的循环；按需渲染由调用方配合 `requestRender()` /
//   `win.render()` 自行驱动。它同时是平台级退出信号（Win32 `WM_QUIT` /
//   Wayland 连接死亡 / `quit()` 本身）的最后通路，返回时 `isRunning()`
//   即为最终值。
//
// - **`waitEvent(timeout_ms)`** — 至多阻塞 `timeout_ms` 毫秒等下一批
//   事件：事件源就绪即提前返回 true（但**不**分派，分派集中在随之而来
//   的 `pump()` 里），超时或无事件源返回 false，期间靠平台的阻塞等待
//   原语睡掉 CPU。`timeout_ms == wait_infinite` 表示无限期阻塞；已处于
//   退出状态时立即返回 false。
//
// - **`start()`** — 进入运行状态，过程式循环的起点：`start()` 之后
//   `isRunning()` 为 true，直到 `quit()` 或平台级退出信号。`run()` 内部
//   会自己调它；过程式调用方必须先调一次，否则 `while (isRunning())`
//   一次都不会进。重复调用属于用法错误。
//
// - **`run()`** — 回调糖，语义与抽走过程内核之前逐平台一致：内部循环
//   = `pump`（或等价的阻塞等待）+ 各窗口帧节拍派发 + owner 回合钩子
//   （`loop_turn_callback`）。`quit()` 仍是停它的手段。
//
// 线程契约：`pump`/`waitEvent` 必须在创建窗口的线程（UI 主线程）上调用；
// `setRenderCallback` 的派发线程仍由各后端自己定义（见 README 表），
// 这条不受过程化影响。

// =============================================================================
// 光标
// =============================================================================

/// 组件可选的光标形状。
pub const CursorShape = enum(u8) {
    default,
    text,
    /// 手型光标，用于可点击元素（按钮、链接）。
    pointer,
};

// =============================================================================
// 玻璃/毛玻璃样式
// =============================================================================

/// 窗口半透明背景样式。
///
/// 全后端共用这一个枚举，跨后端以相同 tag 值引用。
/// 后端不支持某样式时必须"可见地降级"（见 `PlatformCapabilities`
/// 的 `glass_effects`），不能悄悄替换 tag。
pub const GlassStyle = enum(u8) {
    /// 无玻璃效果，直接用窗口背景色。
    none = 0,
    /// 传统背景模糊。
    blur = 1,
    /// macOS 26+ 液态玻璃，常规密度。
    glass_regular = 2,
    /// macOS 26+ 液态玻璃，clear/较浅密度。
    glass_clear = 3,

    /// 此样式是否需要透明清屏，才能让宿主合成的背景透出来。
    pub fn needsTransparentClear(self: GlassStyle) bool {
        return self != .none;
    }
};

// =============================================================================
// 能力
// =============================================================================

/// 后端支持的能力。各后端以编译期常量声明，特性判断可以编译期折叠。
pub const PlatformCapabilities = struct {
    /// 支持高分屏（Retina）。
    high_dpi: bool = true,

    /// 支持多个窗口。
    multi_window: bool = true,

    /// 支持通过 display link 实现 vsync。
    display_link: bool = true,

    /// 能以代码方式关闭窗口。
    can_close_window: bool = true,

    /// 宿主能在窗口 surface 后面合成半透明背景，使非 `.none` 的
    /// `GlassStyle` 真正可见。
    ///
    /// 置 true 则后端必须同时声明 `PlatformWindow.setGlassStyle`
    /// （调用方就是用它选样式）；`contract.verifyPlatformWindow`
    /// 会条件性检查这条约束。
    glass_effects: bool = false,

    /// 支持 IME（输入法编辑器）。
    ime: bool = true,

    /// 支持把文件从系统文件管理器拖到窗口上（`InputEvent.file_drop`）。
    /// 拖放 surface 归窗口层持有（Win32 IDropTarget / Wayland
    /// data-device DnD / NSView 拖放目标），应用没法在外部自行挂上。
    file_drop: bool = false,

    /// 支持自定义光标。
    custom_cursors: bool = true,

    /// 支持按住内容区拖动窗口。
    window_drag_by_content: bool = false,

    /// 后端名称（调试用）。
    name: []const u8 = "unknown",
};

// =============================================================================
// 窗口创建选项
// =============================================================================

/// 窗口创建选项。
///
/// 跨边界时以 `*const WindowOptions` 传递：整个结构体远超 Zig 按值
/// 传递的 16 字节阈值，用指针可以避免调用方字面量被复制进每个后端
/// 的调用帧。
pub const WindowOptions = struct {
    /// 窗口标题。
    title: []const u8 = "windowkit",

    /// 初始宽度（逻辑像素）。
    width: f64 = 800,

    /// 初始高度（逻辑像素）。
    height: f64 = 600,

    /// 背景色。
    background_color: geometry.Color = geometry.Color.rgba(0.2, 0.2, 0.25, 1.0),

    /// 通过 display link 启用 vsync（推荐）。
    use_display_link: bool = true,

    /// 最小窗口尺寸。
    min_size: ?geometry.Size(f64) = null,

    /// 最大窗口尺寸。
    max_size: ?geometry.Size(f64) = null,

    /// 在屏幕居中启动。
    centered: bool = true,

    /// 背景不透明度（0.0 = 全透明，1.0 = 不透明）。
    /// 在 `PlatformCapabilities.glass_effects` 开启的后端生效。
    background_opacity: f64 = 1.0,

    /// 半透明背景样式。
    glass_style: GlassStyle = .none,

    /// 玻璃效果的圆角半径。
    glass_corner_radius: f64 = 16.0,

    /// 标题栏透明（仅 macOS）。
    titlebar_transparent: bool = false,

    /// 内容延伸到标题栏之下（仅 macOS）。
    full_size_content: bool = false,

    /// 接受文件拖放并派发 `.file_drop` 事件。
    /// 在 `capabilities.file_drop` 为 false 的平台被忽略。
    /// 运行时可用 `win.setFileDropEnabled()` 切换。
    file_drop: bool = true,

    /// 该配置下的实际清屏色。
    ///
    /// 玻璃样式需要透明清屏，宿主合成的背景才透得出来；
    /// 否则用配置的背景色。
    pub fn clearColor(self: *const WindowOptions) geometry.Color {
        if (self.glass_style.needsTransparentClear()) return geometry.Color.transparent;
        return self.background_color;
    }
};

// =============================================================================
// 测试
// =============================================================================

test "GlassStyle tags stable across backends" {
    // 这些 tag 值是承重的：应用代码里 `WindowOptions` 字面量会持久化
    // 它们，且此前曾被跨三个枚举重新解释。在此钉死，重排顺序时让
    // 测试失败，而不是窗口外观悄悄变错。
    try std.testing.expectEqual(@as(u8, 0), @backingInt(GlassStyle.none));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(GlassStyle.blur));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(GlassStyle.glass_regular));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(GlassStyle.glass_clear));
}

test "GlassStyle.needsTransparentClear covers all variants" {
    // 一正一反：恰好只有 `.none` 一个变体保留自己的颜色。
    try std.testing.expect(!GlassStyle.none.needsTransparentClear());

    var transparent_count: u32 = 0;
    inline for (comptime std.enums.values(GlassStyle)) |style| {
        if (style.needsTransparentClear()) transparent_count += 1;
    }
    const variant_count = comptime std.enums.values(GlassStyle).len;
    try std.testing.expectEqual(variant_count - 1, transparent_count);
}

test "WindowOptions.clearColor follows glass style" {
    const opaque_options = WindowOptions{
        .glass_style = .none,
        .background_color = geometry.Color.rgba(0.1, 0.2, 0.3, 1.0),
    };
    try std.testing.expectEqual(@as(f32, 1.0), opaque_options.clearColor().a);

    const glass_options = WindowOptions{ .glass_style = .glass_regular };
    try std.testing.expectEqual(@as(f32, 0.0), glass_options.clearColor().a);
}
