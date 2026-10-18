//! Linux 窗口的 Wayland C 绑定。
//!
//! 封装 libwayland-client 及各扩展协议，提供 Linux 上的原生 Wayland 窗口支持。
//!
//! 用到的协议：
//! - wayland-client（核心协议）
//! - xdg-shell（窗口管理）
//! - xdg-decoration（服务端装饰）

const std = @import("std");

// =============================================================================
// 基础类型
// =============================================================================

/// Wayland 定点数（24.8 格式）
pub const Fixed = i32;

pub fn fixedToDouble(f: Fixed) f64 {
    return @as(f64, @floatFromInt(f)) / 256.0;
}

pub fn doubleToFixed(d: f64) Fixed {
    return @intFromFloat(d * 256.0);
}

// =============================================================================
// 不透明句柄类型
// =============================================================================

pub const Display = opaque {};
pub const Registry = opaque {};
pub const Callback = opaque {};
pub const Compositor = opaque {};
pub const Surface = opaque {};
pub const Region = opaque {};
pub const Buffer = opaque {};
pub const ShmPool = opaque {};
pub const Shm = opaque {};
pub const Seat = opaque {};
pub const Pointer = opaque {};
pub const Keyboard = opaque {};
pub const Touch = opaque {};
pub const Output = opaque {};
pub const Subcompositor = opaque {};
pub const Subsurface = opaque {};

// XDG Shell 类型
pub const XdgWmBase = opaque {};
pub const XdgSurface = opaque {};
pub const XdgToplevel = opaque {};
pub const XdgPopup = opaque {};
pub const XdgPositioner = opaque {};

// XDG Decoration 类型
pub const ZxdgDecorationManagerV1 = opaque {};
pub const ZxdgToplevelDecorationV1 = opaque {};

// Text Input 类型（IME 支持）
pub const ZwpTextInputV3 = opaque {};
pub const ZwpTextInputManagerV3 = opaque {};

// Viewporter 类型（HiDPI 支持）
pub const WpViewporter = opaque {};
pub const WpViewport = opaque {};

// 光标形状协议类型
pub const WpCursorShapeManagerV1 = opaque {};
pub const WpCursorShapeDeviceV1 = opaque {};

// Wayland 数组类型（listener 参数用到）
pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

// =============================================================================
// Listener 结构体
// =============================================================================

pub const RegistryListener = extern struct {
    global: ?*const fn (
        data: ?*anyopaque,
        registry: *Registry,
        name: u32,
        interface: [*:0]const u8,
        version: u32,
    ) callconv(.c) void = null,
    global_remove: ?*const fn (
        data: ?*anyopaque,
        registry: *Registry,
        name: u32,
    ) callconv(.c) void = null,
};

pub const SurfaceListener = extern struct {
    enter: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        output: *Output,
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        output: *Output,
    ) callconv(.c) void = null,
    preferred_buffer_scale: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        factor: i32,
    ) callconv(.c) void = null,
    preferred_buffer_transform: ?*const fn (
        data: ?*anyopaque,
        surface: *Surface,
        transform: u32,
    ) callconv(.c) void = null,
};

pub const CallbackListener = extern struct {
    done: ?*const fn (
        data: ?*anyopaque,
        callback: *Callback,
        callback_data: u32,
    ) callconv(.c) void = null,
};

pub const SeatListener = extern struct {
    capabilities: ?*const fn (
        data: ?*anyopaque,
        seat: *Seat,
        capabilities: SeatCapability,
    ) callconv(.c) void = null,
    name: ?*const fn (
        data: ?*anyopaque,
        seat: *Seat,
        name: [*:0]const u8,
    ) callconv(.c) void = null,
};

pub const SeatCapability = packed struct(u32) {
    pointer: bool = false,
    keyboard: bool = false,
    touch: bool = false,
    _padding: u29 = 0,
};

pub const PointerListener = extern struct {
    enter: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        serial: u32,
        surface: *Surface,
        surface_x: Fixed,
        surface_y: Fixed,
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        serial: u32,
        surface: *Surface,
    ) callconv(.c) void = null,
    motion: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        time: u32,
        surface_x: Fixed,
        surface_y: Fixed,
    ) callconv(.c) void = null,
    button: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        serial: u32,
        time: u32,
        button: u32,
        state: PointerButtonState,
    ) callconv(.c) void = null,
    axis: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        time: u32,
        axis: PointerAxis,
        value: Fixed,
    ) callconv(.c) void = null,
    frame: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
    ) callconv(.c) void = null,
    axis_source: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis_source: PointerAxisSource,
    ) callconv(.c) void = null,
    axis_stop: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        time: u32,
        axis: PointerAxis,
    ) callconv(.c) void = null,
    axis_discrete: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis: PointerAxis,
        discrete: i32,
    ) callconv(.c) void = null,
    axis_value120: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis: PointerAxis,
        value120: i32,
    ) callconv(.c) void = null,
    axis_relative_direction: ?*const fn (
        data: ?*anyopaque,
        pointer: *Pointer,
        axis: PointerAxis,
        direction: PointerAxisRelativeDirection,
    ) callconv(.c) void = null,
};

pub const PointerButtonState = enum(u32) {
    released = 0,
    pressed = 1,
};

pub const PointerAxis = enum(u32) {
    vertical_scroll = 0,
    horizontal_scroll = 1,
};

pub const PointerAxisSource = enum(u32) {
    wheel = 0,
    finger = 1,
    continuous = 2,
    wheel_tilt = 3,
};

pub const PointerAxisRelativeDirection = enum(u32) {
    identical = 0,
    inverted = 1,
};

