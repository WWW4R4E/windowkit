//! macOS 输入翻译 —— `NSEvent` 硬件键码（kVK_*）→ 跨平台 `input.KeyTag`。
//!
//! `input/events.zig` 的 `KeyTag` 与平台无关，只按名字描述按键；这里把
//! AppKit 的 `NSEvent.keyCode`（即 Carbon HIToolbox 的 kVK_* 键码）翻译
//! 过去。kVK 码按 US ANSI 物理位置排列，字母、数字行、标点一一对应；
//! 小键盘 / 功能键 / 修饰键查表，未收录的键码折叠成 `.unknown`。
//!
//! 平台原始键码只应出现在这里：核心输入模块不携带任何平台码值。

const std = @import("std");
const input = @import("../../input/events.zig");

pub const KeyTag = input.KeyTag;

/// macOS 虚拟键码（取自 Carbon `Events.h` 的 `kVK_*` 常量）。
pub const kvk = struct {
    // 字母
    pub const ANSI_A: u16 = 0x00;
    pub const ANSI_S: u16 = 0x01;
    pub const ANSI_D: u16 = 0x02;
    pub const ANSI_F: u16 = 0x03;
    pub const ANSI_H: u16 = 0x04;
    pub const ANSI_G: u16 = 0x05;
    pub const ANSI_Z: u16 = 0x06;
    pub const ANSI_X: u16 = 0x07;
    pub const ANSI_C: u16 = 0x08;
    pub const ANSI_V: u16 = 0x09;
    pub const ANSI_B: u16 = 0x0B;
    pub const ANSI_Q: u16 = 0x0C;
    pub const ANSI_W: u16 = 0x0D;
    pub const ANSI_E: u16 = 0x0E;
    pub const ANSI_R: u16 = 0x0F;
    pub const ANSI_Y: u16 = 0x10;
    pub const ANSI_T: u16 = 0x11;
    pub const ANSI_O: u16 = 0x1F;
    pub const ANSI_U: u16 = 0x20;
    pub const ANSI_I: u16 = 0x22;
    pub const ANSI_P: u16 = 0x23;
    pub const ANSI_L: u16 = 0x25;
    pub const ANSI_J: u16 = 0x26;
    pub const ANSI_K: u16 = 0x28;
    pub const ANSI_N: u16 = 0x2D;
    pub const ANSI_M: u16 = 0x2E;

    // 数字行
    pub const ANSI_1: u16 = 0x12;
    pub const ANSI_2: u16 = 0x13;
    pub const ANSI_3: u16 = 0x14;
    pub const ANSI_4: u16 = 0x15;
    pub const ANSI_6: u16 = 0x16;
    pub const ANSI_5: u16 = 0x17;
    pub const ANSI_EQUAL: u16 = 0x18;
    pub const ANSI_9: u16 = 0x19;
    pub const ANSI_7: u16 = 0x1A;
    pub const ANSI_MINUS: u16 = 0x1B;
    pub const ANSI_8: u16 = 0x1C;
    pub const ANSI_0: u16 = 0x1D;

    // 标点
    pub const ANSI_RIGHTBRACKET: u16 = 0x1E;
    pub const ANSI_LEFTBRACKET: u16 = 0x21;
    pub const ANSI_BACKSLASH: u16 = 0x2A;
    pub const ANSI_SEMICOLON: u16 = 0x29;
    pub const ANSI_QUOTE: u16 = 0x27;
    pub const ANSI_COMMA: u16 = 0x2B;
    pub const ANSI_SLASH: u16 = 0x2C;
    pub const ANSI_PERIOD: u16 = 0x2F;
    pub const ANSI_GRAVE: u16 = 0x32;

    // 特殊键
    pub const ANSI_RETURN: u16 = 0x24;
    pub const ANSI_TAB: u16 = 0x30;
    pub const ANSI_SPACE: u16 = 0x31;
    pub const ANSI_DELETE: u16 = 0x33; // 退格
    pub const ANSI_ESCAPE: u16 = 0x35;
    pub const FORWARD_DELETE: u16 = 0x75;

    // 小键盘
    pub const KEYPAD_DECIMAL: u16 = 0x41;
    pub const KEYPAD_MULTIPLY: u16 = 0x43;
    pub const KEYPAD_PLUS: u16 = 0x45;
    pub const KEYPAD_CLEAR: u16 = 0x47; // PC 键盘上对应 NumLock 位置
    pub const KEYPAD_DIVIDE: u16 = 0x4B;
    pub const KEYPAD_ENTER: u16 = 0x4C;
    pub const KEYPAD_MINUS: u16 = 0x4E;
    pub const KEYPAD_EQUALS: u16 = 0x51;
    pub const KEYPAD_0: u16 = 0x52;
    pub const KEYPAD_1: u16 = 0x53;
    pub const KEYPAD_2: u16 = 0x54;
    pub const KEYPAD_3: u16 = 0x55;
    pub const KEYPAD_4: u16 = 0x56;
    pub const KEYPAD_5: u16 = 0x57;
    pub const KEYPAD_6: u16 = 0x58;
    pub const KEYPAD_7: u16 = 0x59;
    pub const KEYPAD_8: u16 = 0x5B;
    pub const KEYPAD_9: u16 = 0x5C;

    // 修饰键
    pub const RIGHT_COMMAND: u16 = 0x36;
    pub const COMMAND: u16 = 0x37;
    pub const SHIFT: u16 = 0x38;
    pub const CAPS_LOCK: u16 = 0x39;
    pub const OPTION: u16 = 0x3A;
    pub const CONTROL: u16 = 0x3B;
    pub const RIGHT_SHIFT: u16 = 0x3C;
    pub const RIGHT_OPTION: u16 = 0x3D;
    pub const RIGHT_CONTROL: u16 = 0x3E;

    // 方向键
    pub const LEFT: u16 = 0x7B;
    pub const RIGHT: u16 = 0x7C;
    pub const DOWN: u16 = 0x7D;
    pub const UP: u16 = 0x7E;

    // 功能键
    pub const F17: u16 = 0x40;
    pub const F18: u16 = 0x4F;
    pub const F19: u16 = 0x50;
    pub const F20: u16 = 0x5A;
    pub const F5: u16 = 0x60;
    pub const F6: u16 = 0x61;
    pub const F7: u16 = 0x62;
    pub const F3: u16 = 0x63;
    pub const F8: u16 = 0x64;
    pub const F9: u16 = 0x65;
    pub const F11: u16 = 0x67;
    pub const F13: u16 = 0x69;
    pub const F16: u16 = 0x6A;
    pub const F14: u16 = 0x6B;
    pub const F10: u16 = 0x6D;
    pub const F12: u16 = 0x6F;
    pub const F15: u16 = 0x71;
    pub const F4: u16 = 0x76;
    pub const F2: u16 = 0x78;
    pub const F1: u16 = 0x7A;

    // 光标/导航键
    pub const HOME: u16 = 0x73;
    pub const END: u16 = 0x77;
    pub const PAGE_UP: u16 = 0x74;
    pub const PAGE_DOWN: u16 = 0x79;
};

