//! WindowId 与 WindowRegistry — 跨窗口引用的追踪机制。
//!
//! 提供：
//! - `WindowId`：窗口唯一标识（enum(u32)，天然类型安全）
//! - `WindowRegistry`：按 ID 追踪窗口的中央注册表
//!
//! ## 设计理由
//!
//! 用 `WindowId` 而不是裸指针：
//! - 类型安全：不会把错的指针类型传进来
//! - 稳定：窗口在内存里挪了，ID 也不变
//! - 可校验：解引用前先判断 ID 是否有效
//! - 跨平台：所有后端用同一个 ID 类型
//!
//! ## 用法
//!
//! ```zig
//! var registry = WindowRegistry.init(allocator);
//! defer registry.deinit();
//!
//! const id = registry.register(window);
//! const maybe_window = registry.get(id);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// WindowId
// =============================================================================

/// 窗口的唯一标识。
///
/// 用 enum(u32) 保证类型安全——不会和其他 ID 弄混。
/// `.invalid` 哨兵恒为 0，空值判断显式化。
pub const WindowId = enum(u32) {
    /// 哨兵值：无窗口 / 无效 ID
    invalid = 0,
    /// 其余任意 u32 值都可作为合法 ID
    _,

    /// 判断该 ID 是否对应一个有效窗口。
    pub fn isValid(self: WindowId) bool {
        return self != .invalid;
    }

    /// 取原始数值（调试/日志用）。
    pub fn raw(self: WindowId) u32 {
        return @backingInt(self);
    }

    /// 从原始数值构造 WindowId。
    /// 断言不允许传入 invalid 哨兵。
    pub fn fromRaw(value: u32) WindowId {
        std.debug.assert(value != 0); // fromRaw 不能造出无效 ID
        return @fromBackingInt(@intCast(value));
    }
};

// =============================================================================
// WindowRegistry
// =============================================================================

