//! 自定义 NSView 子类：接收鼠标/键盘事件。
//! 实现 NSTextInputClient 以支持 IME（选字、死键、中日韩输入）。

const std = @import("std");
const objc = @import("objc");
const input = @import("../../input/events.zig");
const mac_input = @import("input.zig");
const geometry = @import("../../geometry.zig");
const appkit = @import("appkit.zig");
const Window = @import("window.zig").Window;

const NSRect = appkit.NSRect;
const NSPoint = appkit.NSPoint;
const NSRange = appkit.NSRange;
const NSEventModifierFlags = appkit.NSEventModifierFlags;

var view_class: ?objc.Class = null;

/// 向 Objective-C 运行时注册 WkContentView 类。
/// 必须在任何窗口创建前调用一次。
pub fn registerClass() !void {
    if (view_class != null) return;

    const NSView = objc.getClass("NSView") orelse return error.ClassNotFound;

    var cls = objc.allocateClassPair(NSView, "WkContentView") orelse
        return error.ClassAllocationFailed;

    // 添加 ivar 存放 Zig Window 指针
    if (!cls.addIvar("_wkWindow")) {
        return error.IvarAddFailed;
    }

    // 注册 NSTextInputClient 协议遵从（IME 所必需）
    const NSTextInputClient = objc.getProtocol("NSTextInputClient") orelse
        return error.ProtocolNotFound;
    if (objc.c.class_addProtocol(cls.value, NSTextInputClient.value) == 0) {
        return error.ProtocolAddFailed;
    }

    // 接收事件所必需
    if (!cls.addMethod("acceptsFirstResponder", acceptsFirstResponder)) return error.MethodAddFailed;
    if (!cls.addMethod("isFlipped", isFlipped)) return error.MethodAddFailed;

    // 文件拖放（NSDraggingDestination）。注册协议和四个 drag 回调；
    // 接受的 pasteboard 类型在每个实例的 `create` 里声明。
    const NSDraggingDestination = objc.getProtocol("NSDraggingDestination") orelse
        return error.ProtocolNotFound;
    if (objc.c.class_addProtocol(cls.value, NSDraggingDestination.value) == 0) {
        return error.ProtocolAddFailed;
    }
    if (!cls.addMethod("draggingEntered:", draggingEntered)) return error.MethodAddFailed;
    if (!cls.addMethod("draggingUpdated:", draggingUpdated)) return error.MethodAddFailed;
    if (!cls.addMethod("draggingExited:", draggingExited)) return error.MethodAddFailed;
    if (!cls.addMethod("prepareForDragOperation:", prepareForDragOperation)) return error.MethodAddFailed;
    if (!cls.addMethod("performDragOperation:", performDragOperation)) return error.MethodAddFailed;

    // 键盘事件
    if (!cls.addMethod("keyDown:", keyDown)) return error.MethodAddFailed;
    if (!cls.addMethod("keyUp:", keyUp)) return error.MethodAddFailed;
    if (!cls.addMethod("flagsChanged:", flagsChanged)) return error.MethodAddFailed;

    // 鼠标事件
    if (!cls.addMethod("mouseDown:", mouseDown)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseUp:", mouseUp)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseMoved:", mouseMoved)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseDragged:", mouseDragged)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseEntered:", mouseEntered)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseExited:", mouseExited)) return error.MethodAddFailed;
    if (!cls.addMethod("rightMouseDown:", rightMouseDown)) return error.MethodAddFailed;
    if (!cls.addMethod("rightMouseUp:", rightMouseUp)) return error.MethodAddFailed;
    if (!cls.addMethod("scrollWheel:", scrollWheel)) return error.MethodAddFailed;

    // NSTextInputClient 协议方法（IME 支持）
    if (!cls.addMethod("hasMarkedText", hasMarkedText)) return error.MethodAddFailed;
    if (!cls.addMethod("markedRange", markedRange)) return error.MethodAddFailed;
    if (!cls.addMethod("selectedRange", selectedRange)) return error.MethodAddFailed;
    if (!cls.addMethod("setMarkedText:selectedRange:replacementRange:", setMarkedText)) return error.MethodAddFailed;
    if (!cls.addMethod("unmarkText", unmarkText)) return error.MethodAddFailed;
    if (!cls.addMethod("validAttributesForMarkedText", validAttributesForMarkedText)) return error.MethodAddFailed;
    if (!cls.addMethod("attributedSubstringForProposedRange:actualRange:", attributedSubstring)) return error.MethodAddFailed;
    if (!cls.addMethod("insertText:replacementRange:", insertText)) return error.MethodAddFailed;
    if (!cls.addMethod("characterIndexForPoint:", characterIndexForPoint)) return error.MethodAddFailed;
    if (!cls.addMethod("firstRectForCharacterRange:actualRange:", firstRectForCharacterRange)) return error.MethodAddFailed;
    if (!cls.addMethod("doCommandBySelector:", doCommandBySelector)) return error.MethodAddFailed;
    if (!cls.addMethod("performKeyEquivalent:", performKeyEquivalent)) return error.MethodAddFailed;

    objc.registerClassPair(cls);
    view_class = cls;
}

