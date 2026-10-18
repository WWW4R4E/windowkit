//! NSWindowDelegate 实现：处理窗口事件。
//! 这是对性能最友好的路径 —— 不调整窗口大小时零开销。

const objc = @import("objc");

const Window = @import("window.zig").Window;

var delegate_class: ?objc.Class = null;

/// 向 Objective-C 运行时注册 WkWindowDelegate 类。
/// 必须在任何窗口创建前调用一次。
pub fn registerClass() !void {
    if (delegate_class != null) return;

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;

    var cls = objc.allocateClassPair(NSObject, "WkWindowDelegate") orelse
        return error.ClassAllocationFailed;

    // 添加 ivar 存放 Zig Window 指针
    if (!cls.addIvar("_wkWindow")) {
        return error.IvarAddFailed;
    }

    // 注册 delegate 方法
    if (!cls.addMethod("windowShouldClose:", windowShouldClose)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidResize:", windowDidResize)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidChangeBackingProperties:", windowDidChangeBackingProperties)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowWillClose:", windowWillClose)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidBecomeKey:", windowDidBecomeKey)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidResignKey:", windowDidResignKey)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowWillStartLiveResize:", windowWillStartLiveResize)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidEndLiveResize:", windowDidEndLiveResize)) {
        return error.MethodAddFailed;
    }

    objc.registerClassPair(cls);
    delegate_class = cls;
}

/// 为一个窗口创建 delegate 实例
pub fn create(window: *Window) !objc.Object {
    if (delegate_class == null) {
        try registerClass();
    }

    const cls = delegate_class.?;
    const delegate = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});

    // 把 Zig 窗口指针存进 delegate 的 ivar。
    // 用 objc.Object 包一层裸指针（只是当作 id 存放）
    const window_obj = objc.Object.fromId(@as(objc.c.id, @ptrCast(window)));
    delegate.setInstanceVariable("_wkWindow", window_obj);

    return delegate;
}

/// 从 delegate 实例取回 Zig Window
inline fn getWindow(self: objc.c.id) ?*Window {
    const delegate = objc.Object.fromId(self);
    const ptr = delegate.getInstanceVariable("_wkWindow");
    return @ptrCast(@alignCast(ptr.value));
}

// =============================================================================
// Delegate 方法实现
// =============================================================================

fn windowDidResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleResize();
}

fn windowDidChangeBackingProperties(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // 窗口移到不同缩放系数的显示器上时会触发此回调
    const window = getWindow(self) orelse return;
    window.handleResize(); // 缩放系数可能变了
}

fn windowShouldClose(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return true;
    return window.handleClose();
}

fn windowWillClose(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // 故意留空。AppKit 在 `-close` 内部同步调用此回调：NSWindow 仍在栈上
    // 存活，可能还有在途回调正引用窗口状态，在这里销毁窗口必然 use-after-free。
    // 拒绝关闭走 `windowShouldClose:` → `handleClose` 终止 DisplayLink 并置
    // `closed = true`；窗口资源的回收由宿主在 `deinit` 完成。
}

fn windowDidBecomeKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleFocusChange(true);
}

fn windowDidResignKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleFocusChange(false);
}

fn windowWillStartLiveResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleLiveResizeStart();
}

fn windowDidEndLiveResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleLiveResizeEnd();
}