/// macOS kVK 键码 → 跨平台 `KeyTag`。未收录的键码返回 `.unknown`。
pub fn keyTagFromVirtualKey(code: u16) KeyTag {
    return switch (code) {
        kvk.ANSI_A => .a,
        kvk.ANSI_B => .b,
        kvk.ANSI_C => .c,
        kvk.ANSI_D => .d,
        kvk.ANSI_E => .e,
        kvk.ANSI_F => .f,
        kvk.ANSI_G => .g,
        kvk.ANSI_H => .h,
        kvk.ANSI_I => .i,
        kvk.ANSI_J => .j,
        kvk.ANSI_K => .k,
        kvk.ANSI_L => .l,
        kvk.ANSI_M => .m,
        kvk.ANSI_N => .n,
        kvk.ANSI_O => .o,
        kvk.ANSI_P => .p,
        kvk.ANSI_Q => .q,
        kvk.ANSI_R => .r,
        kvk.ANSI_S => .s,
        kvk.ANSI_T => .t,
        kvk.ANSI_U => .u,
        kvk.ANSI_V => .v,
        kvk.ANSI_W => .w,
        kvk.ANSI_X => .x,
        kvk.ANSI_Y => .y,
        kvk.ANSI_Z => .z,

        kvk.ANSI_0 => .@"0",
        kvk.ANSI_1 => .@"1",
        kvk.ANSI_2 => .@"2",
        kvk.ANSI_3 => .@"3",
        kvk.ANSI_4 => .@"4",
        kvk.ANSI_5 => .@"5",
        kvk.ANSI_6 => .@"6",
        kvk.ANSI_7 => .@"7",
        kvk.ANSI_8 => .@"8",
        kvk.ANSI_9 => .@"9",

        kvk.ANSI_MINUS => .minus,
        kvk.ANSI_EQUAL => .equal,
        kvk.ANSI_LEFTBRACKET => .left_bracket,
        kvk.ANSI_RIGHTBRACKET => .right_bracket,
        kvk.ANSI_BACKSLASH => .backslash,
        kvk.ANSI_SEMICOLON => .semicolon,
        kvk.ANSI_QUOTE => .quote,
        kvk.ANSI_COMMA => .comma,
        kvk.ANSI_PERIOD => .period,
        kvk.ANSI_SLASH => .slash,
        kvk.ANSI_GRAVE => .grave,

        kvk.ANSI_RETURN => .@"return",
        kvk.ANSI_TAB => .tab,
        kvk.ANSI_SPACE => .space,
        kvk.ANSI_DELETE => .delete,
        kvk.ANSI_ESCAPE => .escape,
        kvk.FORWARD_DELETE => .forward_delete,

        kvk.KEYPAD_0 => .keypad_0,
        kvk.KEYPAD_1 => .keypad_1,
        kvk.KEYPAD_2 => .keypad_2,
        kvk.KEYPAD_3 => .keypad_3,
        kvk.KEYPAD_4 => .keypad_4,
        kvk.KEYPAD_5 => .keypad_5,
        kvk.KEYPAD_6 => .keypad_6,
        kvk.KEYPAD_7 => .keypad_7,
        kvk.KEYPAD_8 => .keypad_8,
        kvk.KEYPAD_9 => .keypad_9,
        kvk.KEYPAD_DECIMAL => .keypad_decimal,
        kvk.KEYPAD_MULTIPLY => .keypad_multiply,
        kvk.KEYPAD_PLUS => .keypad_plus,
        kvk.KEYPAD_CLEAR => .keypad_clear,
        kvk.KEYPAD_DIVIDE => .keypad_divide,
        kvk.KEYPAD_ENTER => .keypad_enter,
        kvk.KEYPAD_MINUS => .keypad_minus,
        kvk.KEYPAD_EQUALS => .keypad_equals,

        kvk.COMMAND => .command,
        kvk.SHIFT => .shift,
        kvk.CAPS_LOCK => .caps_lock,
        kvk.OPTION => .option,
        kvk.CONTROL => .control,
        kvk.RIGHT_COMMAND => .right_command,
        kvk.RIGHT_SHIFT => .right_shift,
        kvk.RIGHT_OPTION => .right_option,
        kvk.RIGHT_CONTROL => .right_control,

        kvk.LEFT => .left,
        kvk.RIGHT => .right,
        kvk.DOWN => .down,
        kvk.UP => .up,

        kvk.F1 => .f1,
        kvk.F2 => .f2,
        kvk.F3 => .f3,
        kvk.F4 => .f4,
        kvk.F5 => .f5,
        kvk.F6 => .f6,
        kvk.F7 => .f7,
        kvk.F8 => .f8,
        kvk.F9 => .f9,
        kvk.F10 => .f10,
        kvk.F11 => .f11,
        kvk.F12 => .f12,
        kvk.F13 => .f13,
        kvk.F14 => .f14,
        kvk.F15 => .f15,
        kvk.F16 => .f16,
        kvk.F17 => .f17,
        kvk.F18 => .f18,
        kvk.F19 => .f19,
        kvk.F20 => .f20,

        kvk.HOME => .home,
        kvk.END => .end,
        kvk.PAGE_UP => .page_up,
        kvk.PAGE_DOWN => .page_down,

        else => .unknown,
    };
}

