//! 事件传播原语。
//!
//! `EventPhase` / `EventResult` 描述事件如何穿过分发树
//! （见 `context/dispatch.zig`）：
//! 1. capture：根 → 目标，自上而下
//! 2. target：事件已到达目标节点
//! 3. bubble：目标 → 根，自下而上
//!
//! 与 DOM 事件模型同构：父节点可以在 capture 阶段先拦下事件，
//! 也可以在 bubble 阶段处理子节点没消费掉的事件。

/// 事件处理结果
pub const EventResult = enum {
    /// 未处理，继续传播
    ignored,
    /// 已处理，但允许继续传播
    handled,
    /// 已处理，终止所有传播
    stop,
};

/// 事件传播所处阶段
pub const EventPhase = enum {
    /// 事件从根向目标下行中
    capture,
    /// 事件已到达目标节点
    target,
    /// 事件从目标向根上行中
    bubble,
};
