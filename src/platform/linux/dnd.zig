//! Linux/Wayland 文件拖放 —— `wl_data_device` DnD(接收端)。
//!
//! 只实现"别的应用把文件拖进来"方向的语义:`wl_data_device` 的
//! `enter/motion/leave/drop` 事件 + 从 source 经 pipe 读 `text/uri-list`。
//! 剪贴板(getText/setText、`wl_data_source` 出数据方向)已随剪贴板
//! 能力整体删除 —— 事件层不需要它,引擎自己也没有入口做(Wayland 的
//! 拖放绑定在库的注册表/事件循环里,这点与 Windows 的 OLE 同理)。
//!
//! 事件语义:
//! - `enter`  → `.entered`(surface铭记窗口、坐标、serial;发 `accept`)
//! - `motion` → `.moved`
//! - `leave`  → `.exited`(撤销 accept 并销毁 offer)
//! - `drop`   → receive(`text/uri-list`)→ 解析 `file://` URI → `.dropped`
//!
//! 异步语义:`wl_data_offer.receive` 是**异步**的 —— compositor 转端给
//! source 进程写 pipe,数据可能落在 drop 事件之后。windowkit 的约定是
//! 在 drop 回调里**同步阻塞**读到 EOF(GLFW 同款取舍:文件列表是小事
//! 一行,source 在下一次调度内即写完;source 卡死会拖住 UI,可接受),
//! 读完才派发 `.dropped`,所以 `paths` 生命周期契约仍然满足 —— 派发
//! 之后立即释放,ParsedPaths 可复用。

const std = @import("std");
const wayland = @import("wayland.zig");

// =============================================================================
// wl_data_device 协议类型与 listener 布局（事件方向）
// =============================================================================

pub const WlDataDeviceManager = opaque {};
pub const WlDataDevice = opaque {};
pub const WlDataSource = opaque {}; // 仅 opaque 占位(bind 不再创建)
pub const WlDataOffer = opaque {};

/// Data offer listener:mime 通告 + DnD 动作协商反馈。
pub const WlDataOfferListener = extern struct {
    /// 通告 source 提供的 mime 类型
    offer: *const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        mime_type: [*:0]const u8,
    ) callconv(.c) void,
    /// source 可提供的 DnD 动作（version 3+）
    source_actions: ?*const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        source_actions: u32,
    ) callconv(.c) void = null,
    /// compositor 选定的动作（version 3+）
    action: ?*const fn (
        data: ?*anyopaque,
        data_offer: *WlDataOffer,
        dnd_action: u32,
    ) callconv(.c) void = null,
};

/// Data device listener(事件方向)。selection 项保留但恒 null:剪贴板
/// 删除后我们不出不进选区,但数据布局里归位以防 probe 出错。
pub const WlDataDeviceListener = extern struct {
    /// 新建 data offer（选区和 DnD 都走这里）
    data_offer: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        id: *WlDataOffer,
    ) callconv(.c) void = null,
    /// DnD enter
    enter: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        serial: u32,
        surface: ?*wayland.Surface,
        x: i32,
        y: i32,
        id: ?*WlDataOffer,
    ) callconv(.c) void = null,
    /// DnD leave
    leave: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
    ) callconv(.c) void = null,
    /// DnD motion
    motion: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        time: u32,
        x: i32,
        y: i32,
    ) callconv(.c) void = null,
    /// DnD drop
    drop: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
    ) callconv(.c) void = null,
    /// Selection changed(剪贴板已删,我们不处理选区)
    selection: ?*const fn (
        data: ?*anyopaque,
        data_device: *WlDataDevice,
        id: ?*WlDataOffer,
    ) callconv(.c) void = null,
};

// =============================================================================
// 协议接口声明（libwayland-client 全局接口对象,绑定 registry 用）
// =============================================================================

pub extern "wayland-client" var wl_data_device_manager_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_device_interface: wayland.Interface;
pub extern "wayland-client" var wl_data_offer_interface: wayland.Interface;