/// 创建一个 view 实例
pub fn create(frame: NSRect, window: *Window) !objc.Object {
    if (view_class == null) {
        try registerClass();
    }

    const view = view_class.?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});

    // 把 Zig 窗口指针存进 ivar
    const window_obj = objc.Object.fromId(@as(objc.c.id, @ptrCast(window)));
    view.setInstanceVariable("_wkWindow", window_obj);

    // 声明接受的 pasteboard 类型。只注册文件类类型，AppKit 保证每个
    // drag 回调收到的都是文件拖拽（与 Win32 `RegisterDragDrop` +
    // `CF_HDROP` 检查同一个闸门）。
    if (objc.getClass("NSMutableArray")) |NSMutableArray| {
        if (objc.getClass("NSString")) |NSString| {
            const types = NSMutableArray.msgSend(objc.Object, "arrayWithCapacity:", .{@as(c_ulong, 2)});
            // NSPasteboardTypeFileURL + NSFilenamesPboardType(系统会把
            // Finder 的 modern 拖放改写一份 legacy 类型,双注册最稳)。
            inline for (.{ "public.file-url", "NSFilenamesPboardType" }) |type_name| {
                const type_string = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{type_name});
                _ = types.msgSend(objc.Object, "addObject:", .{type_string});
            }
            view.msgSend(void, "registerForDraggedTypes:", .{types});
        }
    }

    return view;
}

// =============================================================================
// 辅助函数
// =============================================================================

inline fn getWindow(self: objc.c.id) ?*Window {
    const view = objc.Object.fromId(self);
    const ptr = view.getInstanceVariable("_wkWindow");
    return @ptrCast(@alignCast(ptr.value));
}

fn parseModifiers(flags: c_ulong) input.Modifiers {
    const mods = NSEventModifierFlags.from(flags);
    return .{
        .shift = mods.shift,
        .ctrl = mods.control,
        .alt = mods.option,
        .cmd = mods.command,
    };
}

fn parseMouseEvent(self: objc.c.id, event_id: objc.c.id, comptime kind: std.meta.Tag(input.InputEvent)) input.InputEvent {
    const view = objc.Object.fromId(self);
    const event = objc.Object.fromId(event_id);

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) });

    const button: input.MouseButton = switch (event.msgSend(c_long, "buttonNumber", .{})) {
        0 => .left,
        1 => .right,
        else => .middle,
    };

    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const click_count = event.msgSend(c_long, "clickCount", .{});

    return @unionInit(input.InputEvent, @tagName(kind), .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .button = button,
        .click_count = @intCast(@max(0, click_count)),
        .modifiers = parseModifiers(modifier_flags),
    });
}

fn parseEnterExitEvent(self_id: objc.c.id, event_id: objc.c.id) input.MouseEvent {
    const view = objc.Object.fromId(self_id);
    const event = objc.Object.fromId(event_id);

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) });
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    return .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .button = .left,
        .click_count = 0,
        .modifiers = parseModifiers(modifier_flags),
    };
}

