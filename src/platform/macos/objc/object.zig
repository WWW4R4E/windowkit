//! Object 即类的实例。覆盖平台层的用法：`msgSend`、`fromId`、`release`
//! 与 id 类型的实例变量读写。（自定义 NSView 子类把所属 Zig `Window`
//! 指针存在 ivar 里，`get`/`setInstanceVariable` 就是为此服务的。）

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const MsgSend = @import("msg_send.zig").MsgSend;

pub const Object = struct {
    value: c.id,

    // Implement msgSend.
    const msg_send = MsgSend(Object);
    pub const msgSend = msg_send.msgSend;

    /// 把裸 `id` 转成 Object。入参必须与 C 的 `id` 等宽（指针大小）。
    pub fn fromId(id: anytype) Object {
        if (@sizeOf(@TypeOf(id)) != @sizeOf(c.id)) {
            @compileError("invalid id type");
        }

        // 有些 Objective-C 指针是 tagged pointer：小对象和字面量
        // （NSNumber、NSString）直接编码在指针位里，不经堆分配。
        // 它们可能未按指针对齐，转换时关掉运行时安全检查。
        const ptr: c.id = blk: {
            @setRuntimeSafety(false);
            break :blk @ptrCast(@alignCast(id));
        };

        return .{ .value = ptr };
    }

    /// 按名字读取 id 类型的实例变量。
    pub fn getInstanceVariable(self: Object, name: [:0]const u8) Object {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        // ivar 为空说明该类没有这个名字；直接读会静默得到 nil，源头就失败。
        assert(ivar != null);
        return fromId(c.object_getIvar(self.value, ivar));
    }

    /// 按名字写入 id 类型的实例变量。
    pub fn setInstanceVariable(self: Object, name: [:0]const u8, val: Object) void {
        assert(self.value != null);
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null);
        // ivar 为空说明该类没有这个名字；直接写是静默 no-op，源头就失败。
        assert(ivar != null);
        c.object_setIvar(self.value, ivar, val.value);
    }

    /// 释放一次 +1 引用。配对的 retain 来自 alloc/copy 或显式 retain。
    pub fn release(self: Object) void {
        c.objc_release(self.value);
    }
};