/// 按 ID 追踪窗口的中央注册表。
///
/// 按 ID O(1) 查找窗口，并记录当前激活窗口。
/// 线程安全：本注册表**不**线程安全，所有访问都必须在主线程
/// （即做窗口操作的地方）进行。
pub const WindowRegistry = struct {
    /// 内部数据结构用的分配器
    allocator: Allocator,

    /// WindowId → 窗口指针（存成 opaque，避免绑死某个平台类型）
    windows: std.AutoHashMap(WindowId, *anyopaque),

    /// 下一个要分配的 ID（单调递增）
    next_id: u32 = 1,

    /// 当前聚焦/激活的窗口（无则 null）
    active_window: ?WindowId = null,

    /// 允许的窗口数量上限。
    pub const MAX_WINDOWS: u32 = 32;

    const Self = @This();

    // =========================================================================
    // 生命周期
    // =========================================================================

    /// 初始化新的 WindowRegistry。
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .windows = std.AutoHashMap(WindowId, *anyopaque).init(allocator),
        };
    }

    /// 清理注册表自己的资源。
    /// 注意：**不会**销毁窗口本身，那是调用方的责任。
    pub fn deinit(self: *Self) void {
        // 断言：校验状态
        std.debug.assert(self.next_id >= 1); // next_id 不能回绕到 0

        self.windows.deinit();
        self.* = undefined;
    }

    // =========================================================================
    // 注册
    // =========================================================================

    /// 注册窗口并返回分配的 ID。
    ///
    /// 窗口指针存成 opaque，避免注册表依赖具体的 Window 类型
    /// （这样是跨平台可用的）。
    pub fn register(self: *Self, window_ptr: *anyopaque) !WindowId {
        // 断言：校验输入与上限
        std.debug.assert(@intFromPtr(window_ptr) != 0);
        std.debug.assert(self.windows.count() < MAX_WINDOWS); // 硬上限

        // 造下一个 ID
        const id: WindowId = @fromBackingInt(@intCast(self.next_id));
        std.debug.assert(id.isValid()); // 抽查一下

        self.next_id += 1;

        // 防回绕（要创建几十亿个窗口才会触发）
        if (self.next_id == 0) {
            self.next_id = 1; // 跳过 invalid 哨兵
        }

        // 存入注册表
        try self.windows.put(id, window_ptr);

        // 注册**不**顺带选中激活窗口。
        //
        // 曾在这里自动激活第一个注册的窗口，使焦点策略变成注册的
        // 隐式副作用：Linux 的 `Window.init` 额外显式发布焦点，导致
        // 各后端对 `getActiveWindowId` 的答案不一致。现在各后端自己调
        // `setActiveWindowId`，策略每个后端各有一行可读代码，
        // 注册表保持纯映射。

        return id;
    }

    /// 按 ID 注销窗口。
    /// 找到则返回窗口指针，否则返回 null。
    pub fn unregister(self: *Self, id: WindowId) ?*anyopaque {
        // 断言：校验输入
        std.debug.assert(id.isValid());

        const result = self.windows.fetchRemove(id);

        // 注销的是激活窗口就清掉
        if (self.active_window) |active| {
            if (active == id) {
                self.active_window = null;
            }
        }

        if (result) |kv| {
            return kv.value;
        }
        return null;
    }

    // =========================================================================
    // 查找
    // =========================================================================

    /// 按 ID 取窗口指针。
    /// ID 无效或未注册则返回 null。
    pub fn get(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        return self.windows.get(id);
    }

    /// 按 ID 取带类型的窗口指针。
    /// 便捷方法：把 opaque 指针转回期望类型。
    pub fn getTyped(self: *const Self, comptime T: type, id: WindowId) ?*T {
        // 断言：T 必须是指针兼容类型
        comptime std.debug.assert(@sizeOf(T) > 0);

        if (self.get(id)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    /// 判断某 ID 是否已注册。
    pub fn contains(self: *const Self, id: WindowId) bool {
        if (!id.isValid()) return false;
        return self.windows.contains(id);
    }

    // =========================================================================
    // 激活窗口
    // =========================================================================

    /// 设置当前激活/聚焦的窗口。
    pub fn setActiveWindow(self: *Self, id: ?WindowId) void {
        // 断言：给了 id 就必须有效且已注册
        if (id) |window_id| {
            std.debug.assert(window_id.isValid());
            std.debug.assert(self.contains(window_id));
        }
        self.active_window = id;
    }

    /// 取当前激活窗口的 ID。
    pub fn getActiveWindow(self: *const Self) ?WindowId {
        return self.active_window;
    }

    /// 取当前激活窗口指针（带类型）。
    pub fn getActiveWindowTyped(self: *const Self, comptime T: type) ?*T {
        if (self.active_window) |id| {
            return self.getTyped(T, id);
        }
        return null;
    }

    // =========================================================================
    // 迭代
    // =========================================================================

    /// 已注册窗口数量。
    pub fn count(self: *const Self) u32 {
        return @intCast(self.windows.count());
    }

    /// 迭代所有已注册的窗口 ID。
    pub fn iterator(self: *const Self) std.AutoHashMap(WindowId, *anyopaque).KeyIterator {
        return self.windows.keyIterator();
    }
};

// =============================================================================
// 测试
// =============================================================================

test "WindowId - basic operations" {
    const invalid = WindowId.invalid;
    std.debug.assert(!invalid.isValid());
    std.debug.assert(invalid.raw() == 0);

    const valid = WindowId.fromRaw(42);
    std.debug.assert(valid.isValid());
    std.debug.assert(valid.raw() == 42);
}

test "WindowRegistry - register and lookup" {
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy1: u32 = 1;
    var dummy2: u32 = 2;

    const id1 = try registry.register(&dummy1);
    const id2 = try registry.register(&dummy2);

    // 断言：ID 应唯一且有效
    std.debug.assert(id1.isValid());
    std.debug.assert(id2.isValid());
    std.debug.assert(id1 != id2);

    // 查找应返回正确的指针
    const ptr1 = registry.getTyped(u32, id1);
    const ptr2 = registry.getTyped(u32, id2);

    std.debug.assert(ptr1 != null);
    std.debug.assert(ptr2 != null);
    std.debug.assert(ptr1.?.* == 1);
    std.debug.assert(ptr2.?.* == 2);
}

test "WindowRegistry - unregister" {
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy: u32 = 42;
    const id = try registry.register(&dummy);

    std.debug.assert(registry.contains(id));
    std.debug.assert(registry.count() == 1);

    _ = registry.unregister(id);

    std.debug.assert(!registry.contains(id));
    std.debug.assert(registry.count() == 0);
    std.debug.assert(registry.get(id) == null);
}

test "WindowRegistry - registration does not elect active window" {
    // 焦点策略归后端管，不该归注册管。在这里选中会让注册悄悄改变
    // 焦点，三个后端还会对"哪个窗口激活"答案不一。注册必须不动
    // 激活槽。
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy1: u32 = 1;
    var dummy2: u32 = 2;

    const id1 = try registry.register(&dummy1);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());

    const id2 = try registry.register(&dummy2);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());

    // 只有显式调用才选中。
    registry.setActiveWindow(id1);
    try std.testing.expectEqual(id1, registry.getActiveWindow().?);

    registry.setActiveWindow(id2);
    try std.testing.expectEqual(id2, registry.getActiveWindow().?);
}

test "WindowRegistry - unregister active window clears slot" {
    // 反例：过期的激活 ID 必须不比窗口活得久，否则后续查找会把焦点
    // 解析到已释放的指针上。
    var registry = WindowRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dummy: u32 = 7;
    const id = try registry.register(&dummy);
    registry.setActiveWindow(id);
    try std.testing.expectEqual(id, registry.getActiveWindow().?);

    _ = registry.unregister(id);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());

    // 空状态下显式清空也是合法的。
    registry.setActiveWindow(null);
    try std.testing.expectEqual(@as(?WindowId, null), registry.getActiveWindow());
}

test "WindowRegistry - count limit constant" {
    // 校验 MAX_WINDOWS 是个合理上限
    std.debug.assert(WindowRegistry.MAX_WINDOWS >= 1);
    std.debug.assert(WindowRegistry.MAX_WINDOWS <= 256);
}
