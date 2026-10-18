//! IME 组合缓冲。
//! 处理 IME 组合期间的 preedit/被标记文本。
//!
//! 缓冲里存的是用户提交前带下划线显示的组合文本
//! （比如输入中文拼音的过程）。

const input = @import("../../input/events.zig");

pub const BUFFER_SIZE = 256;

/// 来自 IME 的组合状态
pub const CompositionBuffer = extern struct {
    /// 组合文本的当前长度
    len: u32 align(4) = 0,
    /// 组合是否在进行中
    active: u8 = 0,
    /// 一次性事件标志；组合结束/取消时发出的空事件也用它。
    pending: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    /// 组合/preedit 文本
    data: [BUFFER_SIZE]u8 = undefined,

    const Self = @This();

    pub fn isActive(self: *const volatile Self) bool {
        return self.active != 0;
    }

    pub fn hasText(self: *const volatile Self) bool {
        return self.len > 0;
    }

    pub fn hasPending(self: *const volatile Self) bool {
        return self.pending != 0;
    }

    pub fn getText(self: *volatile Self) []const u8 {
        const length = self.len;
        const non_volatile = @as(*Self, @volatileCast(self));
        return non_volatile.data[0..length];
    }

    pub fn clear(self: *volatile Self) void {
        self.len = 0;
        self.active = 0;
        self.pending = 0;
    }
};

comptime {
    if (@sizeOf(CompositionBuffer) != 8 + BUFFER_SIZE) @compileError("CompositionBuffer size mismatch");
}

// 全局实例
pub var g_composition_buffer: CompositionBuffer = .{};

// 给 JS 用的导出指针
fn getCompositionBufferPtr() callconv(.c) [*]u8 {
    return @ptrCast(&g_composition_buffer);
}

comptime {
    @export(&getCompositionBufferPtr, .{ .name = "getCompositionBufferPtr" });
}

const InputEvent = input.InputEvent;

/// 处理待处理的组合事件
pub fn processComposition(handler: *const fn (InputEvent) bool) bool {
    const buf = @as(*volatile CompositionBuffer, &g_composition_buffer);
    if (!buf.hasPending()) return false;

    const text = buf.getText();
    const event = InputEvent{ .composition = .{ .text = text } };
    _ = handler(event);
    buf.pending = 0;

    return true;
}

test "composition end emits one empty event to clear retained preedit" {
    // 浏览器的取消/结束用 pending + 零字节表示。该事件恰好被消费
    // 一次，此后模型才能继续对账。
    const Capture = struct {
        var calls: u32 = 0;

        fn handler(event: InputEvent) bool {
            calls += 1;
            return event.composition.text.len == 0;
        }
    };
    const buf = @as(*volatile CompositionBuffer, &g_composition_buffer);
    buf.clear();
    defer buf.clear();
    Capture.calls = 0;
    buf.pending = 1;

    try @import("std").testing.expect(processComposition(Capture.handler));
    try @import("std").testing.expectEqual(@as(u32, 1), Capture.calls);
    try @import("std").testing.expect(!processComposition(Capture.handler));
}
