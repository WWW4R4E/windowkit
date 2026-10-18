//! 项目内置的精简 ObjC 运行时封装，零外部依赖。
//!
//! 只覆盖平台层用到的调用面：类/对象的获取与动态类构建（ivars、方法、
//! 协议）、消息发送、selector、类型编码、autorelease pool。不带任何
//! `translate-c` / xcrun / Apple-SDK 路径的构建环节，`@import("objc")`
//! 的公开形状与常见 zig-objc 模块一致。
//!
//! 有意省略（平台层用不到）：blocks、fast enumeration 迭代器、properties、
//! 调 super 的消息发送路径、metaclass、retain、类对的销毁。

const autorelease = @import("autorelease.zig");
const class = @import("class.zig");
const encoding = @import("encoding.zig");
const object = @import("object.zig");
const protocol = @import("protocol.zig");
const selpkg = @import("sel.zig");

/// 裸的 Objective-C 运行时命名空间（类型 + `extern` 函数）。公开这一层
/// 是为了让调用点能写 `objc.c.id`、`objc.c.SEL` 等，框架全局变量也可
/// 声明为 `extern "c" var x: objc.c.id`。
pub const c = @import("c.zig").c;

pub const AutoreleasePool = autorelease.AutoreleasePool;

pub const Object = object.Object;

pub const Class = class.Class;
pub const getClass = class.getClass;
pub const allocateClassPair = class.allocateClassPair;
pub const registerClassPair = class.registerClassPair;

pub const Protocol = protocol.Protocol;
pub const getProtocol = protocol.getProtocol;

pub const Encoding = encoding.Encoding;
pub const comptimeEncode = encoding.comptimeEncode;

pub const sel = selpkg.sel;
pub const Sel = selpkg.Sel;

test {
    @import("std").testing.refAllDecls(@This());
}
