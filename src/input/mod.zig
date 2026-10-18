//! 输入系统
//!
//! 输入事件、键码与按键绑定。
//!
//! - `events` - 输入事件原语：InputEvent、KeyEvent、MouseEvent、KeyTag、Modifiers
//! - `actions` - 声明式按键绑定：Keymap、Keystroke、KeyBinding

const std = @import("std");

// =============================================================================
// 事件（输入原语）
// =============================================================================

pub const events = @import("events.zig");

pub const InputEvent = events.InputEvent;
pub const MouseEvent = events.MouseEvent;
pub const MouseButton = events.MouseButton;
pub const ScrollEvent = events.ScrollEvent;
pub const KeyEvent = events.KeyEvent;
pub const KeyTag = events.KeyTag;
pub const Modifiers = events.Modifiers;
pub const TextInputEvent = events.TextInputEvent;
pub const CompositionEvent = events.CompositionEvent;
pub const FileDropEvent = events.FileDropEvent;
pub const FileDropPhase = events.FileDropPhase;

// =============================================================================
// Action（按键绑定系统）
// =============================================================================

pub const actions = @import("actions.zig");

pub const Keymap = actions.Keymap;
pub const Keystroke = actions.Keystroke;
pub const KeyBinding = actions.KeyBinding;
pub const ActionTypeId = actions.ActionTypeId;
pub const actionTypeId = actions.actionTypeId;

// =============================================================================
// 事件传播（capture/bubble 阶段）
// =============================================================================

pub const event = @import("event.zig");
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;

// =============================================================================
// 测试
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
