//! Windows 输入翻译 —— VK 码 / 鼠标 / 修饰键 → `input.InputEvent`。
//!
//! 这里把 Win32 的虚拟键码（VK_*）翻译成与平台无关的 `input.KeyTag`：
//! US ANSI 物理位置一一对应（字母、数字行、标点），小键盘 / 功能键 /
//! 修饰键查表，未收录的 VK 折叠成 `.unknown`。

const std = @import("std");
const win32 = @import("win32.zig");
const input = @import("../../input/events.zig");

pub const KeyTag = input.KeyTag;
pub const Modifiers = input.Modifiers;
pub const MouseButton = input.MouseButton;

// =============================================================================
// 修饰键
// =============================================================================

/// 从 GetKeyState 表读当前修饰键状态(比从单个消息的 wParam 推断更准:
/// Alt+Tab、修饰键单独按下等边角都被覆盖)。
///
/// `cmd` 在 Windows 上映射为 Win 键 —— 跨平台消费者把它当"主修饰键"
/// (macOS Cmd / Linux Super)用,语义一致。
pub fn currentModifiers() Modifiers {
    const down = struct {
        fn f(vk: win32.WPARAM) bool {
            return win32.GetKeyState(@intCast(vk)) < 0;
        }
    }.f;

    return .{
        .shift = down(win32.VK_SHIFT),
        .ctrl = down(win32.VK_CONTROL),
        .alt = down(win32.VK_MENU),
        .cmd = down(win32.VK_LWIN) or down(win32.VK_RWIN),
    };
}

/// 鼠标消息 wParam 的 MK_* 位 → 修饰键(消息自带的按下快照,比查表早
/// 一个事件;鼠标事件用这个,键盘事件用 `currentModifiers`)。
pub fn modifiersFromMouseWParam(wparam: win32.WPARAM) Modifiers {
    const mods = currentModifiers();
    return .{
        .shift = mods.shift or (wparam & win32.MK_SHIFT) != 0,
        .ctrl = mods.ctrl or (wparam & win32.MK_CONTROL) != 0,
        .alt = mods.alt,
        .cmd = mods.cmd,
    };
}

// =============================================================================
// VK → KeyTag
// =============================================================================

/// Windows VK 码 → 跨平台 KeyTag。
///
/// `extended` 是 lparam 第 25 位(KF_EXTENDED):区分小键盘 Enter 与主键盘
/// Enter、小键盘斜杠与主键盘斜杠 —— 两者的 VK 码相同。
pub fn keyTagFromVirtualKey(vk: win32.WPARAM, extended: bool) KeyTag {
    // 字母:VK 是 ASCII 大写,查表映射到按物理位置命名的 KeyTag。
    if (vk >= 'A' and vk <= 'Z') {
        const letter_map = [26]KeyTag{
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
        };
        return letter_map[vk - 'A'];
    }

    // 数字行(不含小键盘)。
    if (vk >= '0' and vk <= '9') {
        const digit_map = [10]KeyTag{
            .@"0", .@"1", .@"2", .@"3", .@"4",
            .@"5", .@"6", .@"7", .@"8", .@"9",
        };
        return digit_map[vk - '0'];
    }

    // F1–F24:KeyTag 只定义到 F20,超出部分折叠成 unknown。
    if (vk >= win32.VK_F1 and vk <= win32.VK_F24) {
        const f_map = [24]KeyTag{
            .f1,  .f2,  .f3,  .f4,  .f5,  .f6,  .f7,  .f8,  .f9, .f10, .f11, .f12,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            .unknown, .unknown, .unknown, .unknown, // F21–F24:KeyTag 无对应
        };
        return f_map[vk - win32.VK_F1];
    }

    // 小键盘数字。
    if (vk >= win32.VK_NUMPAD0 and vk <= win32.VK_NUMPAD0 + 9) {
        const kp_map = [10]KeyTag{
            .keypad_0, .keypad_1, .keypad_2, .keypad_3, .keypad_4,
            .keypad_5, .keypad_6, .keypad_7, .keypad_8, .keypad_9,
        };
        return kp_map[vk - win32.VK_NUMPAD0];
    }

    return switch (vk) {
        // 特殊键
        win32.VK_RETURN => if (extended) .keypad_enter else .@"return",
        win32.VK_TAB => .tab,
        win32.VK_SPACE => .space,
        // Windows 的 Backspace 对应 KeyTag.delete。
        win32.VK_BACK => .delete,
        win32.VK_ESCAPE => .escape,
        // Windows 的 Delete 键对应 KeyTag.forward_delete。
        win32.VK_DELETE => .forward_delete,
        win32.VK_INSERT => .unknown,

        // 标点(US ANSI 位置)
        win32.VK_OEM_MINUS => .minus,
        win32.VK_OEM_PLUS => .equal,
        win32.VK_OEM_4 => .left_bracket,
        win32.VK_OEM_6 => .right_bracket,
        win32.VK_OEM_5 => .backslash,
        win32.VK_OEM_1 => .semicolon,
        win32.VK_OEM_7 => .quote,
        win32.VK_OEM_COMMA => .comma,
        win32.VK_OEM_PERIOD => .period,
        win32.VK_OEM_2 => .slash,
        win32.VK_OEM_3 => .grave,

        // 小键盘运算符
        win32.VK_DECIMAL => .keypad_decimal,
        win32.VK_MULTIPLY => .keypad_multiply,
        win32.VK_ADD => .keypad_plus,
        win32.VK_SUBTRACT => .keypad_minus,
        win32.VK_DIVIDE => if (extended) .keypad_divide else .slash,
        win32.VK_CLEAR => .keypad_clear, // NumLock 位置(PC 键盘无 Clear 键)

        // 修饰键。键盘消息的 wParam 送的是合并码 VK_SHIFT / VK_CONTROL /
        // VK_MENU;L*/R* 变体只出现在 GetKeyState 之类的状态查询里。左右
        // 由 extended 位区分:右 Ctrl、右 Alt 的 extended 为真。Shift 例外,
        // 左右 Shift 的 extended 位相同,这里统一映射为左 Shift。
        win32.VK_SHIFT => .shift,
        win32.VK_CONTROL => if (extended) .right_control else .control,
        win32.VK_MENU => if (extended) .right_option else .option,
        // 防御:L*/R* 变体若从别的消息路径进来也能解析。
        win32.VK_LSHIFT => .shift,
        win32.VK_RSHIFT => .right_shift,
        win32.VK_LCONTROL => .control,
        win32.VK_RCONTROL => .right_control,
        win32.VK_LMENU => .option,
        win32.VK_RMENU => .right_option,
        win32.VK_LWIN => .command,
        win32.VK_RWIN => .right_command,
        win32.VK_CAPITAL => .caps_lock,

        // 方向键
        win32.VK_LEFT => .left,
        win32.VK_RIGHT => .right,
        win32.VK_DOWN => .down,
        win32.VK_UP => .up,

        // 翻页/导航
        win32.VK_PRIOR => .page_up,
        win32.VK_NEXT => .page_down,
        win32.VK_HOME => .home,
        win32.VK_END => .end,

        else => .unknown,
    };
}
// =============================================================================
// WM_CHAR → UTF-8
// =============================================================================

