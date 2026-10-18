//! Windows 文件拖放 —— COM `IDropTarget`。
//!
//! 为什么它属于窗口库:拖放目标必须挂在**这个窗口**的 HWND 上
//! (`RegisterDragDrop`),而 HWND 归窗口库所有 —— 引擎在库外没有入口。
//! 这与文件**对话框**不同:对话框是应用主动发起的模态 UI,拖放是 OS
//! 推给窗口的被动事件,和键盘/IME 是同类。GLFW 同样只有 drop callback。
//!
//! 生命周期:窗口创建后 `create` + `register`(ref 2:窗口 1 份 +
//! OLE 1 份);`WM_DESTROY` 里 `unregister`(RevokeDragDrop 放掉 OLE
//! 那份)+ `releaseRef` 归零释放。所有 COM 回调都发生在 UI 线程
//! (STA,platform 初始化时 OleInitialize),与窗口天然串行。
//!
//! 契约:`.file_drop` 事件里的 `paths` **只在回调期间有效**(见
//! `input.FileDropEvent`),要留存必须自行拷贝。

const std = @import("std");
const win32 = @import("win32.zig");
const geometry = @import("../../geometry.zig");
const input = @import("../../input/events.zig");
const window_mod = @import("window.zig");

/// 单次拖放最多报告的路径数;超出的文件被丢弃(不截断列表语义)。
pub const max_drop_paths: usize = 16;
/// 单个路径的 UTF-8 字节上限;超长的路径整条跳过(半截路径没意义)。
pub const max_drop_path_bytes: usize = 1024;