/// 从 NSString 或 NSAttributedString 提取 UTF-8 字符串
fn extractString(text_id: objc.c.id) ?[]const u8 {
    const text = objc.Object.fromId(text_id);

    // 判断是否为 NSAttributedString
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return null;
    const is_attributed = text.msgSend(bool, "isKindOfClass:", .{NSAttributedString.value});

    const ns_string = if (is_attributed)
        text.msgSend(objc.Object, "string", .{})
    else
        text;

    const cstr = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(cstr);
}

// =============================================================================
// NSView 方法实现
// =============================================================================

fn acceptsFirstResponder(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn isFlipped(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

// =============================================================================
// 鼠标方法实现
// =============================================================================

fn mouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_down));
}

fn mouseUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_up));
}

fn mouseMoved(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_moved));
}

fn mouseDragged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_dragged));
}

fn mouseEntered(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(.{ .mouse_entered = parseEnterExitEvent(self, event) });
}

fn mouseExited(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(.{ .mouse_exited = parseEnterExitEvent(self, event) });
}

fn rightMouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_down));
}

fn rightMouseUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_up));
}

fn scrollWheel(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const view = objc.Object.fromId(self);
    const event = objc.Object.fromId(event_id);

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) });

    const delta_x = event.msgSend(f64, "scrollingDeltaX", .{});
    const delta_y = event.msgSend(f64, "scrollingDeltaY", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    _ = window.handleInput(.{ .scroll = .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .delta = geometry.Point(f64).init(delta_x, delta_y),
        .modifiers = parseModifiers(modifier_flags),
    } });
}

// =============================================================================
// 文件拖放（NSDraggingDestination）
// =============================================================================
//
// 接受的 pasteboard 类型在每个实例的 `create` 里声明（仅 file URL 类），
// 因此 AppKit 只会把文件拖拽路由到这里 — 与 Windows 后端 `CF_HDROP`
// 过滤等价。`dropped` 事件里的 paths 指向 NSString 的 UTF-8 存储:回调脉内
// 有效(autoreleasepool 在整个 runloop 迭代后才 drain),契约与 Windows 后端
// 一致 —— 回调返回后不再保证有效,需要留存就自己拷贝。

const NSDragOperationNone: c_ulong = 0;
const NSDragOperationCopy: c_ulong = 0x1;

const max_drop_paths: usize = 64;

/// 键盘修饰键从"当前事件"取:dragging 回调的 sender 只有源声明的
/// operation mask,拿不到键盘状态;`currentEvent` 此时正是拖拽手感事件。
fn currentModifiers() input.Modifiers {
    const NSApplication = objc.getClass("NSApplication") orelse return .{};
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    const event = app.msgSend(objc.Object, "currentEvent", .{});
    if (event.value == null) return .{};
    return parseModifiers(event.msgSend(c_ulong, "modifierFlags", .{}));
}

/// draggingLocation(窗口坐标)→ view 坐标,与鼠标事件同一换算。
fn dragPosition(self_id: objc.c.id, dragging_info: objc.Object) geometry.Point(f64) {
    const view = objc.Object.fromId(self_id);
    const window_loc: NSPoint = dragging_info.msgSend(NSPoint, "draggingLocation", .{});
    const view_loc: NSPoint = view.msgSend(
        NSPoint,
        "convertPoint:fromView:",
        .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) },
    );
    return geometry.Point(f64).init(view_loc.x, view_loc.y);
}

fn draggingEntered(self: objc.c.id, _: objc.c.SEL, info: objc.c.id) callconv(.c) c_ulong {
    const window = getWindow(self) orelse return NSDragOperationNone;
    if (!window.file_drop_enabled) return NSDragOperationNone;
    const dragging_info = objc.Object.fromId(info);
    _ = window.handleInput(.{ .file_drop = .{
        .phase = .entered,
        .paths = &.{},
        .position = dragPosition(self, dragging_info),
        .modifiers = currentModifiers(),
    } });
    return NSDragOperationCopy;
}