/// WM_CHAR 的 wParam 是一个 UTF-16 码元。多数字符是 BMP 单元;emoji /
/// 扩展区字符拆成代理对,两个 WM_CHAR 连续到达 —— 窗口层用
/// `CharBuffer` 跨消息拼装代理对,拼完整再发 `text_input`。
pub const CharBuffer = struct {
    buf: [4]u8 = undefined,
    /// 已编码的 UTF-8 字节数(0 = 空)。
    len: usize = 0,
    /// 等待低半区的代理对高半区。
    pending_high: ?u16 = null,

    /// 收一个 UTF-16 码元;返回 true 表示一个完整字符已就绪。
    /// 代理对的高半区先攒着,低半区到达时合并。
    pub fn pushUtf16(self: *CharBuffer, unit: u16) bool {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.pending_high = unit;
            self.len = 0;
            return false;
        }
        if (std.unicode.utf16IsLowSurrogate(unit)) {
            if (self.pending_high) |high| {
                const pair = [_]u16{ high, unit };
                const cp = std.unicode.utf16DecodeSurrogatePair(&pair) catch {
                    self.pending_high = null;
                    self.len = 0;
                    return false;
                };
                self.len = std.unicode.utf8Encode(cp, &self.buf) catch 0;
                self.pending_high = null;
                return self.len > 0;
            }
            self.len = 0;
            return false;
        }
        self.pending_high = null;
        self.len = std.unicode.utf8Encode(@intCast(unit), &self.buf) catch 0;
        return self.len > 0;
    }

    /// 当前完整字符的 UTF-8 切片(借用,下一次 push 前有效)。
    pub fn slice(self: *const CharBuffer) []const u8 {
        return self.buf[0..self.len];
    }
};

// =============================================================================
// 鼠标
// =============================================================================

/// lparam 低位/高位 → 有符号客户区坐标(GET_X_LPARAM / GET_Y_LPARAM)。
pub fn mouseXFromLParam(lparam: win32.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
}

pub fn mouseYFromLParam(lparam: win32.LPARAM) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
}

/// WM_MOUSEWHEEL 的 wParam 高位 → 滚动增量(±120/格,向下为负)。
pub fn wheelDeltaFromWParam(wparam: win32.WPARAM) i16 {
    return @bitCast(@as(u16, @truncate(wparam >> 16)));
}

// =============================================================================
// 测试
// =============================================================================

