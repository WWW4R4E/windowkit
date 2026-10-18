//! Autorelease pool 封装。在有会派发 autoreleased ObjC 对象的工作区
//! （如每帧的 Foundation 临时对象）外面包一层 pool，让对象确定性
//! 回收而不是持续堆积。

pub const AutoreleasePool = opaque {
    /// 新建 autorelease pool。清理调 deinit。
    pub inline fn init() *AutoreleasePool {
        return @ptrCast(objc_autoreleasePoolPush().?);
    }

    pub inline fn deinit(self: *AutoreleasePool) void {
        objc_autoreleasePoolPop(self);
    }
};

// 这两个符号不在任何公开头文件里，但是 @autoreleasepool 背后
// 有文档的稳定 ABI，跨 macOS 版本不变。
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;
