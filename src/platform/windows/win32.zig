//! Windows 后端 —— 手写 Win32 绑定。
//!
//! 只声明窗口层真正用到的 API:user32(窗口/消息/光标/剪贴板/DPI)、
//! kernel32(模块句柄/全局内存)、gdi32(纯色刷)、dwmapi(模糊/圆角/vsync)、
//! imm32(IME)、ole32 + shell32(COM 文件对话框)。
//!
//! 结构体布局、常量值、COM vtable 顺序均对齐官方 Win32 SDK 头文件
//! (user32/kernel32/gdi32/dwmapi/imm32/ole32/shell32).自包含手写
//! extern —— 不依赖任何 SDK 头文件或生成绑定,未引用的声明零成本
//! (Zig 惰性分析),跨平台后端保持同一风格。

const std = @import("std");

// =============================================================================
// 基础类型
// =============================================================================

pub const BOOL = i32;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const UINT = u32;
pub const ULONG = u32;
pub const LONG = i32;
pub const UINT_PTR = usize;
pub const LONG_PTR = isize;
pub const DWORD_PTR = usize;

pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HRESULT = i32;

/// 不透明句柄。Win32 头文件里 HWND/HINSTANCE/HCURSOR 全是同一形状的
/// 指针,这里统一成 `?*anyopaque`,调用点用 `@ptrCast` 拿回具体类型。
pub const HANDLE = ?*anyopaque;
pub const HWND = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HRGN = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HGLOBAL = ?*anyopaque;
pub const HMONITOR = ?*anyopaque;
pub const HDC = ?*anyopaque;
pub const HMODULE = ?*anyopaque;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const SUCCEEDED = struct {
    pub fn check(hr: HRESULT) bool {
        return hr >= 0;
    }
};

// =============================================================================
// 结构体(布局对齐 Win32 SDK)
// =============================================================================

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,

    pub fn width(self: *const RECT) LONG {
        return self.right - self.left;
    }

    pub fn height(self: *const RECT) LONG {
        return self.bottom - self.top;
    }
};

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: ?WNDPROC,
    cbClsExtra: LONG,
    cbWndExtra: LONG,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
    hIconSm: HICON,
};

/// WM_NCCREATE 的 lParam 指向它;`lpCreateParams` 是 CreateWindowExW 的
/// 最后一个参数 —— 窗口把 `*Window` 从这里取出来挂到 GWLP_USERDATA。
pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: HMENU,
    hwndParent: HWND,
    cy: LONG,
    cx: LONG,
    y: LONG,
    x: LONG,
    style: LONG,
    lpszName: ?[*:0]const u16,
    lpszClass: ?[*:0]const u16,
    dwExStyle: DWORD,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]BYTE,
};

/// WM_DPICHANGED 的 lParam 指向它:系统建议的新窗口矩形。
pub const WINDOWPOS = extern struct {
    hwnd: HWND,
    hwndInsertAfter: HWND,
    x: LONG,
    y: LONG,
    cx: LONG,
    cy: LONG,
    flags: UINT,
};

pub const DWM_BLURBEHIND = extern struct {
    dwFlags: DWORD,
    fEnable: BOOL,
    hRgnBlur: HRGN,
    fTransitionOnMaximized: BOOL,
};

// =============================================================================
// 窗口样式 / 扩展样式
// =============================================================================

pub const WS_OVERLAPPED: UINT = 0x00000000;
pub const WS_CAPTION: UINT = 0x00C00000;
pub const WS_SYSMENU: UINT = 0x00080000;
pub const WS_THICKFRAME: UINT = 0x00040000;
pub const WS_MINIMIZEBOX: UINT = 0x00020000;
pub const WS_MAXIMIZEBOX: UINT = 0x00010000;

