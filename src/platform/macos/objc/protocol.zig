//! 最小 Protocol 封装。平台层只需要按名字查协议（`getProtocol`），并在
//! 构建自定义 NSTextInputClient view 类时把底层指针交给
//! `class_addProtocol`。上层的协议内省一概不用，所以只暴露 `.value`。

const c = @import("c.zig").c;

pub const Protocol = struct {
    value: *c.Protocol,
};

/// 按名字查找已注册的协议，运行时不认识时返回 null。
pub fn getProtocol(name: [:0]const u8) ?Protocol {
    return .{ .value = c.objc_getProtocol(name.ptr) orelse return null };
}
