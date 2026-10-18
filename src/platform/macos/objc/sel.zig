//! Selector 封装。`Sel` 是运行时对方法名的驻留（interned）表示。
//! `msgSend` 接受字符串字面量（即时注册）或已注册的 `Sel`。

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

/// 简写，等价于 `Sel.registerName`。
pub inline fn sel(name: [:0]const u8) Sel {
    return Sel.registerName(name);
}

pub const Sel = struct {
    value: c.SEL,

    /// 向 Objective-C 运行时注册方法名并返回其 selector。
    /// 注册幂等：同一名字在进程生命周期内总是映射到同一 selector。
    pub fn registerName(name: [:0]const u8) Sel {
        assert(name.len > 0);
        return .{ .value = c.sel_registerName(name.ptr) };
    }
};