/// Overlapped | Caption | SysMenu | ThickFrame | MinimizeBox | MaximizeBox。
pub const WS_OVERLAPPEDWINDOW: UINT =
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
/// 分层窗口:`SetLayeredWindowAttributes` 的前提,玻璃透明度用它。
pub const WS_EX_LAYERED: DWORD = 0x00080000;
/// 始终置顶(工具窗口/候选框用,本期未用)。
pub const WS_EX_TOPMOST: DWORD = 0x00000008;

pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;

// =============================================================================
// 消息
// =============================================================================

pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_DPICHANGED: UINT = 0x02E0;

// IME 消息(imm32 / IME 接口)
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;
pub const WM_IME_SETCONTEXT: UINT = 0x0281;
pub const WM_INPUTLANGCHANGE: UINT = 0x0051;

/// `WM_IME_COMPOSITION` 的 lParam 标志。
pub const GCS_COMPSTR: DWORD = 0x0008;
pub const GCS_RESULTSTR: DWORD = 0x0800;

/// WM_IME_SETCONTEXT 的 lParam:清掉这个位,IME 候选窗不再跟着
/// 系统默认位置走,改由 `ImmSetCandidateWindow` 按光标矩形摆放。
pub const ISC_SHOWUICOMPOSITIONWINDOW: LPARAM = 0x80000000;

/// WM_SETCURSOR 的 lParam 低位:客户区。
pub const HTCLIENT: LPARAM = 1;

// 滚轮/按键的 wParam 标志
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_SHIFT: WPARAM = 0x0004;
pub const MK_CONTROL: WPARAM = 0x0008;
pub const MK_MBUTTON: WPARAM = 0x0010;

// ShowWindow
pub const SW_SHOW: i32 = 5;
pub const SW_HIDE: i32 = 0;

// CreateWindowExW 的 X/Y/nWidth/nHeight 特殊值:位置/尺寸由系统选。
pub const CW_USEDEFAULT: LONG = @bitCast(@as(u32, 0x80000000));

// SetWindowPos 的 flags
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;

// PeekMessage
pub const PM_REMOVE: UINT = 0x0001;

// GetWindowLongPtrW 的索引
pub const GWLP_USERDATA: LONG = -2;

// TrackMouseEvent
pub const TME_LEAVE: DWORD = 0x00000002;

// 系统计时器 ID(窗口闪烁用)
pub const TIMER_BLINK_ID: UINT_PTR = 1;

// =============================================================================
// 光标 / 鼠标
// =============================================================================

/// 整数资源 `MAKEINTRESOURCEW(IDC_ARROW)` = 32512。LoadCursorW 的这个参数
/// 名义上是 `LPCWSTR`,实际只认低位整数 ID —— 32513 这类奇数地址根本不是
/// 合法的 `u16` 指针,所以参数按 `?*anyopaque` 收,不做指针对齐检查。
pub const IDC_ARROW: ?*anyopaque = @ptrFromInt(32512);
pub const IDC_IBEAM: ?*anyopaque = @ptrFromInt(32513);
pub const IDC_HAND: ?*anyopaque = @ptrFromInt(32649);
pub const IDC_SIZEALL: ?*anyopaque = @ptrFromInt(32646);

// =============================================================================
// 虚拟键码(Windows VK_*)
// =============================================================================