pub const KeyboardListener = extern struct {
    keymap: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        format: KeyboardKeymapFormat,
        fd: i32,
        size: u32,
    ) callconv(.c) void = null,
    enter: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        surface: *Surface,
        keys: *anyopaque, // wl_array*
    ) callconv(.c) void = null,
    leave: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        surface: *Surface,
    ) callconv(.c) void = null,
    key: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        time: u32,
        key: u32,
        state: KeyState,
    ) callconv(.c) void = null,
    modifiers: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        serial: u32,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) callconv(.c) void = null,
    repeat_info: ?*const fn (
        data: ?*anyopaque,
        keyboard: *Keyboard,
        rate: i32,
        delay: i32,
    ) callconv(.c) void = null,
};

pub const KeyboardKeymapFormat = enum(u32) {
    no_keymap = 0,
    xkb_v1 = 1,
};

pub const KeyState = enum(u32) {
    released = 0,
    pressed = 1,
};

pub const TouchListener = extern struct {
    down: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        serial: u32,
        time: u32,
        surface: *Surface,
        id: i32,
        x: Fixed,
        y: Fixed,
    ) callconv(.c) void = null,
    up: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        serial: u32,
        time: u32,
        id: i32,
    ) callconv(.c) void = null,
    motion: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        time: u32,
        id: i32,
        x: Fixed,
        y: Fixed,
    ) callconv(.c) void = null,
    frame: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
    ) callconv(.c) void = null,
    cancel: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
    ) callconv(.c) void = null,
    shape: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        id: i32,
        major: Fixed,
        minor: Fixed,
    ) callconv(.c) void = null,
    orientation: ?*const fn (
        data: ?*anyopaque,
        touch: *Touch,
        id: i32,
        orientation: Fixed,
    ) callconv(.c) void = null,
};

pub const OutputListener = extern struct {
    geometry: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        x: i32,
        y: i32,
        physical_width: i32,
        physical_height: i32,
        subpixel: i32,
        make: [*:0]const u8,
        model: [*:0]const u8,
        transform: i32,
    ) callconv(.c) void = null,
    mode: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        flags: u32,
        width: i32,
        height: i32,
        refresh: i32,
    ) callconv(.c) void = null,
    done: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
    ) callconv(.c) void = null,
    scale: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        factor: i32,
    ) callconv(.c) void = null,
    name: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        name: [*:0]const u8,
    ) callconv(.c) void = null,
    description: ?*const fn (
        data: ?*anyopaque,
        output: *Output,
        description: [*:0]const u8,
    ) callconv(.c) void = null,
};

// =============================================================================
// XDG Shell listener
// =============================================================================

pub const XdgWmBaseListener = extern struct {
    ping: ?*const fn (
        data: ?*anyopaque,
        xdg_wm_base: *XdgWmBase,
        serial: u32,
    ) callconv(.c) void = null,
};

pub const XdgSurfaceListener = extern struct {
    configure: ?*const fn (
        data: ?*anyopaque,
        xdg_surface: *XdgSurface,
        serial: u32,
    ) callconv(.c) void = null,
};

pub const XdgToplevelListener = extern struct {
    configure: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
        width: i32,
        height: i32,
        states: *anyopaque, // wl_array*
    ) callconv(.c) void = null,
    close: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
    ) callconv(.c) void = null,
    configure_bounds: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
        width: i32,
        height: i32,
    ) callconv(.c) void = null,
    wm_capabilities: ?*const fn (
        data: ?*anyopaque,
        xdg_toplevel: *XdgToplevel,
        capabilities: *anyopaque, // wl_array*
    ) callconv(.c) void = null,
};

pub const XdgToplevelState = enum(u32) {
    maximized = 1,
    fullscreen = 2,
    resizing = 3,
    activated = 4,
    tiled_left = 5,
    tiled_right = 6,
    tiled_top = 7,
    tiled_bottom = 8,
    suspended = 9,
};

// =============================================================================
// XDG Decoration listener
// =============================================================================

pub const ZxdgToplevelDecorationV1Listener = extern struct {
    configure: ?*const fn (
        data: ?*anyopaque,
        decoration: *ZxdgToplevelDecorationV1,
        mode: ZxdgToplevelDecorationV1Mode,
    ) callconv(.c) void = null,
};

pub const ZxdgToplevelDecorationV1Mode = enum(u32) {
    undefined = 0,
    client_side = 1,
    server_side = 2,
};

// =============================================================================
// Text Input V3 协议（IME 支持）
// =============================================================================

/// 文本输入的 content hint 位
pub const ZwpTextInputV3ContentHint = packed struct(u32) {
    completion: bool = false, // 0x1
    spellcheck: bool = false, // 0x2
    auto_capitalization: bool = false, // 0x4
    lowercase: bool = false, // 0x8
    uppercase: bool = false, // 0x10
    titlecase: bool = false, // 0x20
    hidden_text: bool = false, // 0x40
    sensitive_data: bool = false, // 0x80
    latin: bool = false, // 0x100
    multiline: bool = false, // 0x200
    _padding: u22 = 0,

    pub const none: ZwpTextInputV3ContentHint = .{};
    pub const default: ZwpTextInputV3ContentHint = .{ .completion = true, .spellcheck = true, .auto_capitalization = true };
};

/// 文本输入的 content purpose
pub const ZwpTextInputV3ContentPurpose = enum(u32) {
    normal = 0,
    alpha = 1,
    digits = 2,
    number = 3,
    phone = 4,
    url = 5,
    email = 6,
    name = 7,
    password = 8,
    pin = 9,
    date = 10,
    time = 11,
    datetime = 12,
    terminal = 13,
};

/// 文本输入 done 事件的变更原因
pub const ZwpTextInputV3ChangeCause = enum(u32) {
    input_method = 0,
    other = 1,
};