test "letter VK follows physical layout" {
    try std.testing.expectEqual(KeyTag.a, keyTagFromVirtualKey('A', false));
    try std.testing.expectEqual(KeyTag.s, keyTagFromVirtualKey('S', false));
    try std.testing.expectEqual(KeyTag.z, keyTagFromVirtualKey('Z', false));
    try std.testing.expectEqual(KeyTag.m, keyTagFromVirtualKey('M', false));
}

test "digit row and keypad are separate" {
    try std.testing.expectEqual(KeyTag.@"1", keyTagFromVirtualKey('1', false));
    try std.testing.expectEqual(KeyTag.@"0", keyTagFromVirtualKey('0', false));
    try std.testing.expectEqual(KeyTag.keypad_5, keyTagFromVirtualKey(win32.VK_NUMPAD0 + 5, false));
    try std.testing.expectEqual(KeyTag.keypad_decimal, keyTagFromVirtualKey(win32.VK_DECIMAL, false));
}

test "extended bit distinguishes keypad enter" {
    // 两者的 VK 码都是 VK_RETURN,只有 KF_EXTENDED 位不同。
    try std.testing.expectEqual(KeyTag.@"return", keyTagFromVirtualKey(win32.VK_RETURN, false));
    try std.testing.expectEqual(KeyTag.keypad_enter, keyTagFromVirtualKey(win32.VK_RETURN, true));
}

test "modifier left/right variants" {
    try std.testing.expectEqual(KeyTag.shift, keyTagFromVirtualKey(win32.VK_LSHIFT, false));
    try std.testing.expectEqual(KeyTag.right_shift, keyTagFromVirtualKey(win32.VK_RSHIFT, false));
    try std.testing.expectEqual(KeyTag.control, keyTagFromVirtualKey(win32.VK_LCONTROL, false));
    try std.testing.expectEqual(KeyTag.command, keyTagFromVirtualKey(win32.VK_LWIN, false));
}

test "arrows and navigation keys" {
    try std.testing.expectEqual(KeyTag.escape, keyTagFromVirtualKey(win32.VK_ESCAPE, false));
    try std.testing.expectEqual(KeyTag.left, keyTagFromVirtualKey(win32.VK_LEFT, false));
    try std.testing.expectEqual(KeyTag.page_up, keyTagFromVirtualKey(win32.VK_PRIOR, false));
    try std.testing.expectEqual(KeyTag.home, keyTagFromVirtualKey(win32.VK_HOME, false));
}

test "F keys cover F1-F20, F21+ unknown" {
    try std.testing.expectEqual(KeyTag.f1, keyTagFromVirtualKey(win32.VK_F1, false));
    try std.testing.expectEqual(KeyTag.f12, keyTagFromVirtualKey(win32.VK_F1 + 11, false));
    try std.testing.expectEqual(KeyTag.f20, keyTagFromVirtualKey(win32.VK_F1 + 19, false));
    try std.testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(win32.VK_F1 + 20, false));
}

test "unmapped VK folds to unknown" {
    try std.testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(win32.VK_SNAPSHOT, false));
    try std.testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(0xE0, false));
}

test "CharBuffer encodes BMP and surrogates" {
    var cb: CharBuffer = .{};

    // 'A' 单码元。
    try std.testing.expect(cb.pushUtf16('A'));
    try std.testing.expectEqualStrings("A", cb.slice());

    // U+1F600 😀 = 代理对 D83D DE00 → UTF-8 4 字节。
    try std.testing.expect(!cb.pushUtf16(0xD83D));
    try std.testing.expect(cb.pushUtf16(0xDE00));
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", cb.slice());

    // 落单的高半区不产生字符。
    try std.testing.expect(!cb.pushUtf16(0xD83D));
    try std.testing.expectEqual(@as(usize, 0), cb.slice().len);

    // CJK BMP 字符。
    try std.testing.expect(cb.pushUtf16(0x4E2D));
    try std.testing.expectEqualStrings("\xE4\xB8\xAD", cb.slice());
}

test "lparam coordinate extraction" {
    // x=100, y=50 打包进 lparam。
    const lparam: win32.LPARAM = @as(win32.LPARAM, 100) | @as(win32.LPARAM, 50) << 16;
    try std.testing.expectEqual(@as(i16, 100), mouseXFromLParam(lparam));
    try std.testing.expectEqual(@as(i16, 50), mouseYFromLParam(lparam));

    // 负坐标(客户区左上之外)符号扩展正确。
    const neg: win32.LPARAM = @as(win32.LPARAM, @bitCast(@as(u32, 0xFFFF_FFEC)));
    try std.testing.expectEqual(@as(i16, -20), mouseXFromLParam(neg));
}

test "wheel delta extraction" {
    // wParam 高位 = 120(一格向上)。
    const wparam: win32.WPARAM = @as(win32.WPARAM, 120) << 16;
    try std.testing.expectEqual(@as(i16, 120), wheelDeltaFromWParam(wparam));

    const down: win32.WPARAM = @as(win32.WPARAM, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    try std.testing.expectEqual(@as(i16, -120), wheelDeltaFromWParam(down));
}