pub const VK_BACK: WPARAM = 0x08;
pub const VK_TAB: WPARAM = 0x09;
pub const VK_CLEAR: WPARAM = 0x0C;
pub const VK_RETURN: WPARAM = 0x0D;
pub const VK_SHIFT: WPARAM = 0x10;
pub const VK_CONTROL: WPARAM = 0x11;
pub const VK_MENU: WPARAM = 0x12; // Alt
pub const VK_CAPITAL: WPARAM = 0x14;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_SPACE: WPARAM = 0x20;
pub const VK_PRIOR: WPARAM = 0x21; // Page Up
pub const VK_NEXT: WPARAM = 0x22; // Page Down
pub const VK_END: WPARAM = 0x23;
pub const VK_HOME: WPARAM = 0x24;
pub const VK_LEFT: WPARAM = 0x25;
pub const VK_UP: WPARAM = 0x26;
pub const VK_RIGHT: WPARAM = 0x27;
pub const VK_DOWN: WPARAM = 0x28;
pub const VK_SNAPSHOT: WPARAM = 0x2C;
pub const VK_INSERT: WPARAM = 0x2D;
pub const VK_DELETE: WPARAM = 0x2E;
pub const VK_LWIN: WPARAM = 0x5B;
pub const VK_RWIN: WPARAM = 0x5C;
pub const VK_NUMPAD0: WPARAM = 0x60;
pub const VK_MULTIPLY: WPARAM = 0x6A;
pub const VK_ADD: WPARAM = 0x6B;
pub const VK_SUBTRACT: WPARAM = 0x6D;
pub const VK_DECIMAL: WPARAM = 0x6E;
pub const VK_DIVIDE: WPARAM = 0x6F;
pub const VK_F1: WPARAM = 0x70;
pub const VK_F24: WPARAM = 0x87;
pub const VK_NUMLOCK: WPARAM = 0x90;
pub const VK_SCROLL: WPARAM = 0x91;
pub const VK_LSHIFT: WPARAM = 0xA0;
pub const VK_RSHIFT: WPARAM = 0xA1;
pub const VK_LCONTROL: WPARAM = 0xA2;
pub const VK_RCONTROL: WPARAM = 0xA3;
pub const VK_LMENU: WPARAM = 0xA4;
pub const VK_RMENU: WPARAM = 0xA5;

// OEM 布局键(US ANSI 位置)
pub const VK_OEM_1: WPARAM = 0xBA; // ;:
pub const VK_OEM_PLUS: WPARAM = 0xBB; // =+
pub const VK_OEM_COMMA: WPARAM = 0xBC; // ,<
pub const VK_OEM_MINUS: WPARAM = 0xBD; // -_
pub const VK_OEM_PERIOD: WPARAM = 0xBE; // .>
pub const VK_OEM_2: WPARAM = 0xBF; // /?
pub const VK_OEM_3: WPARAM = 0xC0; // `~
pub const VK_OEM_4: WPARAM = 0xDB; // [{
pub const VK_OEM_5: WPARAM = 0xDC; // \|
pub const VK_OEM_6: WPARAM = 0xDD; // ]}
pub const VK_OEM_7: WPARAM = 0xDE; // '"

// =============================================================================
// 剪贴板
// =============================================================================

pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const GHND: UINT = GMEM_MOVEABLE | 0x0042; // MOVEABLE | ZEROINIT

// =============================================================================
// DWM(dwmaapi)
// =============================================================================

pub const DWM_BB_ENABLE: DWORD = 0x00000001;
pub const DWM_BB_BLURREGION: DWORD = 0x00000002;

/// DWMWINDOWATTRIBUTE —— 属性 ID 对齐 SDK `dwmapi.h`。
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE: DWORD = 33;
/// Win11 22H2+ 的系统背景类型(Mica / Acrylic)。
pub const DWMWA_SYSTEMBACKDROP_TYPE: DWORD = 38;

pub const DWMWCP_DEFAULT: DWORD = 0;
pub const DWMWCP_DONOTROUND: DWORD = 1;
pub const DWMWCP_ROUND: DWORD = 2;
pub const DWMWCP_ROUNDSMALL: DWORD = 3;

/// `DWM_SYSTEMBACKDROP_TYPE` —— Win11 22H2 SDK 定义(较老的头文件
/// 尚未收录),值直接取自 Windows SDK `dwmapi.h`。
pub const DWMSBT_AUTO: DWORD = 0;
pub const DWMSBT_NONE: DWORD = 1;
/// Mica(不透明石板纹理)。
pub const DWMSBT_MAINWINDOW: DWORD = 2;
/// Acrylic(背景模糊,半透明)。
pub const DWMSBT_TRANSIENTWINDOW: DWORD = 3;
pub const DWMSBT_TABBEDWINDOW: DWORD = 4;