/// Text Input V3 listener，承载 IME 事件
pub const ZwpTextInputV3Listener = extern struct {
    /// compositor 发来 enter（文本输入已对该 surface 激活）
    enter: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        surface: *Surface,
    ) callconv(.c) void = null,

    /// compositor 发来 leave（文本输入停用）
    leave: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        surface: *Surface,
    ) callconv(.c) void = null,

    /// 预编辑字符串（composing 用；只显示、不上屏）
    preedit_string: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        text: ?[*:0]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    ) callconv(.c) void = null,

    /// 输入法上屏的文本
    commit_string: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        text: ?[*:0]const u8,
    ) callconv(.c) void = null,

    /// 光标前要删除的文本
    delete_surrounding_text: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        before_length: u32,
        after_length: u32,
    ) callconv(.c) void = null,

    /// 一批事件的末尾：把此前的累积状态一次性应用
    done: ?*const fn (
        data: ?*anyopaque,
        text_input: *ZwpTextInputV3,
        serial: u32,
    ) callconv(.c) void = null,
};

// =============================================================================
// 接口结构体（供 wl_proxy_marshal_* 使用）
// =============================================================================

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const Message,
    event_count: c_int,
    events: ?*const Message,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?*const ?*const Interface,
};

// =============================================================================
// 核心 Wayland C 函数（libwayland-client.so）
// =============================================================================

// Display（display 相关）
pub extern "wayland-client" fn wl_display_connect(name: ?[*:0]const u8) ?*Display;
pub extern "wayland-client" fn wl_display_disconnect(display: *Display) void;
pub extern "wayland-client" fn wl_display_dispatch(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_dispatch_pending(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_roundtrip(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_flush(display: *Display) c_int;
pub extern "wayland-client" fn wl_display_get_fd(display: *Display) c_int;

// wl_display_get_registry 在 wayland-client 里是 inline 函数，这里自己实现
pub fn wl_display_get_registry(display: *Display) ?*Registry {
    // wl_display::get_registry 是 opcode 1
    const WL_DISPLAY_GET_REGISTRY: u32 = 1;
    return @ptrCast(wl_proxy_marshal_flags(
        @ptrCast(display),
        WL_DISPLAY_GET_REGISTRY,
        &wl_registry_interface,
        wl_proxy_get_version(@ptrCast(display)),
        0,
    ));
}

// Proxy（所有 Wayland 对象的基类）
pub extern "wayland-client" fn wl_proxy_add_listener(
    proxy: *anyopaque,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) c_int;
pub extern "wayland-client" fn wl_proxy_destroy(proxy: *anyopaque) void;
pub extern "wayland-client" fn wl_proxy_marshal_flags(proxy: *anyopaque, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, ...) ?*anyopaque;
pub extern "wayland-client" fn wl_proxy_get_version(proxy: *anyopaque) u32;

// =============================================================================
// 协议接口声明（链接自协议库）
// =============================================================================

pub extern "wayland-client" var wl_registry_interface: Interface;
pub extern "wayland-client" var wl_compositor_interface: Interface;
pub extern "wayland-client" var wl_surface_interface: Interface;
pub extern "wayland-client" var wl_region_interface: Interface;
pub extern "wayland-client" var wl_callback_interface: Interface;
pub extern "wayland-client" var wl_seat_interface: Interface;
pub extern "wayland-client" var wl_pointer_interface: Interface;
pub extern "wayland-client" var wl_keyboard_interface: Interface;
pub extern "wayland-client" var wl_touch_interface: Interface;
pub extern "wayland-client" var wl_output_interface: Interface;
pub extern "wayland-client" var wl_shm_interface: Interface;

// XDG shell 接口（来自 wayland-protocols 而非 wayland-client，手动补齐）
// 消息签名必须给对，wl_proxy_marshal_flags 才能正确工作。

// 类型数组用到的接口前向引用
const xdg_surface_interface_ptr: ?*const Interface = &xdg_surface_interface;
const xdg_toplevel_interface_ptr: ?*const Interface = &xdg_toplevel_interface;
const xdg_positioner_interface_ptr: ?*const Interface = &xdg_positioner_interface;
const zxdg_toplevel_decoration_v1_interface_ptr: ?*const Interface = &zxdg_toplevel_decoration_v1_interface;

// 含对象/new_id 参数的消息的类型数组
const xdg_wm_base_create_positioner_types = [_]?*const Interface{xdg_positioner_interface_ptr};
const xdg_wm_base_get_xdg_surface_types = [_]?*const Interface{ xdg_surface_interface_ptr, &wl_surface_interface };
const xdg_surface_get_toplevel_types = [_]?*const Interface{xdg_toplevel_interface_ptr};
const xdg_toplevel_set_parent_types = [_]?*const Interface{xdg_toplevel_interface_ptr};
const zxdg_decoration_manager_get_decoration_types = [_]?*const Interface{ zxdg_toplevel_decoration_v1_interface_ptr, xdg_toplevel_interface_ptr };
const zwp_text_input_manager_v3_get_text_input_types = [_]?*const Interface{ zwp_text_input_v3_interface_ptr, &wl_seat_interface };

// Viewporter 前向引用
const wp_viewport_interface_ptr: ?*const Interface = &wp_viewport_interface;
const wp_viewporter_get_viewport_types = [_]?*const Interface{ wp_viewport_interface_ptr, &wl_surface_interface };

// 光标形状前向引用
const wp_cursor_shape_device_v1_interface_ptr: ?*const Interface = &wp_cursor_shape_device_v1_interface;
const wp_cursor_shape_manager_v1_get_pointer_types = [_]?*const Interface{ wp_cursor_shape_device_v1_interface_ptr, &wl_pointer_interface };

// 带 object 参数的 text input v3 事件的类型数组
const zwp_text_input_v3_enter_types = [_]?*const Interface{&wl_surface_interface};
const zwp_text_input_v3_leave_types = [_]?*const Interface{&wl_surface_interface};

// xdg_wm_base 事件：ping
const xdg_wm_base_events = [_]Message{
    .{ .name = "ping", .signature = "u", .types = null },
};

// xdg_wm_base 方法：destroy, create_positioner, get_xdg_surface, pong
const xdg_wm_base_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = @ptrCast(&xdg_wm_base_create_positioner_types) },
    .{ .name = "get_xdg_surface", .signature = "no", .types = @ptrCast(&xdg_wm_base_get_xdg_surface_types) },
    .{ .name = "pong", .signature = "u", .types = null },
};

pub const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 6,
    .method_count = 4,
    .methods = @ptrCast(&xdg_wm_base_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_wm_base_events),
};