/// COM 拖放目标。extern struct 保证 `vtable` 在偏移 0(COM ABI 要求);
/// 字段只用 extern 兼容类型(指针/整数/数组),原子操作直接用
/// `@atomic*` 内建打在 `ref_count` 字段上。
pub const DropTarget = extern struct {
    vtable: *const win32.IDropTargetVTable,
    ref_count: u32,
    /// 事件派发目的地。不变量:OLE 只在 RegisterDragDrop ~ RevokeDragDrop
    /// 期间持有本对象,而 revoke 在 WM_DESTROY 里、窗口内存释放前执行,
    /// 所以回调期间 window 必然存活。
    window: *window_mod.Window,
    /// 当前拖入序列携带的是不是文件(DragLeave 用它过滤非文件拖放)。
    has_files: bool,

    path_buf: [max_drop_paths][max_drop_path_bytes]u8,
    path_lens: [max_drop_paths]u32,
    path_count: u32,

    const Self = @This();

    // =========================================================================
    // 生命周期
    // =========================================================================

    /// 分配并初始化(ref = 1,窗口自己持有那份)。
    pub fn create(allocator: std.mem.Allocator, window: *window_mod.Window) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .vtable = &vtable,
            .ref_count = 1,
            .window = window,
            .has_files = false,
            .path_buf = undefined,
            .path_lens = undefined,
            .path_count = 0,
        };
        return self;
    }

    /// 挂到窗口的 HWND 上(OLE 会 AddRef)。失败返回 false —— 窗口照常
    /// 可用,只是收不到拖放(COM 未初始化之类的边角情况)。
    pub fn register(self: *Self) bool {
        const hwnd = self.window.hwnd orelse return false;
        const hr = win32.RegisterDragDrop(hwnd, @ptrCast(self));
        return win32.SUCCEEDED.check(hr);
    }

    /// 从 HWND 上摘掉(OLE 放掉它那份引用)。必须在窗口销毁前调用。
    pub fn unregister(self: *Self) void {
        if (self.window.hwnd) |hwnd| _ = win32.RevokeDragDrop(hwnd);
    }

    /// 放掉一份引用;归零时经窗口 allocator 释放自身。
    pub fn releaseRef(self: *Self) void {
        const left = @atomicRmw(u32, &self.ref_count, .Sub, 1, .acq_rel) - 1;
        if (left == 0) self.window.allocator.destroy(self);
    }

    // =========================================================================
    // 事件派发
    // =========================================================================

    /// POINTL 是屏幕坐标,转客户区(与鼠标事件同一坐标系)后派发。
    fn dispatch(
        self: *Self,
        phase: input.FileDropPhase,
        paths: []const []const u8,
        pt: win32.POINTL,
        key_state: win32.DWORD,
    ) void {
        var p = win32.POINT{ .x = pt.x, .y = pt.y };
        _ = win32.ScreenToClient(self.window.hwnd, &p);

        _ = self.window.handleInput(.{ .file_drop = .{
            .phase = phase,
            .paths = paths,
            .position = geometry.Point(f64).init(@floatFromInt(p.x), @floatFromInt(p.y)),
            .modifiers = modifiersFromKeyState(key_state),
        } });
    }

    /// 把解析结果组装成切片数组,写入**调用方提供的**缓冲(至少
    /// `max_drop_paths` 项),返回有效项。切片指向本对象的 `path_buf`,
    /// 因此只在回调期间有效 —— 调用方(`drop`)的栈帧在派发期间必然存活。
    ///
    /// 注意:这里绝不能自己开栈数组返回 —— 外层切片数组会随函数返回
    /// 悬垂,回调读到垃圾指针直接 ACCESS_VIOLATION(真机踩过)。
    fn buildPaths(self: *Self, out: *[max_drop_paths][]const u8) []const []const u8 {
        const n: usize = self.path_count;
        for (0..n) |i| {
            out[i] = self.path_buf[i][0..self.path_lens[i]];
        }
        return out[0..n];
    }

    /// 解析 CF_HDROP 内存块(`DROPFILES` 头 + 双 NUL 结尾的路径列表)。
    /// 纯函数式的字节解析,单测直接喂合成块。
    fn parsePaths(self: *Self, block: []const u8) void {
        self.path_count = 0;
        if (block.len < @sizeOf(win32.DROPFILES)) return;

        const hdr: *const win32.DROPFILES = @ptrCast(@alignCast(block.ptr));
        if (hdr.pFiles >= block.len) return;
        const list = block[hdr.pFiles..];

        if (hdr.fWide != 0) {
            self.parseWideList(list);
        } else {
            self.parseAnsiList(list);
        }
    }

    /// UTF-16 列表:每条 NUL 结尾,空条目(连续两个 NUL)= 列表结束。
    fn parseWideList(self: *Self, list: []const u8) void {
        var i: usize = 0;
        while (i + 1 < list.len and self.path_count < max_drop_paths) {
            if (list[i] == 0 and list[i + 1] == 0) break; // 双 NUL 终止
            var end = i;
            while (end + 1 < list.len and !(list[end] == 0 and list[end + 1] == 0)) end += 2;

            // list 来自 GlobalLock 的 HGLOBAL(≥8 对齐),pFiles=20 + 偶数
            // 步进 → 恒 2 对齐,可以安全当 u16 读。
            const units: [*]const u16 = @ptrCast(@alignCast(list.ptr + i));
            const unit_len = (end - i) / 2;

            const n = self.path_count;
            if (std.unicode.utf16LeToUtf8(&self.path_buf[n], units[0..unit_len])) |len| {
                self.path_lens[n] = @intCast(len);
                self.path_count += 1;
            } else |_| {} // 非法 UTF-16 或超长 → 跳过这条

            i = end + 2;
        }
    }

    /// ANSI 列表(老程序的 CF_HDROP):按字节拷贝,语义从简。
    fn parseAnsiList(self: *Self, list: []const u8) void {
        var i: usize = 0;
        while (i < list.len and self.path_count < max_drop_paths) {
            const end = std.mem.indexOfScalar(u8, list[i..], 0) orelse break;
            if (end == 0) break; // 双 NUL 终止

            const n = self.path_count;
            const copy_len = @min(end, max_drop_path_bytes);
            @memcpy(self.path_buf[n][0..copy_len], list[i..][0..copy_len]);
            self.path_lens[n] = @intCast(copy_len);
            self.path_count += 1;

            i += end + 1;
        }
    }

    // =========================================================================
    // COM 回调(静态;经 vtable 进来)
    // =========================================================================

    fn queryInterface(
        this: *const anyopaque,
        riid: *const win32.GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) win32.HRESULT {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        if (std.meta.eql(riid.*, win32.IID_IDropTarget) or std.meta.eql(riid.*, win32.IID_IUnknown)) {
            ppv.* = @ptrCast(self);
            _ = addRef(this);
            return win32.S_OK;
        }
        ppv.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(this: *const anyopaque) callconv(.winapi) win32.ULONG {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        return @atomicRmw(u32, &self.ref_count, .Add, 1, .acq_rel) + 1;
    }

    fn release(this: *const anyopaque) callconv(.winapi) win32.ULONG {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        self.releaseRef();
        return @atomicLoad(u32, &self.ref_count, .acquire);
    }

    /// 拖入:数据对象带 CF_HDROP 才算文件拖放;否则回报 NONE 不发事件。
    fn dragEnter(
        this: *const anyopaque,
        data_obj: ?*anyopaque,
        key_state: win32.DWORD,
        pt: win32.POINTL,
        effect: *win32.DWORD,
    ) callconv(.winapi) win32.HRESULT {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        self.has_files = offersFileDrop(data_obj) and self.window.file_drop_enabled;
        effect.* = if (self.has_files) effectForKeyState(key_state) else win32.DROPEFFECT_NONE;
        if (self.has_files) {
            self.dispatch(.entered, &.{}, pt, key_state);
        }
        return win32.S_OK;
    }

    /// 悬停移动:同样只在文件拖放时报效果(非 NONE 时 OLE 才会继续
    /// 发 DragOver)。
    fn dragOver(
        this: *const anyopaque,
        key_state: win32.DWORD,
        pt: win32.POINTL,
        effect: *win32.DWORD,
    ) callconv(.winapi) win32.HRESULT {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        effect.* = if (self.has_files) effectForKeyState(key_state) else win32.DROPEFFECT_NONE;
        if (self.has_files) {
            self.dispatch(.moved, &.{}, pt, key_state);
        }
        return win32.S_OK;
    }

    /// 拖离窗口 / 拖放取消。
    fn dragLeave(this: *const anyopaque) callconv(.winapi) win32.HRESULT {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        if (self.has_files) {
            self.has_files = false;
            self.dispatch(.exited, &.{}, .{ .x = 0, .y = 0 }, 0);
        }
        return win32.S_OK;
    }

    /// 放下:取 CF_HDROP → 解析路径 → 带 paths 派发 `.dropped`。
    fn drop(
        this: *const anyopaque,
        data_obj: ?*anyopaque,
        key_state: win32.DWORD,
        pt: win32.POINTL,
        effect: *win32.DWORD,
    ) callconv(.winapi) win32.HRESULT {
        const self: *Self = @ptrCast(@alignCast(@constCast(this)));
        const was_files = self.has_files;
        self.has_files = false;
        effect.* = if (was_files) effectForKeyState(key_state) else win32.DROPEFFECT_NONE;
        if (!was_files) return win32.S_OK;

        if (data_obj) |ptr| {
            const obj: *const win32.IDataObject = @ptrCast(@alignCast(ptr));
            const fmt = fileDropFormat();
            if (obj.getData(&fmt)) |medium_opt| {
                // ReleaseStgMedium 要可变指针(内部可能置 tymed 为 NONE),
                // const 捕获得先落到本地 var。
                var medium = medium_opt;
                defer win32.ReleaseStgMedium(&medium);
                // CF_HDROP 的载体就是 HGLOBAL(HDROP),整块读出来解析。
                if (win32.GlobalLock(medium.u.hGlobal)) |mem| {
                    defer _ = win32.GlobalUnlock(medium.u.hGlobal);
                    const block: [*]const u8 = @ptrCast(mem);
                    self.parsePaths(block[0..win32.GlobalSize(medium.u.hGlobal)]);
                }
            }
        }

        // 切片数组放本帧:dispatch → handleInput → 用户回调同步执行,
        // 回调返回前本帧一直存活(契约:paths 仅回调期间有效)。
        var slices: [max_drop_paths][]const u8 = undefined;
        self.dispatch(.dropped, self.buildPaths(&slices), pt, key_state);
        return win32.S_OK;
    }

    // =========================================================================
    // 测试
    // =========================================================================

    test "QueryInterface accepts IDropTarget/IUnknown, rejects others" {
        var dt: DropTarget = undefined;
        dt.ref_count = 1;

        var out: ?*anyopaque = @ptrFromInt(1);
        try std.testing.expectEqual(
            win32.S_OK,
            queryInterface(&dt, &win32.IID_IDropTarget, &out),
        );
        try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&dt)), out);

        out = @ptrFromInt(1);
        try std.testing.expectEqual(
            win32.S_OK,
            queryInterface(&dt, &win32.IID_IUnknown, &out),
        );
        try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&dt)), out);

        const bogus = win32.GUID{ .Data1 = 0xdeadbeef, .Data2 = 0, .Data3 = 0, .Data4 = .{0}**8 };
        out = @ptrFromInt(1);
        try std.testing.expectEqual(win32.E_NOINTERFACE, queryInterface(&dt, &bogus, &out));
        try std.testing.expectEqual(@as(?*anyopaque, null), out);
    }

    test "AddRef/Release refcounting" {
        var dt: DropTarget = undefined;
        dt.ref_count = 1;

        try std.testing.expectEqual(@as(win32.ULONG, 2), addRef(&dt));
        try std.testing.expectEqual(@as(win32.ULONG, 1), release(&dt));
        try std.testing.expectEqual(@as(u32, 1), dt.ref_count);
    }

    test "parsePaths UTF-16 double-NUL list" {
        var dt: DropTarget = undefined;

        // 合成 CF_HDROP 块:DROPFILES 头(pFiles=20, fWide)+ 两条路径。
        var block: [128]u8 align(8) = undefined;
        @memset(&block, 0);
        const hdr: *win32.DROPFILES = @ptrCast(@alignCast(&block));
        hdr.pFiles = 20;
        hdr.fWide = 1;

        var off: usize = 20;
        for ([_][]const u16{ "C:\\models\\ship.glb", "D:\\tex\\albedo.png" }) |path| {
            const dst: [*]u16 = @ptrCast(@alignCast(block[off..].ptr));
            @memcpy(dst[0..path.len], path);
            off += (path.len + 1) * 2;
        }

        dt.parsePaths(block[0..off]);

        try std.testing.expectEqual(@as(u32, 2), dt.path_count);
        try std.testing.expectEqualStrings("C:\\models\\ship.glb", dt.path_buf[0][0..dt.path_lens[0]]);
        try std.testing.expectEqualStrings("D:\\tex\\albedo.png", dt.path_buf[1][0..dt.path_lens[1]]);

        // buildPaths 必须由调用方提供缓冲(返回栈数组会悬垂)。
        var out: [max_drop_paths][]const u8 = undefined;
        const slice = dt.buildPaths(&out);
        try std.testing.expectEqual(@as(usize, 2), slice.len);
        try std.testing.expectEqualStrings("C:\\models\\ship.glb", slice[0]);
        try std.testing.expectEqualStrings("D:\\tex\\albedo.png", slice[1]);
    }

    test "parsePaths skips oversized and bad blocks" {
        var dt: DropTarget = undefined;

        // 超过 max_drop_path_bytes 的路径整条跳过,后续路径继续。
        var block: [4 * max_drop_path_bytes + 64]u8 align(8) = undefined;
        @memset(&block, 0);
        const hdr: *win32.DROPFILES = @ptrCast(@alignCast(&block));
        hdr.pFiles = 20;
        hdr.fWide = 1;

        var off: usize = 20;
        { // 超长路径:max_drop_path_bytes/2 + 1 个 u16 → 超 UTF-8 上限
            const units: [*]u16 = @ptrCast(@alignCast(block[off..].ptr));
            for (0..(max_drop_path_bytes / 2 + 1)) |i| units[i] = 'a';
            off += (max_drop_path_bytes / 2 + 1 + 1) * 2;
        }
        { // 正常路径
            const path = "ok.txt";
            const units: [*]u16 = @ptrCast(@alignCast(block[off..].ptr));
            @memcpy(units[0..path.len], path);
            off += (path.len + 1) * 2;
        }

        dt.parsePaths(block[0..off]);
        try std.testing.expectEqual(@as(u32, 1), dt.path_count);
        try std.testing.expectEqualStrings("ok.txt", dt.path_buf[0][0..dt.path_lens[0]]);

        // 短块 / pFiles 越界 → 空结果,不崩。
        dt.parsePaths(block[0..4]);
        try std.testing.expectEqual(@as(u32, 0), dt.path_count);
        const bad_hdr: *win32.DROPFILES = @ptrCast(@alignCast(&block));
        bad_hdr.pFiles = 9999;
        dt.parsePaths(block[0..64]);
        try std.testing.expectEqual(@as(u32, 0), dt.path_count);
    }

    test "parsePaths ANSI list" {
        var dt: DropTarget = undefined;

        var block: [64]u8 align(8) = undefined;
        @memset(&block, 0);
        const hdr: *win32.DROPFILES = @ptrCast(@alignCast(&block));
        hdr.pFiles = 20;
        hdr.fWide = 0;

        const list = "C:\\a.txt\x00C:\\b.txt\x00\x00";
        @memcpy(block[20 .. 20 + list.len], list);

        dt.parsePaths(block[0 .. 20 + list.len]);
        try std.testing.expectEqual(@as(u32, 2), dt.path_count);
        try std.testing.expectEqualStrings("C:\\a.txt", dt.path_buf[0][0..dt.path_lens[0]]);
        try std.testing.expectEqualStrings("C:\\b.txt", dt.path_buf[1][0..dt.path_lens[1]]);
    }

    test "key state to drop effect/modifiers" {
        try std.testing.expectEqual(win32.DROPEFFECT_COPY, effectForKeyState(0));
        try std.testing.expectEqual(win32.DROPEFFECT_LINK, effectForKeyState(win32.DD_CONTROL | win32.DD_SHIFT));
        try std.testing.expectEqual(win32.DROPEFFECT_MOVE, effectForKeyState(win32.DD_SHIFT));
        try std.testing.expectEqual(win32.DROPEFFECT_COPY, effectForKeyState(win32.DD_CONTROL));

        const mods = modifiersFromKeyState(win32.DD_SHIFT | win32.DD_ALT);
        try std.testing.expect(mods.shift);
        try std.testing.expect(!mods.ctrl);
        try std.testing.expect(mods.alt);
        try std.testing.expect(!mods.cmd);
    }
};