// =============================================================================
// DPI
// =============================================================================

/// `DPI_AWARENESS_CONTEXT` 句柄值(非指针,是伪句柄整数)。
/// PER_MONITOR_AWARE_V2:每显示器缩放 + Win10 1703+ 自动非客户区。
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE = @ptrFromInt(@as(usize, 0xFFFFFFFFFFFFFFFC));

// =============================================================================
// OLE 拖放(COM)
// =============================================================================

/// `FORMATETC.tymed`:只认 HGLOBAL(CF_HDROP 装在全局内存里)。
pub const TYMED_HGLOBAL: DWORD = 0x00000001;
/// `FORMATETC.dwAspect`:内容本身。
pub const DVASPECT_CONTENT: DWORD = 1;

/// 剪贴板格式:文件列表(HDROP)。拖放数据对象上问"有没有这个格式"
/// 就是问"你带的是不是文件"。
pub const CF_HDROP: UINT = 15;

/// DROPEFFECT —— DragEnter/DragOver/Drop 返回的放下的效果。
pub const DROPEFFECT_NONE: DWORD = 0;
pub const DROPEFFECT_COPY: DWORD = 1;
pub const DROPEFFECT_MOVE: DWORD = 2;
pub const DROPEFFECT_LINK: DWORD = 4;

// DragEnter/DragOver 的 grfKeyState 标志(注意和 MK_LBUTTON 那套不同:
// 拖放期间按键状态是独立编码的)。
pub const DD_SHIFT: DWORD = 0x0001;
pub const DD_CONTROL: DWORD = 0x0002;
pub const DD_ALT: DWORD = 0x0020;

/// `FORMATETC`:向数据对象描述"我要哪种呈现"。
pub const FORMATETC = extern struct {
    cfFormat: WORD, // CF_HDROP
    ptd: ?*anyopaque,
    dwAspect: DWORD,
    lindex: LONG,
    tymed: DWORD,
};

/// `STGMEDIUM`:数据对象交出的存储载体。windowkit 只用 `hGlobal`
/// (TYMED_HGLOBAL),取完必须 `ReleaseStgMedium`,不能直接 GlobalFree。
///
/// 布局对照 ole2.h `tagSTGMEDIUM`:DWORD tymed + union(指针宽)+
/// pUnkForRelease(union 外面的独立字段!)。x64 下 24 字节。
pub const STGMEDIUM = extern struct {
    tymed: DWORD,
    u: extern union {
        hGlobal: HGLOBAL,
    },
    pUnkForRelease: ?*anyopaque,
};