// xdg_surface 事件：configure
const xdg_surface_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};

// xdg_surface 方法：destroy, get_toplevel, get_popup, set_window_geometry, ack_configure
const xdg_surface_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = @ptrCast(&xdg_surface_get_toplevel_types) },
    .{ .name = "get_popup", .signature = "noo", .types = null }, // simplified
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};

pub const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 6,
    .method_count = 5,
    .methods = @ptrCast(&xdg_surface_methods),
    .event_count = 1,
    .events = @ptrCast(&xdg_surface_events),
};

// xdg_toplevel 事件：configure, close, configure_bounds, wm_capabilities
const xdg_toplevel_events = [_]Message{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "a", .types = null },
};

// xdg_toplevel 方法（共 14 个，这里只定义我们用到的）
const xdg_toplevel_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = @ptrCast(&xdg_toplevel_set_parent_types) },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_app_id", .signature = "s", .types = null },
    .{ .name = "show_window_menu", .signature = "ouii", .types = null },
    .{ .name = "move", .signature = "ou", .types = null },
    .{ .name = "resize", .signature = "ouu", .types = null },
    .{ .name = "set_max_size", .signature = "ii", .types = null },
    .{ .name = "set_min_size", .signature = "ii", .types = null },
    .{ .name = "set_maximized", .signature = "", .types = null },
    .{ .name = "unset_maximized", .signature = "", .types = null },
    .{ .name = "set_fullscreen", .signature = "?o", .types = null },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};

pub const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 6,
    .method_count = 14,
    .methods = @ptrCast(&xdg_toplevel_methods),
    .event_count = 4,
    .events = @ptrCast(&xdg_toplevel_events),
};

pub const xdg_positioner_interface: Interface = .{
    .name = "xdg_positioner",
    .version = 6,
    .method_count = 10,
    .methods = null,
    .event_count = 0,
    .events = null,
};

// XDG decoration 接口
const zxdg_decoration_manager_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel_decoration", .signature = "no", .types = @ptrCast(&zxdg_decoration_manager_get_decoration_types) },
};

pub const zxdg_decoration_manager_v1_interface: Interface = .{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&zxdg_decoration_manager_v1_methods),
    .event_count = 0,
    .events = null,
};

// zxdg_toplevel_decoration_v1 事件：configure
const zxdg_toplevel_decoration_v1_events = [_]Message{
    .{ .name = "configure", .signature = "u", .types = null },
};

const zxdg_toplevel_decoration_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_mode", .signature = "u", .types = null },
    .{ .name = "unset_mode", .signature = "", .types = null },
};

pub const zxdg_toplevel_decoration_v1_interface: Interface = .{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&zxdg_toplevel_decoration_v1_methods),
    .event_count = 1,
    .events = @ptrCast(&zxdg_toplevel_decoration_v1_events),
};

// Text Input V3 接口（IME 支持）
const zwp_text_input_v3_interface_ptr = &zwp_text_input_v3_interface;

// zwp_text_input_manager_v3 方法：destroy, get_text_input
const zwp_text_input_manager_v3_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_text_input", .signature = "no", .types = @ptrCast(&zwp_text_input_manager_v3_get_text_input_types) },
};

pub const zwp_text_input_manager_v3_interface: Interface = .{
    .name = "zwp_text_input_manager_v3",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&zwp_text_input_manager_v3_methods),
    .event_count = 0,
    .events = null,
};

// zwp_text_input_v3 事件：enter, leave, preedit_string, commit_string, delete_surrounding_text, done
const zwp_text_input_v3_events = [_]Message{
    .{ .name = "enter", .signature = "o", .types = @ptrCast(&zwp_text_input_v3_enter_types) },
    .{ .name = "leave", .signature = "o", .types = @ptrCast(&zwp_text_input_v3_leave_types) },
    .{ .name = "preedit_string", .signature = "?sii", .types = null },
    .{ .name = "commit_string", .signature = "?s", .types = null },
    .{ .name = "delete_surrounding_text", .signature = "uu", .types = null },
    .{ .name = "done", .signature = "u", .types = null },
};

// zwp_text_input_v3 方法：destroy, enable, disable, set_surrounding_text, set_text_change_cause, set_content_type, set_cursor_rectangle, commit
const zwp_text_input_v3_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "enable", .signature = "", .types = null },
    .{ .name = "disable", .signature = "", .types = null },
    .{ .name = "set_surrounding_text", .signature = "sii", .types = null },
    .{ .name = "set_text_change_cause", .signature = "u", .types = null },
    .{ .name = "set_content_type", .signature = "uu", .types = null },
    .{ .name = "set_cursor_rectangle", .signature = "iiii", .types = null },
    .{ .name = "commit", .signature = "", .types = null },
};

pub const zwp_text_input_v3_interface: Interface = .{
    .name = "zwp_text_input_v3",
    .version = 1,
    .method_count = 8,
    .methods = @ptrCast(&zwp_text_input_v3_methods),
    .event_count = 6,
    .events = @ptrCast(&zwp_text_input_v3_events),
};