fn draggingUpdated(self: objc.c.id, _: objc.c.SEL, info: objc.c.id) callconv(.c) c_ulong {
    const window = getWindow(self) orelse return NSDragOperationNone;
    if (!window.file_drop_enabled) return NSDragOperationNone;
    // moved 的高频回调里不碰 currentEvent(节省 msgSend),沿用进入时的
    // 修饰键;修饰键变化会经 flagsChanged 正常流入(on_input)。
    const dragging_info = objc.Object.fromId(info);
    _ = window.handleInput(.{ .file_drop = .{
        .phase = .moved,
        .paths = &.{},
        .position = dragPosition(self, dragging_info),
        .modifiers = currentModifiers(),
    } });
    return NSDragOperationCopy;
}

fn draggingExited(self: objc.c.id, _: objc.c.SEL, info: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const dragging_info = objc.Object.fromId(info);
    _ = window.handleInput(.{ .file_drop = .{
        .phase = .exited,
        .paths = &.{},
        .position = dragPosition(self, dragging_info),
        .modifiers = currentModifiers(),
    } });
}

fn prepareForDragOperation(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) bool {
    return true;
}

fn performDragOperation(self: objc.c.id, _: objc.c.SEL, info: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    if (!window.file_drop_enabled) return false; // 拒绝落下,AppKit 终止拖拽
    const dragging_info = objc.Object.fromId(info);
    const pasteboard = dragging_info.msgSend(objc.Object, "draggingPasteboard", .{});

    // 切片数组放本帧:handleInput → 用户回调同步执行,回调返回前本帧存活
    // (Windows 后端 drop 同一模式 —— 返回栈数组会悬垂,别改回去)。
    var slices: [max_drop_paths][]const u8 = undefined;
    const paths = extractDropPaths(pasteboard, &slices);

    _ = window.handleInput(.{ .file_drop = .{
        .phase = .dropped,
        .paths = paths,
        .position = dragPosition(self, dragging_info),
        .modifiers = currentModifiers(),
    } });
    return true;
}

/// 挑出所有文件路径。首选 `readObjectsForClasses:`(NSPasteboardTypeFileURL
/// → NSURL 数组);老系统 / 特殊源兜底 `propertyListForType:NSFilenamesPboardType`
/// (路径数组)。都失败就返回空 —— AppKit 仍会“接受”这个 drag,但事件里
/// paths 为空,消费方自行忽略。
fn extractDropPaths(
    pasteboard: objc.Object,
    slices: *[max_drop_paths][]const u8,
) []const []const u8 {
    var count: usize = 0;

    // modern 路径：[pasteboard readObjectsForClasses:@[NSURL] options:nil]
    if (objc.getClass("NSURL")) |NSURL| {
        if (objc.getClass("NSMutableArray")) |NSMutableArray| {
            const class_array = NSMutableArray.msgSend(objc.Object, "arrayWithCapacity:", .{@as(c_ulong, 1)});
            _ = class_array.msgSend(objc.Object, "addObject:", .{
                @as(objc.c.id, @ptrCast(NSURL.value)),
            });
            const objects = pasteboard.msgSend(
                objc.Object,
                "readObjectsForClasses:options:",
                .{ class_array, @as(objc.c.id, @ptrFromInt(0)) },
            );
            if (objects.value != null) {
                const total = objects.msgSend(c_ulong, "count", .{});
                for (0..@min(total, max_drop_paths)) |i| {
                    const url = objects.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, @intCast(i))});
                    const path_string = url.msgSend(objc.Object, "path", .{});
                    const utf8 = path_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse continue;
                    slices[count] = std.mem.span(utf8);
                    count += 1;
                }
            }
        }
    }

    // legacy 路径：文件名列表（当目标声明了
    // NSFilenamesPboardType 时，系统会把 Finder 拖拽改写为该类型）。
    if (count == 0) {
        if (objc.getClass("NSString")) |NSString| {
            if (objc.getClass("NSArray")) |NSArray| {
                const type_string = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSFilenamesPboardType"});
                const list = pasteboard.msgSend(objc.Object, "propertyListForType:", .{type_string});
                if (list.value != null and list.msgSend(bool, "isKindOfClass:", .{NSArray.value})) {
                    const total = list.msgSend(c_ulong, "count", .{});
                    for (0..@min(total, max_drop_paths)) |i| {
                        const path_string = list.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, @intCast(i))});
                        const utf8 = path_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse continue;
                        slices[count] = std.mem.span(utf8);
                        count += 1;
                    }
                }
            }
        }
    }

    return slices[0..count];
}

