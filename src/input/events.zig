const geometry = @import("../geometry.zig");

/// 与平台无关的按键标识（key tag）。
///
/// 只描述"按下了哪个键"，按 US ANSI 物理位置命名，不含任何平台的
/// 原始键码。各平台后端负责把本机的 scancode / VK / evdev / DOM code
/// 翻译成这里的名字（见 `platform/<os>/input.zig`）。
///
/// 消费方直接按名字判断即可，例如 `if (key == .escape) win.close();`，
/// 完全不需要关心底层触发的是哪个 code。
pub const KeyTag = enum {
    // 字母
    a,
    s,
    d,
    f,
    h,
    g,
    z,
    x,
    c,
    v,
    b,
    q,
    w,
    e,
    r,
    y,
    t,
    o,
    u,
    i,
    p,
    l,
    j,
    k,
    n,
    m,

    // 数字
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    @"0",

    // 标点。按物理位置（US ANSI 布局）命名；在其他布局上该位置的
    // 物理键可能打出不同字符，所以关心"打到什么字符"的消费方应使用
    // 事件里的 `characters_ignoring_modifiers`，别用这些名字。
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    quote,
    comma,
    period,
    slash,
    grave,

    // 特殊键
    @"return",
    tab,
    space,
    delete,
    escape,
    forward_delete,

    // 小键盘。与主键区数字行区分开，方便终端模拟器和游戏支持应用
    // 键盘模式（DECKPAM）。
    keypad_0,
    keypad_1,
    keypad_2,
    keypad_3,
    keypad_4,
    keypad_5,
    keypad_6,
    keypad_7,
    keypad_8,
    keypad_9,
    keypad_decimal,
    keypad_multiply,
    keypad_plus,
    keypad_clear, // PC 键盘上对应 NumLock 位置
    keypad_divide,
    keypad_enter,
    keypad_minus,
    keypad_equals,

    // 修饰键
    command,
    shift,
    caps_lock,
    option,
    control,
    right_command,
    right_shift,
    right_option,
    right_control,

    // 方向键
    left,
    right,
    down,
    up,

    // 功能键
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,

    // 光标/导航键
    home,
    end,
    page_up,
    page_down,

    /// 后端无法识别的键。
    unknown,
};

pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _pad: u4 = 0,
};

pub const MouseEvent = struct {
    position: geometry.Point(f64),
    button: MouseButton,
    click_count: u32,
    modifiers: Modifiers,
};

pub const ScrollEvent = struct {
    position: geometry.Point(f64),
    delta: geometry.Point(f64),
    modifiers: Modifiers,
};

pub const KeyEvent = struct {
    key: KeyTag,
    modifiers: Modifiers,
    /// 该按键事件产生的文本（UTF-8）。
    /// 不可打印键时可能为空。
    characters: ?[]const u8,
    /// 不含修饰键影响的字符（给快捷键判断用）
    characters_ignoring_modifiers: ?[]const u8,
    /// 是否为长按重复
    is_repeat: bool,
};

/// 经 IME 插入的文本。
/// 覆盖表情选择器、死键、中日韩输入、听写等。
pub const TextInputEvent = struct {
    /// 插入的文本（UTF-8）
    text: []const u8,
};

/// IME 组合（preedit）状态变化
pub const CompositionEvent = struct {
    /// 组合中的文本（UTF-8），组合结束时为空
    text: []const u8,
};

/// 触屏/触控板上的一个触点
pub const TouchEvent = struct {
    position: geometry.Point(f64),
    /// 触点标识；同一次手势内正在触摸的每个触点各不相同。
    id: i32,
};

/// 文件拖放的阶段。
///
/// 生命周期:`entered → moved* → (dropped | exited)`。`moved` 的频率与
/// `mouse_moved` 同量级,只在文件悬停期间发生。
pub const FileDropPhase = enum {
    /// 文件拖进窗口上方(可在此高亮放置区)。
    entered,
    /// 拖着文件在窗口上移动。
    moved,
    /// 文件拖出窗口 / 拖放被取消。
    exited,
    /// 文件已放下 —— 只有这个阶段带 `paths`。
    dropped,
};

/// 文件从系统文件管理器拖到窗口上(资源管理器 / Finder)。
///
/// 与文件对话框的区别:这是**被动接收的事件**(OS 推给窗口),
/// 不是应用发起的模态 UI,所以它属于窗口库;模态弹窗不属于。
pub const FileDropEvent = struct {
    phase: FileDropPhase,
    /// 放下的文件路径(UTF-8,绝对路径)。仅 `dropped` 阶段非空。
    ///
    /// 生命周期:**只在回调期间有效** —— 后端在派发后立即释放。
    /// 要留到后面用就自己拷贝(或用 allocator 复制)。
    paths: []const []const u8,
    /// 光标位置(客户区,逻辑像素)。
    position: geometry.Point(f64),
    modifiers: Modifiers,
};

pub const InputEvent = union(enum) {
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_moved: MouseEvent,
    mouse_dragged: MouseEvent,
    mouse_entered: MouseEvent,
    mouse_exited: MouseEvent,
    scroll: ScrollEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    modifiers_changed: Modifiers,
    /// IME 提交后的最终文本
    text_input: TextInputEvent,
    /// IME 组合状态变化（preedit 文本）
    composition: CompositionEvent,
    touch_down: TouchEvent,
    touch_up: TouchEvent,
    touch_moved: TouchEvent,
    /// 合成器把表面上的所有触点取消了。
    touch_cancelled,
    /// 系统文件管理器拖入的文件（见 `FileDropPhase`）。
    /// `capabilities.file_drop` 决定后端是否发这个事件。
    file_drop: FileDropEvent,
};