// =============================================================================
// 上层封装函数
// =============================================================================

pub const MARSHAL_FLAG_DESTROY: u32 = 1;

// Display 操作
pub fn displayConnect(name: ?[*:0]const u8) ?*Display {
    return wl_display_connect(name);
}

pub fn displayDisconnect(display: *Display) void {
    wl_display_disconnect(display);
}

pub fn displayDispatch(display: *Display) c_int {
    return wl_display_dispatch(display);
}

pub fn displayDispatchPending(display: *Display) c_int {
    return wl_display_dispatch_pending(display);
}

pub fn displayRoundtrip(display: *Display) c_int {
    return wl_display_roundtrip(display);
}

pub fn displayFlush(display: *Display) c_int {
    return wl_display_flush(display);
}

pub fn displayGetRegistry(display: *Display) ?*Registry {
    return wl_display_get_registry(display);
}

pub fn displayGetFd(display: *Display) c_int {
    return wl_display_get_fd(display);
}

// 接口访问器（供 registryBind 用）
pub fn getCompositorInterface() *const Interface {
    return &wl_compositor_interface;
}

pub fn getXdgWmBaseInterface() *const Interface {
    return &xdg_wm_base_interface;
}

pub fn getSeatInterface() *const Interface {
    return &wl_seat_interface;
}

pub fn getOutputInterface() *const Interface {
    return &wl_output_interface;
}

pub fn getDecorationManagerInterface() *const Interface {
    return &zxdg_decoration_manager_v1_interface;
}

pub fn getTextInputManagerV3Interface() *const Interface {
    return &zwp_text_input_manager_v3_interface;
}

pub fn getTextInputV3Interface() *const Interface {
    return &zwp_text_input_v3_interface;
}

// Registry 操作
pub fn registryAddListener(registry: *Registry, listener: *const RegistryListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(registry), @ptrCast(listener), data) == 0;
}

pub fn registryBind(registry: *Registry, name: u32, interface: *const Interface, version: u32) ?*anyopaque {
    return wl_proxy_marshal_flags(
        @ptrCast(registry),
        0, // WL_REGISTRY_BIND
        interface,
        version,
        0,
        name,
        interface.name,
        version,
        @as(?*anyopaque, null),
    );
}

pub fn registryDestroy(registry: *Registry) void {
    wl_proxy_destroy(@ptrCast(registry));
}

// Compositor 操作
pub fn compositorCreateSurface(compositor: *Compositor) ?*Surface {
    const result = wl_proxy_marshal_flags(
        @ptrCast(compositor),
        0, // WL_COMPOSITOR_CREATE_SURFACE
        &wl_surface_interface,
        wl_proxy_get_version(@ptrCast(compositor)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn compositorCreateRegion(compositor: *Compositor) ?*Region {
    const result = wl_proxy_marshal_flags(
        @ptrCast(compositor),
        1, // WL_COMPOSITOR_CREATE_REGION
        &wl_region_interface,
        wl_proxy_get_version(@ptrCast(compositor)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn compositorDestroy(compositor: *Compositor) void {
    wl_proxy_destroy(@ptrCast(compositor));
}

// Surface 操作
pub fn surfaceAddListener(surface: *Surface, listener: *const SurfaceListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(surface), @ptrCast(listener), data) == 0;
}

pub fn surfaceDestroy(surface: *Surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        0, // WL_SURFACE_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn surfaceCommit(surface: *Surface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        6, // WL_SURFACE_COMMIT
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
    );
}

pub fn surfaceFrame(surface: *Surface) ?*Callback {
    const result = wl_proxy_marshal_flags(
        @ptrCast(surface),
        3, // WL_SURFACE_FRAME
        &wl_callback_interface,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn surfaceSetOpaqueRegion(surface: *Surface, region: ?*Region) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        4, // WL_SURFACE_SET_OPAQUE_REGION
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        @as(?*anyopaque, @ptrCast(region)),
    );
}

pub fn surfaceSetBufferScale(surface: *Surface, scale: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(surface),
        8, // WL_SURFACE_SET_BUFFER_SCALE
        null,
        wl_proxy_get_version(@ptrCast(surface)),
        0,
        scale,
    );
}

// =============================================================================
// wp_viewporter 封装（HiDPI 支持）
// =============================================================================

/// 绑定 wp_viewporter global
pub fn bindViewporter(registry: *Registry, name: u32, version: u32) ?*WpViewporter {
    return @ptrCast(@alignCast(registryBind(
        registry,
        name,
        &wp_viewporter_interface,
        @min(version, 1),
    )));
}

/// 为 surface 创建 viewport
pub fn viewporterGetViewport(viewporter: *WpViewporter, surface: *Surface) ?*WpViewport {
    const result = wl_proxy_marshal_flags(
        @ptrCast(viewporter),
        1, // WP_VIEWPORTER_GET_VIEWPORT
        &wp_viewport_interface,
        wl_proxy_get_version(@ptrCast(viewporter)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(surface)),
    );
    return @ptrCast(@alignCast(result));
}

/// 销毁 viewporter
pub fn viewporterDestroy(viewporter: *WpViewporter) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewporter),
        0, // WP_VIEWPORTER_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(viewporter)),
        0,
    );
    wl_proxy_destroy(@ptrCast(viewporter));
}

/// 设置 viewport 的目标尺寸（逻辑像素）
/// 即 surface 在屏幕上呈现的尺寸
pub fn viewportSetDestination(viewport: *WpViewport, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewport),
        2, // WP_VIEWPORT_SET_DESTINATION
        null,
        wl_proxy_get_version(@ptrCast(viewport)),
        0,
        width,
        height,
    );
}