// =============================================================================
// 协议常量
// =============================================================================

pub const WL_DATA_DEVICE_MANAGER_INTERFACE_NAME = "wl_data_device_manager";

/// 只认的文件列表 MIME(uri-list 是 XDG 规范;浏览器与各文件管理器都出)。
pub const MIME_URI_LIST = "text/uri-list";

/// `wl_data_offer.set_actions` / `action` 事件的 DnD 动作位。
pub const DND_ACTION_NONE: u32 = 0;
pub const DND_ACTION_COPY: u32 = 1;
pub const DND_ACTION_MOVE: u32 = 2;
pub const DND_ACTION_ASK: u32 = 4;

// Data device manager 方法 opcode
const WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE = 1;

// Data device 方法 opcode（start_drag=0 不用,我们只做接收端）
const WL_DATA_DEVICE_RELEASE = 2;

// Data offer 方法 opcode（destroy=2）
const WL_DATA_OFFER_ACCEPT = 0;
const WL_DATA_OFFER_RECEIVE = 1;
const WL_DATA_OFFER_DESTROY = 2;
const WL_DATA_OFFER_FINISH = 3; // version 3+
const WL_DATA_OFFER_SET_ACTIONS = 4; // version 3+

// =============================================================================
// 封装函数
// =============================================================================

pub fn dataDeviceManagerGetDataDevice(manager: *WlDataDeviceManager, seat: *wayland.Seat) ?*WlDataDevice {
    return @ptrCast(wayland.wl_proxy_marshal_flags(
        @ptrCast(manager),
        WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE,
        &wl_data_device_interface,
        wayland.wl_proxy_get_version(@ptrCast(manager)),
        0,
        @as(?*anyopaque, null), // new_id placeholder
        seat,
    ));
}

pub fn dataDeviceRelease(device: *WlDataDevice) void {
    // wl_data_device version range: 1-3;version 2 起 offer release。
    const version = wayland.wl_proxy_get_version(@ptrCast(device));
    std.debug.assert(version >= 1 and version <= 3);
    if (version >= 2) {
        _ = wayland.wl_proxy_marshal_flags(
            @ptrCast(device),
            WL_DATA_DEVICE_RELEASE,
            null,
            version,
            wayland.MARSHAL_FLAG_DESTROY,
        );
    } else {
        wayland.wl_proxy_destroy(@ptrCast(device));
    }
}

pub fn dataDeviceAddListener(device: *WlDataDevice, listener: *const WlDataDeviceListener, data: ?*anyopaque) c_int {
    return wayland.wl_proxy_add_listener(@ptrCast(device), @ptrCast(listener), data);
}

pub fn dataOfferAddListener(offer: *WlDataOffer, listener: *const WlDataOfferListener, data: ?*anyopaque) c_int {
    return wayland.wl_proxy_add_listener(@ptrCast(offer), @ptrCast(listener), data);
}

/// 目标端接受一种 mime(serial 是 `enter` 的 serial)。
pub fn dataOfferAccept(offer: *WlDataOffer, serial: u32, mime_type: ?[*:0]const u8) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_ACCEPT,
        null,
        wayland.wl_proxy_get_version(@ptrCast(offer)),
        0,
        serial,
        mime_type,
    );
}

pub fn dataOfferReceive(offer: *WlDataOffer, mime_type: [*:0]const u8, fd: i32) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_RECEIVE,
        null,
        wayland.wl_proxy_get_version(@ptrCast(offer)),
        0,
        mime_type,
        fd,
    );
}

/// DnD 事务收尾(version 3+;move 语义必须,读不到不 finish)。
pub fn dataOfferFinish(offer: *WlDataOffer) void {
    if (wayland.wl_proxy_get_version(@ptrCast(offer)) < 3) return;
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_FINISH,
        null,
        3,
        0,
    );
}

