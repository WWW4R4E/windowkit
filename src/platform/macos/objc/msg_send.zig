//! `objc_msgSend` 的 ABI 转换核心，整个运行时封装的关键：为每个调用点
//! 构造正确类型的 C 函数指针，并在调用前把包装类型参数
//! （Object / Class / Sel）解包为底层 `c.id` / `c.Class` / `c.SEL`。
//!
//! 只提供普通 `msgSend` 形式。平台层从不直接调用 super 实现，
//! `objc_msgSendSuper`（连同 `objc_super` 结构体）因此有意省略。
//!
//! 仅支持 Apple Silicon (aarch64)：单条 `objc_msgSend` 入口即可处理
//! 所有返回类型，x86_64 的 `_stret` / `_fpret` 返回类型分发不实现。

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const objc = @import("main.zig");

comptime {
    // 不支持的架构上要大声失败，而不是静默生成错误的 struct/float 返回：
    // aarch64 上所有返回类型都走同一条 `objc_msgSend`，
    // x86_64 则需要本封装有意省略的 `_stret` / `_fpret` 变体。
    if (builtin.target.cpu.arch != .aarch64)
        @compileError("本项目的 Objective-C 封装仅支持 aarch64 (Apple Silicon)");
}

/// 返回一个为类型 T 实现 `msgSend` 的结构体。T 必须是带 `value` 字段、
/// 宽度和 `id` 一致的 struct（Object、Class 等）。
pub fn MsgSend(comptime T: type) type {
    return struct {
        /// 对目标调用 selector，即对象上的实例方法或类上的类方法。
        /// `args` 必须是 tuple。
        pub fn msgSend(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            // 本封装的唯一特例：返回类型是自己的 Object 时，包一层裸 id。
            const is_object = Return == objc.Object;

            // 包装时真正的 ABI 返回类型是 `id`，否则信任调用方给的类型。
            const RealReturn = if (is_object) c.id else Return;

            // 既接受已注册的 Sel，也接受需要注册的字符串。
            const sel: objc.Sel = switch (@TypeOf(sel_raw)) {
                objc.Sel => sel_raw,
                else => objc.sel(sel_raw),
            };

            // 构造具体的函数类型并经它调 objc_msgSend。
            // aarch64 上单一入口服务所有返回类型。
            const Fn = MsgSendFn(RealReturn, @TypeOf(target.value), @TypeOf(args));
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(&c.objc_msgSend));

            // 把参数里的包装类型解包成底层 C 值。
            const unwrapped_args = buildUnwrappedArgs(args);
            const result = @call(.auto, msg_send_ptr, .{ target.value, sel.value } ++ unwrapped_args);

            if (!is_object) return result;
            return .{ .value = result };
        }
    };
}

/// 返回与给定返回类型、目标类型、参数 tuple 匹配的 `objc_msgSend`
/// C 函数指针类型。
///
/// objc_msgSend 的特殊之处：必须按*真实*目标方法的 C ABI 调用，
/// 不能当可变参数 C 函数调。所以先合成精确的函数类型，把它
/// cast 到 objc_msgSend 上再调用。
///
///     // 错误（得到垃圾）：objc_msgSend(obj, sel, (float)x)
///     // 正确：((void (*)(id, SEL, float))objc_msgSend)(obj, sel, x)
fn MsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime Args: type,
) type {
    const argsInfo = @typeInfo(Args).@"struct";
    assert(argsInfo.is_tuple);

    // 目标必须始终是 `id` 宽度的值（Class、Object 等）。
    assert(@sizeOf(Target) == @sizeOf(c.id));

    // 逐个搭参数类型：target、selector，然后是解包后的 args。
    var param_types: [argsInfo.field_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = c.SEL;
    for (argsInfo.field_types, 0..) |field_type, i| param_types[i + 2] = unwrapType(field_type);

    return @Fn(&param_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

fn UnwrappedArgs(comptime Args: type) type {
    const field_types = @typeInfo(Args).@"struct".field_types;
    var types: [field_types.len]type = undefined;
    for (field_types, 0..) |field_type, i| types[i] = unwrapType(field_type);
    return @Tuple(&types);
}

/// 把 objc 包装类型映射到底层 C 类型供 `@Fn` 签名使用，
/// 并校验其余类型兼容 C ABI。
fn unwrapType(comptime T: type) type {
    // 解包 objc.Object。
    if (T == objc.Object) return c.id;

    // 解包其余 objc 包装类型（Class、Sel 等）—— 判据是只有单个指针
    // 宽度的 `value` 字段。返回真实字段类型而不是 c.id，
    // 因为 Class 和 Sel 的指针类型互不相同。
    if (@typeInfo(T) == .@"struct") {
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, "value") and @sizeOf(field_type) == @sizeOf(c.id)) {
                return field_type;
            }
        }
    }

    // 校验剩余类型能安全过 C ABI。不兼容的类型（比如 []const u8）只会
    // 编译通过却在 objc_msgSend 处段错误；这些检查让它变成编译错误。
    switch (@typeInfo(T)) {
        .int, .float, .bool, .void => {},
        .@"enum" => {},
        .pointer => {},
        .optional => |opt| {
            if (@typeInfo(opt.child) != .pointer)
                @compileError("msgSend: " ++ @typeName(T) ++ " — optional must wrap a pointer");
        },
        .@"struct" => |s| {
            if (s.layout != .@"extern" and s.layout != .@"packed")
                @compileError("msgSend: " ++ @typeName(T) ++ " — struct must be extern or packed");
        },
        .@"union" => |u| {
            if (u.layout != .@"extern")
                @compileError("msgSend: " ++ @typeName(T) ++ " — union must be extern");
        },
        else => @compileError("msgSend: " ++ @typeName(T) ++ " — not C-ABI compatible"),
    }

    return T;
}

inline fn buildUnwrappedArgs(args: anytype) UnwrappedArgs(@TypeOf(args)) {
    const field_types = @typeInfo(@TypeOf(args)).@"struct".field_types;
    var result: UnwrappedArgs(@TypeOf(args)) = undefined;
    inline for (field_types, 0..) |_, i| {
        result[i] = if (unwrapType(@TypeOf(args[i])) != @TypeOf(args[i]))
            args[i].value
        else
            args[i];
    }
    return result;
}

test "MsgSendFn produces the expected C function type" {
    const testing = std.testing;
    try testing.expectEqual(fn (
        c.id,
        c.SEL,
    ) callconv(.c) u64, MsgSendFn(u64, c.id, @TypeOf(.{})));
    try testing.expectEqual(fn (c.id, c.SEL, u16, u32) callconv(.c) u64, MsgSendFn(u64, c.id, @TypeOf(.{
        @as(u16, 0),
        @as(u32, 0),
    })));
}