// =============================================================================
// 键盘方法实现
// =============================================================================

fn keyDown(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const view = objc.Object.fromId(self);

    // 先派发 key_down 事件（供快捷键、导航等使用）
    if (parseKeyEvent(event_id)) |key_event| {
        const handled = window.handleInput(.{ .key_down = key_event });

        // 应用已处理则该键不再送入 IME
        if (handled) {
            return;
        }
    }

    // 保存当前事件，供 doCommandBySelector 兜底使用
    window.pending_key_event = event_id;
    defer window.pending_key_event = null;

    // 经 interpretKeyEvents 路由，支持 IME
    const NSArray = objc.getClass("NSArray") orelse return;
    const event_array = NSArray.msgSend(objc.Object, "arrayWithObject:", .{event_id});
    view.msgSend(void, "interpretKeyEvents:", .{event_array.value});
}

fn keyUp(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const event = objc.Object.fromId(event_id);

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});

    // 不去取 characters —— 系统合成事件中它可能无效；
    // 文本输入经 IME 的 insertText: 进入
    _ = window.handleInput(.{ .key_up = .{
        .key = mac_input.keyTagFromVirtualKey(key_code),
        .modifiers = parseModifiers(modifier_flags),
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = is_repeat,
    } });
}

fn flagsChanged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const ns_event = objc.Object.fromId(event);
    const modifier_flags = ns_event.msgSend(c_ulong, "modifierFlags", .{});
    _ = window.handleInput(.{ .modifiers_changed = parseModifiers(modifier_flags) });
}

fn parseKeyEvent(event_id: objc.c.id) ?input.KeyEvent {
    const event = objc.Object.fromId(event_id);

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});

    const characters = getCharacters(event);
    const characters_unmod = getCharactersIgnoringModifiers(event);

    return .{
        .key = mac_input.keyTagFromVirtualKey(key_code),
        .modifiers = parseModifiers(modifier_flags),
        .characters = characters,
        .characters_ignoring_modifiers = characters_unmod,
        .is_repeat = is_repeat,
    };
}