/// 设置 viewport 的源矩形（buffer 坐标，wl_fixed）
/// 全部传 -1 表示使用整个 buffer
pub fn viewportSetSource(viewport: *WpViewport, x: Fixed, y: Fixed, width: Fixed, height: Fixed) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewport),
        1, // WP_VIEWPORT_SET_SOURCE
        null,
        wl_proxy_get_version(@ptrCast(viewport)),
        0,
        x,
        y,
        width,
        height,
    );
}

/// 销毁 viewport
pub fn viewportDestroy(viewport: *WpViewport) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(viewport),
        0, // WP_VIEWPORT_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(viewport)),
        0,
    );
    wl_proxy_destroy(@ptrCast(viewport));
}

// Callback 操作
pub fn callbackAddListener(callback: *Callback, listener: *const CallbackListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(callback), @ptrCast(listener), data) == 0;
}

pub fn callbackDestroy(callback: *Callback) void {
    wl_proxy_destroy(@ptrCast(callback));
}

// Region 操作
pub fn regionAdd(region: *Region, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(region),
        1, // WL_REGION_ADD
        null,
        wl_proxy_get_version(@ptrCast(region)),
        0,
        x,
        y,
        width,
        height,
    );
}

pub fn regionDestroy(region: *Region) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(region),
        0, // WL_REGION_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(region)),
        MARSHAL_FLAG_DESTROY,
    );
}

// Seat 操作
pub fn seatAddListener(seat: *Seat, listener: *const SeatListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(seat), @ptrCast(listener), data) == 0;
}

pub fn seatGetPointer(seat: *Seat) ?*Pointer {
    const result = wl_proxy_marshal_flags(
        @ptrCast(seat),
        0, // WL_SEAT_GET_POINTER
        &wl_pointer_interface,
        wl_proxy_get_version(@ptrCast(seat)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn seatGetKeyboard(seat: *Seat) ?*Keyboard {
    const result = wl_proxy_marshal_flags(
        @ptrCast(seat),
        1, // WL_SEAT_GET_KEYBOARD
        &wl_keyboard_interface,
        wl_proxy_get_version(@ptrCast(seat)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn seatDestroy(seat: *Seat) void {
    wl_proxy_destroy(@ptrCast(seat));
}

// Pointer 操作
pub fn pointerAddListener(pointer: *Pointer, listener: *const PointerListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(pointer), @ptrCast(listener), data) == 0;
}

pub fn pointerDestroy(pointer: *Pointer) void {
    // 直接 wl_proxy_destroy，不走 release 请求。
    // release 请求要求 wl_seat 版本 3+，并可能带来额外问题。
    wl_proxy_destroy(@ptrCast(pointer));
}

pub fn cursorShapeManagerGetPointer(manager: *WpCursorShapeManagerV1, pointer: *Pointer) ?*WpCursorShapeDeviceV1 {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        1, // get_pointer
        &wp_cursor_shape_device_v1_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
        pointer,
    );
    return @ptrCast(@alignCast(result));
}

pub fn cursorShapeManagerDestroy(manager: *WpCursorShapeManagerV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn cursorShapeDeviceSetShape(device: *WpCursorShapeDeviceV1, serial: u32, shape: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(device),
        1, // set_shape
        null,
        wl_proxy_get_version(@ptrCast(device)),
        0,
        serial,
        shape,
    );
}

pub fn cursorShapeDeviceDestroy(device: *WpCursorShapeDeviceV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(device),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(device)),
        MARSHAL_FLAG_DESTROY,
    );
}

// Keyboard 操作
pub fn keyboardAddListener(keyboard: *Keyboard, listener: *const KeyboardListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(keyboard), @ptrCast(listener), data) == 0;
}

pub fn keyboardDestroy(keyboard: *Keyboard) void {
    // 直接 wl_proxy_destroy，不走 release 请求。
    // release 请求要求 wl_seat 版本 3+，并可能带来额外问题。
    wl_proxy_destroy(@ptrCast(keyboard));
}

// Touch 操作
pub fn seatGetTouch(seat: *Seat) ?*Touch {
    const result = wl_proxy_marshal_flags(
        @ptrCast(seat),
        2, // WL_SEAT_GET_TOUCH
        &wl_touch_interface,
        wl_proxy_get_version(@ptrCast(seat)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn touchAddListener(touch: *Touch, listener: *const TouchListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(touch), @ptrCast(listener), data) == 0;
}

pub fn touchDestroy(touch: *Touch) void {
    wl_proxy_destroy(@ptrCast(touch));
}

// Output 操作
pub fn outputAddListener(output: *Output, listener: *const OutputListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(output), @ptrCast(listener), data) == 0;
}

pub fn outputDestroy(output: *Output) void {
    wl_proxy_destroy(@ptrCast(output));
}

// =============================================================================
// XDG Shell 封装函数
// =============================================================================

// XDG WM Base
pub fn xdgWmBaseAddListener(wm_base: *XdgWmBase, listener: *const XdgWmBaseListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(wm_base), @ptrCast(listener), data) == 0;
}

pub fn xdgWmBasePong(wm_base: *XdgWmBase, serial: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(wm_base),
        3, // XDG_WM_BASE_PONG (destroy=0, create_positioner=1, get_xdg_surface=2, pong=3)
        null,
        wl_proxy_get_version(@ptrCast(wm_base)),
        0,
        serial,
    );
}

pub fn xdgWmBaseGetXdgSurface(wm_base: *XdgWmBase, surface: *Surface) ?*XdgSurface {
    const result = wl_proxy_marshal_flags(
        @ptrCast(wm_base),
        2, // XDG_WM_BASE_GET_XDG_SURFACE
        &xdg_surface_interface,
        wl_proxy_get_version(@ptrCast(wm_base)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(surface)),
    );
    return @ptrCast(@alignCast(result));
}