// =============================================================================
// 模块级助手
// =============================================================================

/// "拖的是不是文件" —— 数据对象提供 CF_HDROP 才算。
fn offersFileDrop(data_obj: ?*anyopaque) bool {
    const ptr = data_obj orelse return false;
    const obj: *const win32.IDataObject = @ptrCast(@alignCast(ptr));
    const fmt = fileDropFormat();
    return win32.SUCCEEDED.check(obj.vtable.QueryGetData(@ptrCast(obj), &fmt));
}

fn fileDropFormat() win32.FORMATETC {
    return .{
        .cfFormat = @intCast(win32.CF_HDROP),
        .ptd = null,
        .dwAspect = win32.DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = win32.TYMED_HGLOBAL,
    };
}

/// 拖放期间的按键状态 → DROPEFFECT(资源管理器惯例:默认复制,Shift
/// 移动,Ctrl+Shift 链接)。引擎只收路径,效果仅影响拖拽光标提示。
fn effectForKeyState(key_state: win32.DWORD) win32.DWORD {
    const shift = key_state & win32.DD_SHIFT != 0;
    const ctrl = key_state & win32.DD_CONTROL != 0;
    if (ctrl and shift) return win32.DROPEFFECT_LINK;
    if (shift) return win32.DROPEFFECT_MOVE;
    return win32.DROPEFFECT_COPY;
}

fn modifiersFromKeyState(key_state: win32.DWORD) input.Modifiers {
    return .{
        .shift = key_state & win32.DD_SHIFT != 0,
        .ctrl = key_state & win32.DD_CONTROL != 0,
        .alt = key_state & win32.DD_ALT != 0,
        .cmd = false,
    };
}

// =============================================================================
// vtable 实例(COM 对象指向它)
// =============================================================================

const vtable: win32.IDropTargetVTable = .{
    .base = .{
        .QueryInterface = DropTarget.queryInterface,
        .AddRef = DropTarget.addRef,
        .Release = DropTarget.release,
    },
    .DragEnter = DropTarget.dragEnter,
    .DragOver = DropTarget.dragOver,
    .DragLeave = DropTarget.dragLeave,
    .Drop = DropTarget.drop,
};