/// 协商动作:preferred=我们希望的(按住修饰键时用户/合成器可改),
/// 这包装会句 offer 版本 >= 3 再发。
pub fn dataOfferSetActions(offer: *WlDataOffer, preferred_actions: u32, allowed_actions: u32) void {
    if (wayland.wl_proxy_get_version(@ptrCast(offer)) < 3) return;
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_SET_ACTIONS,
        null,
        wayland.wl_proxy_get_version(@ptrCast(offer)),
        0,
        preferred_actions,
        allowed_actions,
    );
}

pub fn dataOfferDestroy(offer: *WlDataOffer) void {
    _ = wayland.wl_proxy_marshal_flags(
        @ptrCast(offer),
        WL_DATA_OFFER_DESTROY,
        null,
        wayland.wl_proxy_get_version(@ptrCast(offer)),
        wayland.MARSHAL_FLAG_DESTROY,
    );
}

// =============================================================================
// URI -> 路径 解析(纯函数,可直接单测)
// =============================================================================

/// 单次拖放的路径解析结果(每条是绝对路径、UTF-8)。
/// 生命周期:`dropped` 回调期间有效,派发后可整体复用。
pub const ParsedPaths = struct {
    pub const max_paths = 64;
    pub const max_path_len = 1024;

    path_buf: [max_paths][max_path_len]u8 = undefined,
    path_lens: [max_paths]usize = undefined, // 由 parseUriList 填充
    count: usize = 0,

    pub fn slices(self: *const ParsedPaths) []const []const u8 {
        // 陷阱说明:绝不能在这里返回局部数组的切片(Windows 后端踩过,
        // 外层切片数组随函数返回即悬垂)。正确用法是下面的 `buildSlices`,
        // 由调用方帧提供输出数组。
        _ = self;
        @compileError("use buildSlices with a caller-provided out array instead");
    }

    /// 供回调派发用的安全切片:`dst` 至少 max_paths 项、由调用方栈帧
    /// 提供(见 `platform.zig` 的 dndDrop 回调,与 Windows 后端
    /// `drop_target.buildPaths` 同一模式)。
    pub fn buildSlices(self: *const ParsedPaths, dst: *[max_paths][]const u8) []const []const u8 {
        for (0..self.count) |i| {
            dst[i] = self.path_buf[i][0..self.path_lens[i]];
        }
        return dst[0..self.count];
    }
};

/// 解析 `text/uri-list`:每行一个 URI,\r\n / \n 分行,`#` 注释跳过,
/// 只认 `file://`。`localhost` 主机名剥掉(`file://localhost/etc/x` →
/// `/etc/x`)。非文件 URI 与超长路径(> max_path_len)整条跳过,计数
/// 照常推进。
pub fn parseUriList(bytes: []const u8, out: *ParsedPaths) void {
    out.count = 0;
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line_raw| {
        if (out.count >= ParsedPaths.max_paths) return;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const rest = stripFileScheme(line) orelse continue;
        const encoded = trimLocalhost(rest);
        if (encoded.len == 0 or encoded.len > ParsedPaths.max_path_len) continue;

        // percent-decode(uri-list 是 URL 语义,空格/中文都是 %XX)
        const n = decodePercent(&out.path_buf[out.count], encoded);
        if (n == 0) continue;
        out.path_lens[out.count] = n;
        out.count += 1;
    }
}

/// `file://...` → `...`;其他 scheme(ftp:/smb:/# 注释)返回 null。
fn stripFileScheme(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "file://")) return null;
    return line["file://".len..];
}

/// `localhost/...` → `...`(file:// 之后可以写 host;只处理 localhost,
/// 带 nick/utf-8 的 host 名不在 X 环境下出现)。
fn trimLocalhost(rest: []const u8) []const u8 {
    if (std.mem.startsWith(u8, rest, "localhost/")) {
        return rest["localhost/".len..];
    }
    return rest;
}

