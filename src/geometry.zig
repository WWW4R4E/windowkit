//! 窗口库自己的几何/颜色词汇表。
//!
//! 只放事件与窗口 API 会说出口的东西:位置(Point)、尺寸(Size)、
//! 矩形(Rect)、颜色(Color)。**刻意没有** GPU 布局类型(f32/Metal
//! 对齐的顶点结构)、Edges/Corners 这类 UI 布局词汇——渲染和数据布局
//! 归消费方(引擎自助),窗口库不替渲染器定 ABI。
//!
//! 库内消费方式几乎全是字段与构造(init/rgba/...);方法只留最基础的
//! 几何读数,不往布局/变换方向长。

const std = @import("std");

// =============================================================================
// Point
// =============================================================================

/// 2D 点(客户区/事件坐标,逻辑像素)。
pub fn Point(comptime T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,

        const Self = @This();

        pub fn init(x_val: T, y_val: T) Self {
            return .{ .x = x_val, .y = y_val };
        }
    };
}

// =============================================================================
// Size
// =============================================================================

/// 2D 尺寸(逻辑像素;物理像素乘 `scale_factor`,或直接用
/// `framebufferSize()`)。
pub fn Size(comptime T: type) type {
    return struct {
        width: T = 0,
        height: T = 0,

        const Self = @This();

        pub fn init(w: T, h: T) Self {
            return .{ .width = w, .height = h };
        }
    };
}

// =============================================================================
// Rect
// =============================================================================

/// 原点 + 尺寸的矩形。窗口库内只用于 IME 候选窗定位这类需要"一块区域"
/// 的场景;更复杂的几何运算归消费方。
pub fn Rect(comptime T: type) type {
    return struct {
        origin: Point(T) = .{},
        size: Size(T) = .{},

        const Self = @This();

        pub fn init(x: T, y: T, w: T, h: T) Self {
            return .{
                .origin = .{ .x = x, .y = y },
                .size = .{ .width = w, .height = h },
            };
        }

        pub fn containsPoint(self: Self, x: T, y: T) bool {
            return x >= self.origin.x and
                x < self.origin.x + self.size.width and
                y >= self.origin.y and
                y < self.origin.y + self.size.height;
        }

        pub fn left(self: Self) T {
            return self.origin.x;
        }
        pub fn top(self: Self) T {
            return self.origin.y;
        }
        pub fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }
        pub fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }
    };
}

// =============================================================================
// Color
// =============================================================================

/// RGBA 颜色(线性 [0,1] 分量)。窗口 API 的颜色入口只有背景/清屏,
/// 不指示渲染器如何解释颜色空间(见消费方与 swapchain 的约定)。
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        std.debug.assert(r >= 0.0 and r <= 1.0);
        std.debug.assert(g >= 0.0 and g <= 1.0);
        std.debug.assert(b >= 0.0 and b <= 1.0);
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        std.debug.assert(r >= 0.0 and r <= 1.0);
        std.debug.assert(g >= 0.0 and g <= 1.0);
        std.debug.assert(b >= 0.0 and b <= 1.0);
        std.debug.assert(a >= 0.0 and a <= 1.0);
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = 1,
        };
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        std.debug.assert(a >= 0.0 and a <= 1.0);
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    /// 颜色分量转数组 [r, g, b, a]。
    pub fn toRgba(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
};

// =============================================================================
// 具名别名（库内实际用到的实例化）
// =============================================================================

/// 逻辑像素别名（Linux IME 候选窗矩形用 f32）。
pub const Pixels = f32;

pub const RectF = Rect(Pixels);

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Point/Size/Rect basics" {
    const p = Point(f64).init(1.5, 2.5);
    try testing.expectEqual(@as(f64, 1.5), p.x);
    const s = Size(f64).init(800, 600);
    try testing.expectEqual(@as(f64, 600), s.height);
    const r = Rect(f32).init(10, 20, 30, 40);
    try testing.expect(r.containsPoint(10, 20));
    try testing.expect(!r.containsPoint(40, 20));
    try testing.expectEqual(@as(f32, 40), r.right());
    try testing.expectEqual(@as(f32, 60), r.bottom());
}

test "Color constructors and components" {
    const c = Color.rgba(0.1, 0.2, 0.3, 0.4);
    try testing.expectEqual(@as(@TypeOf(c.a), 0.4), c.a);
    const c8 = Color.rgb8(255, 128, 0);
    try testing.expectEqual(@as(f32, 1.0), c8.r);
    try testing.expectEqual(@as(f32, 0.0), c8.b);
    try testing.expectEqual(@as(f32, 0.0), Color.transparent.a);
}