pub fn xdgWmBaseDestroy(wm_base: *XdgWmBase) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(wm_base),
        0, // XDG_WM_BASE_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(wm_base)),
        MARSHAL_FLAG_DESTROY,
    );
}

// XDG Surface（xdg_surface 请求封装）
pub fn xdgSurfaceAddListener(xdg_surface: *XdgSurface, listener: *const XdgSurfaceListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(xdg_surface), @ptrCast(listener), data) == 0;
}

pub fn xdgSurfaceGetToplevel(xdg_surface: *XdgSurface) ?*XdgToplevel {
    const result = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        1, // XDG_SURFACE_GET_TOPLEVEL
        &xdg_toplevel_interface,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        0,
        @as(?*anyopaque, null),
    );
    return @ptrCast(@alignCast(result));
}

pub fn xdgSurfaceAckConfigure(xdg_surface: *XdgSurface, serial: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        4, // XDG_SURFACE_ACK_CONFIGURE
        null,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        0,
        serial,
    );
}

pub fn xdgSurfaceSetWindowGeometry(xdg_surface: *XdgSurface, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        3, // XDG_SURFACE_SET_WINDOW_GEOMETRY
        null,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        0,
        x,
        y,
        width,
        height,
    );
}

pub fn xdgSurfaceDestroy(xdg_surface: *XdgSurface) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(xdg_surface),
        0, // XDG_SURFACE_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(xdg_surface)),
        MARSHAL_FLAG_DESTROY,
    );
}

// XDG Toplevel（xdg_toplevel 请求封装）
pub fn xdgToplevelAddListener(toplevel: *XdgToplevel, listener: *const XdgToplevelListener, data: ?*anyopaque) bool {
    return wl_proxy_add_listener(@ptrCast(toplevel), @ptrCast(listener), data) == 0;
}

pub fn xdgToplevelSetTitle(toplevel: *XdgToplevel, title: [*:0]const u8) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        2, // XDG_TOPLEVEL_SET_TITLE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        title,
    );
}

pub fn xdgToplevelSetAppId(toplevel: *XdgToplevel, app_id: [*:0]const u8) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        3, // XDG_TOPLEVEL_SET_APP_ID
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        app_id,
    );
}

pub fn xdgToplevelSetMinSize(toplevel: *XdgToplevel, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        8, // XDG_TOPLEVEL_SET_MIN_SIZE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        width,
        height,
    );
}

pub fn xdgToplevelSetMaxSize(toplevel: *XdgToplevel, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        7, // XDG_TOPLEVEL_SET_MAX_SIZE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        width,
        height,
    );
}

/// 发起交互式移动（用户拖动窗口）
/// 必须在响应指针按扣事件时调用
pub fn xdgToplevelMove(toplevel: *XdgToplevel, seat: *Seat, serial: u32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        5, // XDG_TOPLEVEL_MOVE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        seat,
        serial,
    );
}

/// xdgToplevelResize 用的边缘标志
pub const ResizeEdge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

/// 发起交互式缩放
/// 必须在响应指针按下事件时调用
pub fn xdgToplevelResize(toplevel: *XdgToplevel, seat: *Seat, serial: u32, edges: ResizeEdge) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        6, // XDG_TOPLEVEL_RESIZE
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        0,
        seat,
        serial,
        @backingInt(edges),
    );
}

pub fn xdgToplevelDestroy(toplevel: *XdgToplevel) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(toplevel),
        0, // XDG_TOPLEVEL_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(toplevel)),
        MARSHAL_FLAG_DESTROY,
    );
}

// =============================================================================
// XDG Decoration 封装函数
// =============================================================================

pub fn zxdgDecorationManagerV1GetToplevelDecoration(
    manager: *ZxdgDecorationManagerV1,
    toplevel: *XdgToplevel,
) ?*ZxdgToplevelDecorationV1 {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        1, // ZXDG_DECORATION_MANAGER_V1_GET_TOPLEVEL_DECORATION
        &zxdg_toplevel_decoration_v1_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null),
        @as(*anyopaque, @ptrCast(toplevel)),
    );
    return @ptrCast(@alignCast(result));
}

pub fn zxdgDecorationManagerV1Destroy(manager: *ZxdgDecorationManagerV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        0, // ZXDG_DECORATION_MANAGER_V1_DESTROY
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

pub fn zxdgToplevelDecorationV1AddListener(
    decoration: *ZxdgToplevelDecorationV1,
    listener: *const ZxdgToplevelDecorationV1Listener,
    data: ?*anyopaque,
) bool {
    return wl_proxy_add_listener(@ptrCast(decoration), @ptrCast(listener), data) == 0;
}

pub fn zxdgToplevelDecorationV1SetMode(decoration: *ZxdgToplevelDecorationV1, mode: ZxdgToplevelDecorationV1Mode) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(decoration),
        1, // ZXDG_TOPLEVEL_DECORATION_V1_SET_MODE
        null,
        wl_proxy_get_version(@ptrCast(decoration)),
        0,
        @backingInt(mode),
    );
}

pub fn zxdgToplevelDecorationV1Destroy(decoration: *ZxdgToplevelDecorationV1) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(decoration),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(decoration)),
        MARSHAL_FLAG_DESTROY,
    );
}

// =============================================================================
// Text Input V3 函数（IME 支持）
// =============================================================================

/// 从 text input manager 取一个 text input 对象
pub fn zwpTextInputManagerV3GetTextInput(manager: *ZwpTextInputManagerV3, seat: *Seat) ?*ZwpTextInputV3 {
    return @ptrCast(wl_proxy_marshal_flags(
        @ptrCast(manager),
        1, // get_text_input
        &zwp_text_input_v3_interface,
        wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null), // new_id placeholder
        seat,
    ));
}