/// 百分号解码,返回解码后长度;`%XX` 之外的字符原样拷贝。
pub fn decodePercent(dst: []u8, src: []const u8) usize {
    var dst_i: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '%') {
            dst[dst_i] = src[i];
            dst_i += 1;
            i += 1;
            continue;
        }
        // %XX 需要两个 hex
        if (i + 2 < src.len and std.ascii.isHex(src[i + 1]) and std.ascii.isHex(src[i + 2])) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch unreachable;
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch unreachable;
            dst[dst_i] = @as(u8, @intCast(hi)) << 4 | @as(u8, @intCast(lo));
            dst_i += 1;
            i += 3;
        } else {
            // 不成对的 % —— 原样保留(URL 的歧义交给调用方)
            dst[dst_i] = src[i];
            dst_i += 1;
            i += 1;
        }
    }
    return dst_i;
}

// =============================================================================
// DnD 状态(协议侧;窗口定位/事件派发在 platform.zig)
// =============================================================================

const MAX_TRANSFER_BYTES = 1 * 1024 * 1024;

pub const DndState = struct {
    const Self = @This();

    data_device_manager: ?*WlDataDeviceManager = null,
    data_device: ?*WlDataDevice = null,
    display: ?*wayland.Display = null,

    /// 当前 DnD offer(enter 给出;leave/drop 后清空)。
    dnd_offer: ?*WlDataOffer = null,
    offer_has_uri_list: bool = false,
    /// offer 对象的 mime 由 data_offer → offer(mime) 事件流带过来,
    /// 顺序可能比 `enter` 晚:每个 offer 记录自己的判定,enter 时取走。
    offer_probe_uri_list: bool = false,
    probe_offer: ?*WlDataOffer = null,
    probe_has_uri_list: bool = false,
    enter_serial: u32 = 0,
    enter_x: i32 = 0,
    enter_y: i32 = 0,

    /// drop 时 동시解析结果(平台侧读 buffer → 本结构)。
    parsed: ParsedPaths = .{},

    const offer_listener = WlDataOfferListener{
        .offer = offerMimeCallback,
        .source_actions = null, // 动作协商只是信息,引擎契约不需要
        .action = null,
    };

    /// 进入拖放(enter 事件):记录 offer/serial/坐标,发 accept +
    /// set_actions。调用方已保证 `offer != null`。
    pub fn beginDrag(self: *Self, offer: *WlDataOffer, serial: u32, x: i32, y: i32) void {
        self.dnd_offer = offer;
        self.offer_has_uri_list = if (self.probe_offer == offer) self.probe_has_uri_list else false;
        self.probe_offer = null;
        self.probe_has_uri_list = false;
        self.enter_serial = serial;
        self.enter_x = x;
        self.enter_y = y;

        // accept:必须对 serial + mime_type;这里无条件接受 uri-list,
        // 对非路由源的合成器也安全(合成器只看 mime 匹配与否)。
        dataOfferAccept(offer, serial, MIME_URI_LIST);
        // 动作协商:composer 会在 `action` 事件回传最终选择。
        dataOfferSetActions(
            offer,
            DND_ACTION_COPY | DND_ACTION_MOVE, // preferred(我们只是读路径,任选都行)
            DND_ACTION_COPY | DND_ACTION_MOVE, // allowed
        );
    }

    /// 目标端拒绝 drag:`accept(serial, null)` + 无动作 → 合成器显示
    /// “不可放下”光标。(窗口 `options.file_drop = false` 时用。)
    pub fn refuseDrag(self: *Self, offer: *WlDataOffer, serial: u32) void {
        _ = self;
        dataOfferAccept(offer, serial, null);
        dataOfferSetActions(offer, DND_ACTION_NONE, DND_ACTION_NONE);
    }

    pub fn endDrag(self: *Self) void {
        if (self.dnd_offer) |offer| {
            dataOfferDestroy(offer);
            self.dnd_offer = null;
        }
        self.offer_has_uri_list = false;
    }

    /// data_offer 事件:给新 offer 对象挂 mime listener。上一个 probe
    /// 若没被 beginDrag 领走(selection offer),销毁防 proxy 泄漏。
    pub fn trackOffer(self: *Self, offer: *WlDataOffer) void {
        if (self.probe_offer) |old| dataOfferDestroy(old);
        self.probe_offer = offer;
        self.probe_has_uri_list = false;
        _ = dataOfferAddListener(offer, &Self.offer_listener, self);
    }

    /// offer(mime) 事件:登记是否带 uri-list。
    pub fn recordMime(self: *Self, offer: *WlDataOffer, mime_type: [*:0]const u8) void {
        if (!std.mem.eql(u8, std.mem.span(mime_type), MIME_URI_LIST)) return;
        if (self.probe_offer == offer) self.probe_has_uri_list = true;
        // mime 比 enter 晚到的兜底:进入中的 drag 出现 uri-list,
        // 直接置位(enter 时 unknown 则 entered 缺发,后续照常)。
        if (self.dnd_offer == offer) self.offer_has_uri_list = true;
    }

    /// drop:拿 uri-list。直接同步读 pipe(receive 之后 flush)。
    /// 返回堆上字节,调用方 `allocator.free`。
    pub fn receiveUriList(self: *Self, allocator: std.mem.Allocator) ?[]const u8 {
        const offer = self.dnd_offer orelse return null;

        var pipe_fds: [2]i32 = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return null;
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];

        dataOfferReceive(offer, MIME_URI_LIST, write_fd);
        if (self.display) |display| _ = wayland.wl_display_flush(display);

        // 只读不写,立刻关写端。std.posix.close 在 Zig 0.16 已移除
        // (见 0.16 release notes "posix and os.windows removals"),本模块
        // 链接 libc,直接调 std.c 的符号。
        _ = std.c.close(@intCast(write_fd));

        // 指数扩容读满 EOF,上限 MAX_TRANSFER_BYTES(超出截断 —— 路径
        // 列表正常远小于此,截断保命优于挂死)。
        var buffer: []u8 = allocator.alloc(u8, 4096) catch {
            _ = std.c.close(@intCast(read_fd));
            return null;
        };
        errdefer allocator.free(buffer);
        var filled: usize = 0;
        while (filled < MAX_TRANSFER_BYTES) {
            if (filled == buffer.len) {
                const next_len = @min(buffer.len * 2, MAX_TRANSFER_BYTES);
                buffer = allocator.realloc(buffer, next_len) catch break;
            }
            const n = std.posix.read(@intCast(read_fd), buffer[filled..]) catch break;
            if (n == 0) break; // EOF
            filled += n;
        }
        _ = std.c.close(@intCast(read_fd));

        if (filled == 0) {
            allocator.free(buffer);
            return null;
        }
        buffer = allocator.realloc(buffer, filled) catch buffer;
        return buffer[0..filled];
    }

    pub fn deinit(self: *Self) void {
        self.endDrag();
        if (self.data_device) |device| {
            dataDeviceRelease(device);
            self.data_device = null;
        }
        self.data_device_manager = null;
        self.display = null;
    }

    pub fn bindManager(self: *Self, registry: *wayland.Registry, name: u32, version: u32) void {
        self.data_device_manager = @ptrCast(@alignCast(wayland.registryBind(
            registry,
            name,
            &wl_data_device_manager_interface,
            @min(version, 3),
        )));
    }

    pub fn setupDataDevice(self: *Self, seat: *wayland.Seat, display: *wayland.Display) void {
        if (self.data_device_manager == null) return;
        if (self.data_device != null) return;

        self.display = display;
        self.data_device = dataDeviceManagerGetDataDevice(self.data_device_manager.?, seat);
        // listener 由 platform.zig 装配(6 个事件槽必须全非空,否则
        // compositor 一派发就空指针;platform 侧的回调负责窗口定位与
        // 事件派发,protocol 层不掺和)。
    }
};