fn getCharacters(event: objc.Object) ?[]const u8 {
    // 直接拿裸 id 并显式判 nil —— ?objc.Object 对 nil 的处理不正确
    const ns_string_id: objc.c.id = event.msgSend(objc.c.id, "characters", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object.fromId(ns_string_id);
    // 先查 length —— 对空串/特殊字符串调 UTF8String 可能出问题
    const length: c_ulong = ns_string.msgSend(c_ulong, "length", .{});
    if (length == 0) return null;

    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    return std.mem.span(cstr.?);
}

fn getCharactersIgnoringModifiers(event: objc.Object) ?[]const u8 {
    // 直接拿裸 id 并显式判 nil —— ?objc.Object 对 nil 的处理不正确
    const ns_string_id: objc.c.id = event.msgSend(objc.c.id, "charactersIgnoringModifiers", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object.fromId(ns_string_id);
    // 先查 length —— 对空串/特殊字符串调 UTF8String 可能出问题
    const length: c_ulong = ns_string.msgSend(c_ulong, "length", .{});
    if (length == 0) return null;

    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    return std.mem.span(cstr.?);
}

// =============================================================================
// NSTextInputClient 协议实现
// =============================================================================

fn hasMarkedText(self: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    return window.marked_text.len > 0;
}

fn markedRange(self: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    const window = getWindow(self) orelse return NSRange.invalid();
    if (window.marked_text.len > 0) {
        return .{ .location = 0, .length = window.marked_text.len };
    }
    return NSRange.invalid();
}

fn selectedRange(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    // 目前返回位置 0 处的空选区；
    // 完整实现应查询持有焦点的文本元素
    return .{ .location = 0, .length = 0 };
}

fn performKeyEquivalent(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    const event = objc.Object.fromId(event_id);

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const mods = parseModifiers(modifier_flags);

    // 只处理带 command 修饰键的事件（key equivalent）
    if (mods.cmd) {
        const key_event = input.KeyEvent{
            .key = mac_input.keyTagFromVirtualKey(key_code),
            .modifiers = mods,
            .characters = null, // key equivalent 场景取 characters 可能崩溃
            .characters_ignoring_modifiers = null,
            .is_repeat = false,
        };

        // 送给输入处理；返回 true 表示已处理
        if (window.handleInput(.{ .key_down = key_event })) {
            return true;
        }
    }

    // 返回 false，未处理的 key equivalent 交给系统
    return false;
}

fn setMarkedText(
    self: objc.c.id,
    _: objc.c.SEL,
    text_id: objc.c.id,
    _: NSRange,
    _: NSRange,
) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const str = extractString(text_id) orelse "";

    std.debug.print("setMarkedText: \"{s}\"\n", .{str});

    window.setMarkedText(str);
    _ = window.handleInput(.{ .composition = .{ .text = window.marked_text } });
}

fn unmarkText(self: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.clearMarkedText();

    // 发送空 composition 表示合成结束
    _ = window.handleInput(.{ .composition = .{
        .text = "",
    } });
}

fn validAttributesForMarkedText(_: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    // 返回空数组 —— 不支持带样式的 marked text
    const NSArray = objc.getClass("NSArray") orelse return null;
    return NSArray.msgSend(objc.c.id, "array", .{});
}

fn attributedSubstring(
    _: objc.c.id,
    _: objc.c.SEL,
    _: NSRange, // range
    _: *NSRange, // actual_range
) callconv(.c) objc.c.id {
    // 返回 nil —— 暂不支持该查询
    return null;
}

fn insertText(
    self: objc.c.id,
    _: objc.c.SEL,
    text_id: objc.c.id,
    _: NSRange,
) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const str = extractString(text_id) orelse return;

    std.debug.print("insertText: \"{s}\"\n", .{str});

    // 拷贝进窗口自有的缓冲区，在 objc 调用返回前完成
    window.setInsertedText(str);
    window.clearMarkedText();
    _ = window.handleInput(.{ .text_input = .{ .text = window.inserted_text } });
}

fn characterIndexForPoint(_: objc.c.id, _: objc.c.SEL, _: NSPoint) callconv(.c) c_ulong {
    // 返回 0 —— 暂不支持 IME 候选窗的点击定位
    return 0;
}

fn firstRectForCharacterRange(
    self: objc.c.id,
    _: objc.c.SEL,
    _: NSRange, // range
    _: *NSRange, // actual_range
) callconv(.c) NSRect {
    const view = objc.Object.fromId(self);
    const window = getWindow(self) orelse {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    };

    // 取 view 所属的 NSWindow。
    // Zig 0.16：C 调用约定的返回类型不允许 ？objc.Object；
    // 用 objc.c.id（即 [*c]T，天然可空）并手动判空。
    const ns_window_id: objc.c.id = view.msgSend(objc.c.id, "window", .{});
    if (ns_window_id == null) {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    }
    const ns_window = objc.Object.fromId(ns_window_id);

    // 使用持有焦点的 TextInput 设置的 IME 光标矩形
    const view_rect = window.ime_cursor_rect;

    // view 坐标 → 窗口坐标 → 屏幕坐标
    const window_rect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(objc.c.id, @ptrFromInt(0)) });
    const screen_rect = ns_window.msgSend(NSRect, "convertRectToScreen:", .{window_rect});

    return screen_rect;
}

fn doCommandBySelector(self: objc.c.id, _: objc.c.SEL, selector: objc.c.SEL) callconv(.c) void {
    std.debug.print("doCommandBySelector called: {*}\n", .{selector});

    const window = getWindow(self) orelse return;

    if (window.pending_key_event) |event_id| {
        if (parseKeyEvent(event_id)) |key_event| {
            _ = window.handleInput(.{ .key_down = key_event });
        }
    }
}
