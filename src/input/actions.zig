//! Action 系统 — 声明式按键绑定 + 按上下文分发。
//!
//! 把"做什么操作"和"按什么键触发"解耦：
//! - 用空类型定义 action（Undo、Save 等）
//! - 在 keymap 里把按键串绑定到 action
//! - 组件为自己支持的 action 注册处理函数
//! - 分发时按 按键 → action → 处理函数 匹配，受当前激活上下文过滤
//!
//! 例：
//! ```zig
//! // 定义 action
//! const Undo = struct {};
//! const Save = struct {};
//!
//! // 绑定按键（一般放在应用初始化）
//! keymap.bind(Undo, "cmd-z", null);       // 全局生效
//! keymap.bind(Save, "cmd-s", "Editor");   // 仅在 Editor 上下文生效
//!
//! // 组件里注册处理函数：
//! dispatch.onAction(Undo, handleUndo);
//! ```

const std = @import("std");
const input_mod = @import("events.zig");

const KeyTag = input_mod.KeyTag;
const Modifiers = input_mod.Modifiers;

// =============================================================================
// Keystroke（按键组合）
// =============================================================================

/// 解析好的按键，如 "cmd-z" 或 "ctrl-shift-s"
pub const Keystroke = struct {
    key: KeyTag,
    modifiers: Modifiers,

    const Self = @This();

    /// 解析按键串，如 "cmd-z"、"ctrl-shift-s"、"escape"。
    pub fn parse(str: []const u8) ?Self {
        var mods = Modifiers{};
        var remaining = str;

        // 逐段解析修饰键前缀
        while (true) {
            if (startsWith(remaining, "cmd-") or startsWith(remaining, "super-")) {
                mods.cmd = true;
                remaining = remaining[4..];
            } else if (startsWith(remaining, "ctrl-")) {
                mods.ctrl = true;
                remaining = remaining[5..];
            } else if (startsWith(remaining, "alt-") or startsWith(remaining, "opt-")) {
                mods.alt = true;
                remaining = remaining[4..];
            } else if (startsWith(remaining, "shift-")) {
                mods.shift = true;
                remaining = remaining[6..];
            } else {
                break;
            }
        }

        // 解析键名
        const key = parseKeyName(remaining) orelse return null;

        return .{ .key = key, .modifiers = mods };
    }

    /// 判断按键是否与某个 key event 匹配。
    pub fn matches(self: Self, key: KeyTag, mods: Modifiers) bool {
        return self.key == key and
            self.modifiers.cmd == mods.cmd and
            self.modifiers.ctrl == mods.ctrl and
            self.modifiers.alt == mods.alt and
            self.modifiers.shift == mods.shift;
    }

    fn startsWith(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        return std.mem.eql(u8, haystack[0..needle.len], needle);
    }

    fn parseKeyName(name: []const u8) ?KeyTag {
        // 具名键（含单字符）
        const map = std.StaticStringMap(KeyTag).initComptime(.{
            // 字母
            .{ "a", .a },           .{ "b", .b },         .{ "c", .c },              .{ "d", .d },
            .{ "e", .e },           .{ "f", .f },         .{ "g", .g },              .{ "h", .h },
            .{ "i", .i },           .{ "j", .j },         .{ "k", .k },              .{ "l", .l },
            .{ "m", .m },           .{ "n", .n },         .{ "o", .o },              .{ "p", .p },
            .{ "q", .q },           .{ "r", .r },         .{ "s", .s },              .{ "t", .t },
            .{ "u", .u },           .{ "v", .v },         .{ "w", .w },              .{ "x", .x },
            .{ "y", .y },           .{ "z", .z },
            // 数字
                    .{ "0", .@"0" },           .{ "1", .@"1" },
            .{ "2", .@"2" },        .{ "3", .@"3" },      .{ "4", .@"4" },           .{ "5", .@"5" },
            .{ "6", .@"6" },        .{ "7", .@"7" },      .{ "8", .@"8" },           .{ "9", .@"9" },
            // 特殊键
            .{ "escape", .escape }, .{ "esc", .escape },  .{ "return", .@"return" }, .{ "enter", .@"return" },
            .{ "tab", .tab },       .{ "space", .space }, .{ "backspace", .delete }, .{ "delete", .forward_delete },
            // 方向键
            .{ "up", .up },         .{ "down", .down },   .{ "left", .left },        .{ "right", .right },
            // 光标/导航键
            .{ "home", .home },     .{ "end", .end },     .{ "pageup", .page_up },   .{ "pagedown", .page_down },
            // 功能键
            .{ "f1", .f1 },         .{ "f2", .f2 },       .{ "f3", .f3 },            .{ "f4", .f4 },
            .{ "f5", .f5 },         .{ "f6", .f6 },       .{ "f7", .f7 },            .{ "f8", .f8 },
            .{ "f9", .f9 },         .{ "f10", .f10 },     .{ "f11", .f11 },          .{ "f12", .f12 },
        });

        return map.get(name);
    }
};

