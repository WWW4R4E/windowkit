//! Class 封装。覆盖平台层用到的能力：给类发消息（如 `+alloc`、
//! `+stringWithUTF8String:`）、按名字查类，以及在运行时构建自定义类对
//! （NSTextInputClient 的 view），用到 `allocateClassPair` + `addIvar` +
//! `addMethod` + `registerClassPair`。

const std = @import("std");
const assert = std.debug.assert;
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Class = struct {
    value: c.Class,

    // Implement msgSend.
    const msg_send = MsgSend(Class);
    pub const msgSend = msg_send.msgSend;

    /// 给类添加新方法。`imp` 必须是 C 调用约定、前两个参数为 `c.id`
    /// （self）和 `c.SEL`（selector）的函数。成功返回 true。只在
    /// `allocateClassPair` 与 `registerClassPair` 之间有效。
    pub fn addMethod(self: Class, name: [:0]const u8, imp: anytype) bool {
        const Fn = @TypeOf(imp);
        const fn_info = @typeInfo(Fn).@"fn";
        assert(std.meta.eql(fn_info.attrs.@"callconv", std.builtin.CallingConvention.c));
        assert(fn_info.attrs.varargs == false);
        assert(fn_info.param_types.len >= 2);
        assert(fn_info.param_types[0] == c.id);
        assert(fn_info.param_types[1] == c.SEL);
        const encoding = comptime objc.comptimeEncode(Fn);
        return boolResult(c.class_addMethod(
            self.value,
            objc.sel(name).value,
            @ptrCast(&imp),
            &encoding,
        ));
    }

    /// 给类添加类型为 `id` 的实例变量。只在 `allocateClassPair` 与
    /// `registerClassPair` 之间有效。成功返回 true。
    pub fn addIvar(self: Class, name: [:0]const u8) bool {
        const result = c.class_addIvar(self.value, name.ptr, @sizeOf(c.id), @alignOf(c.id), "@");
        return boolResult(result);
    }
};

/// 按名字查找已注册的类，未知返回 null。
pub fn getClass(name: [:0]const u8) ?Class {
    assert(name.len > 0);
    return .{ .value = c.objc_getClass(name.ptr) orelse return null };
}

/// 开始定义新类。所有 ivar 和方法添加完后再对结果调 `registerClassPair`。
pub fn allocateClassPair(superclass: ?Class, name: [:0]const u8) ?Class {
    assert(name.len > 0);
    if (superclass) |cls| assert(cls.value != null);
    return .{ .value = c.objc_allocateClassPair(
        if (superclass) |cls| cls.value else null,
        name.ptr,
        0,
    ) orelse return null };
}

/// 完成类定义，运行时此后可以实例化它。
pub fn registerClassPair(class: Class) void {
    assert(class.value != null);
    c.objc_registerClassPair(class.value);
}