/// `IDataObject` vtable —— 拖放期间"被拖的东西"。slot 顺序对照 ole2.h:
/// IUnknown 3 个 + GetData/GetDataHere/QueryGetData/GetCanonicalFormatEtc/
/// SetData/EnumFormatEtc/DAdvise/DUnadvise/EnumDAdvise。只用 GetData 与
/// QueryGetData,其余占位保证偏移正确。
pub const IDataObjectVTable = extern struct {
    base: IUnknownVTable,
    GetData: *const fn (*const anyopaque, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    GetDataHere: *const fn (*const anyopaque, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    QueryGetData: *const fn (*const anyopaque, *const FORMATETC) callconv(.winapi) HRESULT,
    GetCanonicalFormatEtc: *const fn (*const anyopaque, *?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    SetData: *const fn (*const anyopaque, ?*anyopaque, ?*anyopaque, BOOL) callconv(.winapi) HRESULT,
    EnumFormatEtc: *const fn (*const anyopaque, DWORD, *?*anyopaque) callconv(.winapi) HRESULT,
    DAdvise: *const fn (*const anyopaque, ?*anyopaque, DWORD, *?*anyopaque, *DWORD) callconv(.winapi) HRESULT,
    DUnadvise: *const fn (*const anyopaque, DWORD) callconv(.winapi) HRESULT,
    EnumDAdvise: *const fn (*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IDataObject = extern struct {
    vtable: *const IDataObjectVTable,

    /// 数据对象是否提供指定格式(拖入时判断"是不是文件")。
    pub fn queryGetData(self: *const IDataObject, fmt: *const FORMATETC) bool {
        return SUCCEEDED.check(self.vtable.QueryGetData(@ptrCast(self), fmt));
    }

    /// 取数据;失败返回 null(调用方无需 Release)。
    pub fn getData(self: *const IDataObject, fmt: *const FORMATETC) ?STGMEDIUM {
        var medium: STGMEDIUM = undefined;
        if (!SUCCEEDED.check(self.vtable.GetData(@ptrCast(self), fmt, &medium))) return null;
        return medium;
    }

    pub fn release(self: *const IDataObject) ULONG {
        const unk: *const IUnknown = @ptrCast(self);
        return unk.release();
    }
};

/// `IDropTarget` vtable —— 挂在窗口上的拖放目标。slot 顺序:IUnknown 3 个
/// + DragEnter/DragOver/DragLeave/Drop(ole2.h `IDropTarget`)。
pub const IDropTargetVTable = extern struct {
    base: IUnknownVTable,
    DragEnter: *const fn (*const anyopaque, ?*anyopaque, DWORD, POINTL, *DWORD) callconv(.winapi) HRESULT,
    DragOver: *const fn (*const anyopaque, DWORD, POINTL, *DWORD) callconv(.winapi) HRESULT,
    DragLeave: *const fn (*const anyopaque) callconv(.winapi) HRESULT,
    Drop: *const fn (*const anyopaque, ?*anyopaque, DWORD, POINTL, *DWORD) callconv(.winapi) HRESULT,
};

/// 点(屏幕坐标,拖放回调用)。
pub const POINTL = extern struct {
    x: LONG,
    y: LONG,
};

// =============================================================================
// COM 基础
// =============================================================================

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    /// 编译期从 `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` 构造 GUID。
    /// 按小端序把十六进制对写进 16 字节(Data1/Data2/Data3 字节翻转,
    /// Data4 原样)。
    pub fn initString(comptime s: *const [36]u8) GUID {
        comptime {
            std.debug.assert(s[8] == '-' and s[13] == '-' and s[18] == '-' and s[23] == '-');
        }
        return comptime parseNoBraces(s) catch @panic("invalid GUID");
    }

    /// `s` 必须是完整的 36 字符 GUID 文本(无花括号)。
    fn parseNoBraces(s: []const u8) !GUID {
        std.debug.assert(s.len == 36);
        var bytes: [16]u8 = undefined;
        // GUID 文本→字节的偏移表(小端布局):每个偏移指向
        // 一对十六进制字符,结果按小端布局直接 bitCast 成 GUID。
        const offsets = [16]u6{ 6, 4, 2, 0, 11, 9, 16, 14, 19, 21, 24, 26, 28, 30, 32, 34 };
        for (offsets, 0..) |off, i| {
            bytes[i] = (try std.fmt.charToDigit(s[off], 16)) << 4 |
                try std.fmt.charToDigit(s[off + 1], 16);
        }
        // offsets 按小端排字节:前 8 字节依次是 Data1/Data2/Data3 的小端
        // 表示,尾 8 字节是 Data4 原序。
        return .{
            .Data1 = std.mem.readInt(u32, bytes[0..4], .little),
            .Data2 = std.mem.readInt(u16, bytes[4..6], .little),
            .Data3 = std.mem.readInt(u16, bytes[6..8], .little),
            .Data4 = bytes[8..16].*,
        };
    }
};

/// IUnknown vtable —— COM 对象的第一张表。
pub const IUnknownVTable = extern struct {
    QueryInterface: *const fn (*const anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*const anyopaque) callconv(.winapi) ULONG,
    Release: *const fn (*const anyopaque) callconv(.winapi) ULONG,
};

pub const IUnknown = extern struct {
    vtable: *const IUnknownVTable,

    pub fn addRef(self: *const IUnknown) ULONG {
        return self.vtable.AddRef(@ptrCast(self));
    }

    pub fn release(self: *const IUnknown) ULONG {
        return self.vtable.Release(@ptrCast(self));
    }
};

/// `IID_IDropTarget` = `{00000122-0000-0000-C000-000000000046}`。拖放目标
/// 挂上窗口后,OLE 用它做 QueryInterface 身份判断。
pub const IID_IDropTarget = GUID.initString("00000122-0000-0000-c000-000000000046");
/// `IID_IUnknown` = `{00000000-0000-0000-C000-000000000046}` —— QueryInterface
/// 的兜底身份(任何 COM 对象都要认它)。
pub const IID_IUnknown = GUID.initString("00000000-0000-0000-c000-000000000046");
/// `E_NOINTERFACE` —— QueryInterface 认不出该 IID 时返回。
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

// =============================================================================
// user32
// =============================================================================

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) WORD;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?[*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: LONG,
    Y: LONG,
    nWidth: LONG,
    nHeight: LONG,
    hWndParent: HWND,
    hMenu: HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) HWND;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, HWND, LONG, LONG, LONG, LONG, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectEx(*RECT, DWORD, BOOL, DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(HWND, LONG) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetWindowLongPtrW(HWND, LONG, LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn BringWindowToTop(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(HWND) callconv(.winapi) HWND;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) HWND;
pub extern "user32" fn IsWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
/// 分层窗口整体透明度:`WS_EX_LAYERED` + `LWA_ALPHA`。
pub extern "user32" fn SetLayeredWindowAttributes(HWND, DWORD, BYTE, DWORD) callconv(.winapi) BOOL;

pub const LWA_ALPHA: DWORD = 0x00000002;
pub const LWA_COLORKEY: DWORD = 0x00000001;

pub extern "user32" fn GetMessageW(*MSG, HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn WaitMessage() callconv(.winapi) BOOL;

/// 阻塞至多 `dwMilliseconds` 毫秒等句柄数组或消息队列（QS 唤醒掩码）有输入。
/// 用于 `waitEvent`：句柄数组传空、只等消息队列。
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    n_count: DWORD,
    handles: ?[*]const HANDLE,
    dw_milliseconds: DWORD,
    wake_mask: DWORD,
    flags: DWORD,
) callconv(.winapi) DWORD;

/// `MsgWaitForMultipleObjectsEx` 的唤醒掩码：任意一条消息队列输入。
pub const QS_ALLINPUT: DWORD = 0x04FF;
/// `MsgWaitForMultipleObjectsEx` 的旗标：队列里**已有**输入时立即返回
/// （不带此旗标会只在"新到一条"的边沿返回，漏掉 pump 前残留的消息）。
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
/// `MsgWaitForMultipleObjectsEx` 返回值：超出时限。
pub const WAIT_TIMEOUT: DWORD = 0x00000102;

pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn LoadCursorW(HINSTANCE, ?*anyopaque) callconv(.winapi) HCURSOR;
pub extern "user32" fn SetCursor(HCURSOR) callconv(.winapi) HCURSOR;
pub extern "user32" fn GetCursor() callconv(.winapi) HCURSOR;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) HWND;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;

/// 键盘状态表:`GetKeyState(VK_SHIFT) < 0` 表示按下。
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) SHORT_as_WORD;
/// 物理键扫描码:扩展键区分数码行 1 与小键盘 1。
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
/// VK + 扫描码 + 键盘状态 → UTF-16 字符(dead key 用第二次调用冲掉)。
pub extern "user32" fn ToUnicode(
    UINT,
    UINT,
    *const BYTE,
    [*:0]u16,
    c_int,
    UINT,
) callconv(.winapi) c_int;

/// GetKeyState 返回 SHORT(与 u16 同宽,符号位是"按下")。
pub const SHORT_as_WORD = i16;

// DPI
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn GetDpiForSystem() callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;

// 剪贴板
pub extern "user32" fn OpenClipboard(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) HANDLE;
pub extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(.winapi) HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterClipboardFormatW([*:0]const u16) callconv(.winapi) UINT;

// 文件对话框 owner + 系统模态
pub extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;

// =============================================================================
// kernel32
// =============================================================================

pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HMODULE;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) HGLOBAL;
pub extern "kernel32" fn GlobalFree(HGLOBAL) callconv(.winapi) HGLOBAL;
pub extern "kernel32" fn GlobalLock(HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalSize(HGLOBAL) callconv(.winapi) usize;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;

// =============================================================================
// gdi32(纯色刷,WM_ERASEBKGND 用)
// =============================================================================

pub extern "gdi32" fn CreateSolidBrush(DWORD) callconv(.winapi) HBRUSH;
pub extern "gdi32" fn DeleteObject(HANDLE) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetStockObject(i32) callconv(.winapi) HANDLE;

/// GetStockObject 的刷子 ID
pub const BLACK_BRUSH: i32 = 4;
pub const WHITE_BRUSH: i32 = 0;
pub const DKGRAY_BRUSH: i32 = 17;

/// RGB 宏:0x00BBGGRR。
pub fn RGB(r: u8, g: u8, b: u8) DWORD {
    return @as(DWORD, r) | @as(DWORD, g) << 8 | @as(DWORD, b) << 16;
}

// =============================================================================
// dwmapi
// =============================================================================

pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.winapi) HRESULT;
pub extern "dwmapi" fn DwmEnableBlurBehindWindow(HWND, *const DWM_BLURBEHIND) callconv(.winapi) HRESULT;
/// 阻塞到下一个合成帧 —— Windows 后端的 vsync 节拍(替代 CVDisplayLink)。
pub extern "dwmapi" fn DwmFlush() callconv(.winapi) HRESULT;
pub extern "dwmapi" fn DwmIsCompositionEnabled(*BOOL) callconv(.winapi) HRESULT;

// =============================================================================
// imm32(IME)
// =============================================================================

pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?*anyopaque;
pub extern "imm32" fn ImmReleaseContext(HWND, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(?*anyopaque, DWORD, ?*anyopaque, DWORD) callconv(.winapi) LONG;
pub extern "imm32" fn ImmSetCandidateWindow(?*anyopaque, *const CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetDefaultIMEWnd(HWND) callconv(.winapi) HWND;

pub const CFS_POINT: DWORD = 0x0002;
pub const CFS_RECT: DWORD = 0x0001;
pub const CFS_CANDIDATEPOS: DWORD = 0x0040;

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

// =============================================================================
// ole32(拖放目标的 COM 注册)
// =============================================================================

/// 拖放目标要挂成 COM 对象,UI 线程必须先初始化 OLE。
/// 必须用 `OleInitialize` 而非 `CoInitializeEx`:MSDN 明确说后者注册
/// 拖放时 `RegisterDragDrop` **恒返回 E_OUTOFMEMORY**(OLE 拖放子系统
/// 需要 OleInitialize 的额外初始化,0x8007000e 实测踩过)。
/// `platform.initInPlace` 调一次,`deinit` 里配对 `OleUninitialize`。
/// 参数是保留的 pvReserved,必须传 null。
pub extern "ole32" fn OleInitialize(?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;
/// 把 IDropTarget 挂到窗口(拖放开始时 OLE 会 QueryInterface 并回调)。
pub extern "ole32" fn RegisterDragDrop(HWND, ?*anyopaque) callconv(.winapi) HRESULT;
/// 摘掉拖放目标;窗口销毁前必须调,否则 OLE 还持有悬空指针。
pub extern "ole32" fn RevokeDragDrop(HWND) callconv(.winapi) HRESULT;
/// 释放 `IDataObject::GetData` 交出的 STGMEDIUM(不能手搓 GlobalFree,
/// pUnkForRelease 可能不是 null)。
pub extern "ole32" fn ReleaseStgMedium(*STGMEDIUM) callconv(.winapi) void;

/// CF_HDROP 的载体:一个装着 `DROPFILES` 头 + 双 NUL 结尾路径列表的
/// HGLOBAL。`STGMEDIUM.u.hGlobal` 取出后直接当 HDROP 用。
pub const HDROP = ?*anyopaque;

/// `DROPFILES`:CF_HDROP 内存块的头(shellapi.h),x64 下 20 字节。
/// `pFiles` 是文件列表相对块首的字节偏移;`fWide` = 列表是 UTF-16。
pub const DROPFILES = extern struct {
    pFiles: DWORD,
    pt: POINT,
    fNC: BOOL,
    fWide: BOOL,
};

// shell32(枚举拖放携带的文件列表)

/// `iFile == 0xFFFFFFFF` 时返回文件总数;否则枚举第 `iFile` 个路径写入
/// `lpszFile`(返回值 = 字符数,不含结尾 NUL;缓冲太小则返回所需大小)。
/// `lpszFile` 传 null 只询问长度。UTF-16 进出。
pub extern "shell32" fn DragQueryFileW(
    hDrop: HDROP,
    iFile: UINT,
    lpszFile: ?[*]u16,
    cch: UINT,
) callconv(.winapi) UINT;

// =============================================================================
// 测试
// =============================================================================

test "GUID.initString parses COM IID" {
    // IID_IDropTarget:Data1 是字符串第一段的小端 u32。
    const g = GUID.initString("00000122-0000-0000-c000-000000000046");
    try std.testing.expectEqual(@as(u32, 0x00000122), g.Data1);
    try std.testing.expectEqual(@as(u16, 0x0000), g.Data2);
    try std.testing.expectEqual(@as(u16, 0x0000), g.Data3);
    try std.testing.expectEqual([8]u8{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 }, g.Data4);
    // 常量与手写解析一致。
    try std.testing.expect(std.meta.eql(IID_IDropTarget, g));
}

test "GUID byte layout matches COM ABI" {
    // little-endian:Data1 在前 4 字节,Data2/Data3 各 2 字节,Data4 原样。
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    const g = GUID.initString("00000000-0000-0000-0000-000000000001");
    try std.testing.expectEqual(@as(u8, 1), g.Data4[7]);
}

test "RGB macro layout" {
    try std.testing.expectEqual(@as(DWORD, 0x00FF0000), RGB(0, 0, 255)); // 红在低位字节之后
    try std.testing.expectEqual(@as(DWORD, 0x0000FF00), RGB(0, 255, 0));
    try std.testing.expectEqual(@as(DWORD, 0x000000FF), RGB(255, 0, 0));
}

test "key struct sizes (x64 ABI)" {
    // MSG 在 x64 是 48 字节(hwnd 8 + message 4 + pad 4 + wParam 8 +
    // lParam 8 + time 4 + pt 8)。extern struct 自动按平台规则对齐。
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 48), @sizeOf(MSG));
        // WNDCLASSEXW 固定 80 字节(x64)。
        try std.testing.expectEqual(@as(usize, 80), @sizeOf(WNDCLASSEXW));
        // CREATESTRUCTW 72 字节(x64)。
        try std.testing.expectEqual(@as(usize, 72), @sizeOf(CREATESTRUCTW));
        // FORMATETC 是 2 + pad 6 + 8 + 4 + 4 + 4 → 32 字节(x64 对齐)。
        try std.testing.expectEqual(@as(usize, 32), @sizeOf(FORMATETC));
        // STGMEDIUM = DWORD + pad 4 + union 8 + pUnkForRelease 8 → 24 字节(x64)。
        try std.testing.expectEqual(@as(usize, 24), @sizeOf(STGMEDIUM));
        // POINTL 两个 LONG → 8 字节(任何架构)。
        try std.testing.expectEqual(@as(usize, 8), @sizeOf(POINTL));
    }
}