fn offerMimeCallback(data: ?*anyopaque, offer: *WlDataOffer, mime_type: [*:0]const u8) callconv(.c) void {
    const state: *DndState = @ptrCast(@alignCast(data));
    state.recordMime(offer, mime_type);
}

fn dataOfferArrivalCallback(data: ?*anyopaque, _: *WlDataDevice, offer: *WlDataOffer) callconv(.c) void {
    const state: *DndState = @ptrCast(@alignCast(data));
    state.trackOffer(offer);
}

var global_state: DndState = .{};

/// 平台全局单例(platform.zig 接线用)。
pub fn getState() *DndState {
    return &global_state;
}

// =============================================================================
// Tests(纯函数:URI 解析不依赖任何 Wayland 对象)
// =============================================================================

const testing = std.testing;

test "parseUriList two paths with CRLF" {
    const input = "file:///opt/models/a.glb\r\nfile:///opt/models/b.png\r\n";
    var parsed: ParsedPaths = .{};
    parseUriList(input, &parsed);
    try testing.expectEqual(@as(usize, 2), parsed.count);
    try testing.expectEqualStrings("/opt/models/a.glb", parsed.path_buf[0][0..parsed.path_lens[0]]);
    try testing.expectEqualStrings("/opt/models/b.png", parsed.path_buf[1][0..parsed.path_lens[1]]);
}