/// 销毁 text input manager
pub fn zwpTextInputManagerV3Destroy(manager: *ZwpTextInputManagerV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(manager),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(manager)),
        MARSHAL_FLAG_DESTROY,
    );
}

/// 给 text input 挂 listener
pub fn zwpTextInputV3AddListener(text_input: *ZwpTextInputV3, listener: *const ZwpTextInputV3Listener, data: ?*anyopaque) void {
    _ = wl_proxy_add_listener(@ptrCast(text_input), @ptrCast(listener), data);
}

/// 销毁 text input
pub fn zwpTextInputV3Destroy(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        0, // destroy
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        MARSHAL_FLAG_DESTROY,
    );
}

/// 开启文本输入（开始接收输入）
pub fn zwpTextInputV3Enable(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        1, // enable
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
    );
}

/// 关闭文本输入（停止接收输入）
pub fn zwpTextInputV3Disable(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        2, // disable
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
    );
}

/// 设置上下文用的周边文本
pub fn zwpTextInputV3SetSurroundingText(text_input: *ZwpTextInputV3, text: [*:0]const u8, cursor: i32, anchor: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        3, // set_surrounding_text
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        text,
        cursor,
        anchor,
    );
}

/// 设置文本变更原因
pub fn zwpTextInputV3SetTextChangeCause(text_input: *ZwpTextInputV3, cause: ZwpTextInputV3ChangeCause) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        4, // set_text_change_cause
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        @backingInt(cause),
    );
}

/// 设置内容类型（hint 位与 purpose）
pub fn zwpTextInputV3SetContentType(text_input: *ZwpTextInputV3, hint: ZwpTextInputV3ContentHint, purpose: ZwpTextInputV3ContentPurpose) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        5, // set_content_type
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        @as(u32, @bitCast(hint)),
        @backingInt(purpose),
    );
}

/// 设置 IME 候选窗定位用的光标矩形
pub fn zwpTextInputV3SetCursorRectangle(text_input: *ZwpTextInputV3, x: i32, y: i32, width: i32, height: i32) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        6, // set_cursor_rectangle
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
        x,
        y,
        width,
        height,
    );
}

/// 提交累积的待应用状态
pub fn zwpTextInputV3Commit(text_input: *ZwpTextInputV3) void {
    _ = wl_proxy_marshal_flags(
        @ptrCast(text_input),
        7, // commit
        null,
        wl_proxy_get_version(@ptrCast(text_input)),
        0,
    );
}

// =============================================================================
// 辅助常量
// =============================================================================

/// Linux 按钮码（取自 linux/input-event-codes.h）
pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

/// 供 registry bind 用的接口名常量
pub const WL_COMPOSITOR_INTERFACE_NAME = "wl_compositor";
pub const WL_SHM_INTERFACE_NAME = "wl_shm";
pub const WL_SEAT_INTERFACE_NAME = "wl_seat";
pub const WL_OUTPUT_INTERFACE_NAME = "wl_output";
pub const XDG_WM_BASE_INTERFACE_NAME = "xdg_wm_base";
pub const ZXDG_DECORATION_MANAGER_V1_INTERFACE_NAME = "zxdg_decoration_manager_v1";
pub const ZWP_TEXT_INPUT_MANAGER_V3_INTERFACE_NAME = "zwp_text_input_manager_v3";
pub const WP_VIEWPORTER_INTERFACE_NAME = "wp_viewporter";
pub const WP_CURSOR_SHAPE_MANAGER_V1_INTERFACE_NAME = "wp_cursor_shape_manager_v1";

// =============================================================================
// wp_viewporter 接口（HiDPI 支持）
// =============================================================================

// wp_viewporter 方法：destroy, get_viewport
const wp_viewporter_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_viewport", .signature = "no", .types = @ptrCast(&wp_viewporter_get_viewport_types) },
};

pub const wp_viewporter_interface: Interface = .{
    .name = "wp_viewporter",
    .version = 1,
    .method_count = 2,
    .methods = @ptrCast(&wp_viewporter_methods),
    .event_count = 0,
    .events = null,
};

// wp_cursor_shape_manager_v1 方法：destroy, get_pointer, get_tablet_tool_v2
const wp_cursor_shape_manager_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_pointer", .signature = "no", .types = @ptrCast(&wp_cursor_shape_manager_v1_get_pointer_types) },
    .{ .name = "get_tablet_tool_v2", .signature = "no", .types = null },
};

pub const wp_cursor_shape_manager_v1_interface: Interface = .{
    .name = "wp_cursor_shape_manager_v1",
    .version = 2,
    .method_count = 3,
    .methods = @ptrCast(&wp_cursor_shape_manager_v1_methods),
    .event_count = 0,
    .events = null,
};

// wp_cursor_shape_device_v1 方法：destroy, set_shape
const wp_cursor_shape_device_v1_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_shape", .signature = "uu", .types = null },
};

pub const wp_cursor_shape_device_v1_interface: Interface = .{
    .name = "wp_cursor_shape_device_v1",
    .version = 2,
    .method_count = 2,
    .methods = @ptrCast(&wp_cursor_shape_device_v1_methods),
    .event_count = 0,
    .events = null,
};

// wp_viewport 方法：destroy, set_source, set_destination
const wp_viewport_methods = [_]Message{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_source", .signature = "ffff", .types = null }, // wl_fixed x, y, width, height
    .{ .name = "set_destination", .signature = "ii", .types = null }, // int32 width, height
};

pub const wp_viewport_interface: Interface = .{
    .name = "wp_viewport",
    .version = 1,
    .method_count = 3,
    .methods = @ptrCast(&wp_viewport_methods),
    .event_count = 0,
    .events = null,
};