test "kVK resolves to platform-neutral key tags" {
    const testing = std.testing;

    try testing.expectEqual(KeyTag.a, keyTagFromVirtualKey(kvk.ANSI_A));
    try testing.expectEqual(KeyTag.z, keyTagFromVirtualKey(kvk.ANSI_Z));
    try testing.expectEqual(KeyTag.@"5", keyTagFromVirtualKey(kvk.ANSI_5));
    try testing.expectEqual(KeyTag.@"return", keyTagFromVirtualKey(kvk.ANSI_RETURN));
    try testing.expectEqual(KeyTag.delete, keyTagFromVirtualKey(kvk.ANSI_DELETE));
    try testing.expectEqual(KeyTag.forward_delete, keyTagFromVirtualKey(kvk.FORWARD_DELETE));
    try testing.expectEqual(KeyTag.minus, keyTagFromVirtualKey(kvk.ANSI_MINUS));
    try testing.expectEqual(KeyTag.keypad_enter, keyTagFromVirtualKey(kvk.KEYPAD_ENTER));
    try testing.expectEqual(KeyTag.keypad_clear, keyTagFromVirtualKey(kvk.KEYPAD_CLEAR));
    try testing.expectEqual(KeyTag.f20, keyTagFromVirtualKey(kvk.F20));

    // 空档与越界都折叠成 unknown。
    try testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(0x42));
    try testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(0xFFFF));
}
