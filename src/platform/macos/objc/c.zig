//! 手写的 `extern "c"` 声明，覆盖平台层实际调用的那部分 Objective-C
//! 运行时。取代对 `<objc/runtime.h>` + `<objc/message.h>` 的 translate-c
//! 依赖，完全省掉 xcrun / Apple-SDK 路径的构建环节。系统 `objc` 库和
//! Foundation 框架仍由 build.zig 链接，符号在那里解析。
//!
//! 只声明调用点用得到的函数和类型。需要新的运行时调用时，加一条
//! 声明即可，不要引入代码生成器。

/// Objective-C 运行时命名空间，公开为 `objc.c`。内部模块以
/// `@import("c.zig").c` 引入；直接触碰运行时的文件引用的都是
/// `objc.c.id`、`objc.c.SEL` 和 `objc.c.class_addProtocol`。
pub const c = struct {
    // 不透明的运行时类型。刻意做成互不相同的 Zig 类型（而不是全部
    // 别名 `?*anyopaque`），类型编码和 msgSend 的参数解包才能区分
    // `id` / `Class` / `SEL` / `Protocol` —— 它们各自编码不同
    // （'@' / '#' / ':'），否则 switch 里会出现重复分支。
    pub const objc_object = opaque {};
    pub const objc_class = opaque {};
    pub const objc_selector = opaque {};
    pub const objc_protocol = opaque {};
    pub const objc_ivar = opaque {};

    pub const id = ?*objc_object;
    pub const Class = ?*objc_class;
    pub const SEL = ?*objc_selector;
    pub const Protocol = objc_protocol;
    pub const Ivar = ?*objc_ivar;

    // Apple 的 <objc/objc.h> 在 x86_64 上把 BOOL 定义为 `signed char`，
    // 在 arm64 上是 C99 `_Bool`。这里统一建模为 `i8`：i8 返回与两者
    // ABI 兼容（返回寄存器里一个 0/1 字节），调用点也能按运行时 C API
    // 的习惯比较结果（如 `class_addProtocol(...) == 0`）。
    // `boolResult` 再把它映射回 Zig 的 `bool`。
    pub const BOOL = i8;

    // --- 类与 selector ---------------------------------------------
    pub extern fn objc_getClass(name: [*c]const u8) Class;
    pub extern fn sel_registerName(str: [*c]const u8) SEL;

    // --- 动态类构建 --------------------------------------
    pub extern fn objc_allocateClassPair(superclass: Class, name: [*c]const u8, extra_bytes: usize) Class;
    pub extern fn objc_registerClassPair(cls: Class) void;
    pub extern fn class_addMethod(cls: Class, name: SEL, imp: ?*const anyopaque, types: [*c]const u8) BOOL;
    pub extern fn class_addIvar(cls: Class, name: [*c]const u8, size: usize, alignment: u8, types: [*c]const u8) BOOL;
    pub extern fn class_addProtocol(cls: Class, protocol: *objc_protocol) BOOL;

    // --- 协议 -------------------------------------------------------
    pub extern fn objc_getProtocol(name: [*c]const u8) ?*objc_protocol;

    // --- 实例变量 ----------------------------------------------
    pub extern fn object_getInstanceVariable(obj: id, name: [*c]const u8, out_value: ?*?*anyopaque) Ivar;
    pub extern fn object_getIvar(obj: id, ivar: Ivar) id;
    pub extern fn object_setIvar(obj: id, ivar: Ivar, value: id) void;

    // --- 引用计数 ----------------------------------------------
    pub extern fn objc_release(obj: id) void;

    // --- 消息发送 ----------------------------------------------------
    // 声明为零参数 C 函数，在每个调用点再按正确签名重转（见
    // msg_send.zig）；objc_msgSend 必须按真实目标方法的 ABI 调用，
    // 绝不能当可变参数函数调。本项目只针对 Apple Silicon —— 那里单
    // 一入口即可处理所有返回类型，x86_64 的 `_stret` / `_fpret`
    // 变体有意缺失。
    pub extern fn objc_msgSend() callconv(.c) void;
};

/// 把运行时 `BOOL` 返回值转成 Zig `bool`。非零即 true，与 C 语义一致。
pub fn boolResult(result: c.BOOL) bool {
    return result != 0;
}