test "parseUriList strips localhost hostname" {
    var parsed: ParsedPaths = .{};
    parseUriList("file://localhost/etc/hosts\n", &parsed);
    try testing.expectEqual(@as(usize, 1), parsed.count);
    try testing.expectEqualStrings("/etc/hosts", parsed.path_buf[0][0..parsed.path_lens[0]]);
}

test "parseUriList skips comments, non-file schemes, empty lines" {
    var parsed: ParsedPaths = .{};
    parseUriList(
        "# ref: https://example.com\nftp://example.com/x\n\nfile:///a/b\ntext://line\n",
        &parsed,
    );
    try testing.expectEqual(@as(usize, 1), parsed.count);
    try testing.expectEqualStrings("/a/b", parsed.path_buf[0][0..parsed.path_lens[0]]);
}

test "parseUriList percent-decoding spaces and CJK" {
    var parsed: ParsedPaths = .{};
    parseUriList("file:///opt/my%20models/%E4%B8%AD%E6%96%87.glb\n", &parsed);
    try testing.expectEqual(@as(usize, 1), parsed.count);
    try testing.expectEqualStrings(
        "/opt/my models/中文.glb",
        parsed.path_buf[0][0..parsed.path_lens[0]],
    );
}

test "parseUriList skips overlong path" {
    var parsed: ParsedPaths = .{};
    // file:/// + (max_path_len+1) 个 'a' → 路径超限,整条跳过;
    // 后面的正常路径照常收。
    const over_len = ParsedPaths.max_path_len + 1;
    const long_block = std.testing.allocator.alloc(u8, over_len) catch return error.OutOfMemory;
    defer std.testing.allocator.free(long_block);
    @memset(long_block, 'a');

    const input = try std.fmt.allocPrint(
        std.testing.allocator,
        "file:///{s}\nfile:///ok\n",
        .{long_block},
    );
    defer std.testing.allocator.free(input);

    parseUriList(input, &parsed);
    try testing.expectEqual(@as(usize, 1), parsed.count);
    try testing.expectEqualStrings("/ok", parsed.path_buf[0][0..parsed.path_lens[0]]);
}

test "parseUriList stops after path limit" {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    for (0..ParsedPaths.max_paths + 6) |i| {
        const line = std.fmt.bufPrint(buf[total..], "file:///f/d{d}\n", .{i}) catch unreachable;
        total += line.len;
    }
    var parsed: ParsedPaths = .{};
    parseUriList(buf[0..total], &parsed);
    try testing.expectEqual(ParsedPaths.max_paths, parsed.count);
}

test "decodePercent keeps stray percent" {
    var dst: [16]u8 = undefined;
    const n = decodePercent(&dst, "a%2zb%");
    try testing.expectEqualStrings("a%2zb%", dst[0..n]);
}