// =============================================================================
// Action 类型 ID
// =============================================================================

/// 类型擦除后的 action 标识。
pub const ActionTypeId = usize;

/// 取某个 action 类型的唯一 ID。
/// 用类型名的地址，每个类型唯一。
pub fn actionTypeId(comptime T: type) ActionTypeId {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

// =============================================================================
// 按键绑定（KeyBinding）
// =============================================================================

/// 按键到 action 的绑定。
pub const KeyBinding = struct {
    keystroke: Keystroke,
    action_type: ActionTypeId,
    /// 绑定要求的上下文（null = 全局）
    context: ?[]const u8,
};

// =============================================================================
// Keymap（按键 → action 映射）
// =============================================================================

/// 按键 → action 映射表，绑定可要求特定上下文。
pub const Keymap = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayListUnmanaged(KeyBinding) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.bindings.deinit(self.allocator);
    }

    /// 把按键串绑定到 action 类型。解析失败则静默忽略。
    pub fn bind(
        self: *Self,
        comptime Action: type,
        keystroke_str: []const u8,
        context: ?[]const u8,
    ) void {
        const keystroke = Keystroke.parse(keystroke_str) orelse return;
        self.bindings.append(self.allocator, .{
            .keystroke = keystroke,
            .action_type = actionTypeId(Action),
            .context = context,
        }) catch {};
    }

    /// 按当前激活的上下文查找匹配的绑定。
    pub fn match(
        self: *const Self,
        key: KeyTag,
        mods: Modifiers,
        active_contexts: []const []const u8,
    ) ?KeyBinding {
        // 倒序遍历绑定（后绑定的覆盖先绑定的）
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.bindings.items[i];

            if (!binding.keystroke.matches(key, mods)) continue;

            // 检查上下文要求
            if (binding.context) |required_ctx| {
                var found = false;
                for (active_contexts) |ctx| {
                    if (std.mem.eql(u8, ctx, required_ctx)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            return binding;
        }

        return null;
    }
};

// =============================================================================
// 测试
// =============================================================================

test "keystroke parsing" {
    const ks1 = Keystroke.parse("cmd-z").?;
    try std.testing.expectEqual(KeyTag.z, ks1.key);
    try std.testing.expect(ks1.modifiers.cmd);
    try std.testing.expect(!ks1.modifiers.shift);

    const ks2 = Keystroke.parse("ctrl-shift-s").?;
    try std.testing.expectEqual(KeyTag.s, ks2.key);
    try std.testing.expect(ks2.modifiers.ctrl);
    try std.testing.expect(ks2.modifiers.shift);

    const ks3 = Keystroke.parse("escape").?;
    try std.testing.expectEqual(KeyTag.escape, ks3.key);
}

test "keymap binding and matching" {
    const allocator = std.testing.allocator;
    var keymap = Keymap.init(allocator);
    defer keymap.deinit();

    const Undo = struct {};
    const Save = struct {};

    keymap.bind(Undo, "cmd-z", null); // 全局
    keymap.bind(Save, "cmd-s", "Editor"); // 仅 Editor

    // cmd-z 全局都能匹配
    const match1 = keymap.match(.z, .{ .cmd = true }, &.{});
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(actionTypeId(Undo), match1.?.action_type);

    // cmd-s 需要 Editor 上下文才匹配
    const match2 = keymap.match(.s, .{ .cmd = true }, &.{});
    try std.testing.expect(match2 == null);

    const match3 = keymap.match(.s, .{ .cmd = true }, &.{"Editor"});
    try std.testing.expect(match3 != null);
    try std.testing.expectEqual(actionTypeId(Save), match3.?.action_type);
}
