//! windowkit WASM 入口（freestanding wasm32 根模块）。
//!
//! 示例以子模块 `application` 的形式导入，这样它自己的 `main` 不会让
//! Zig 为 freestanding 目标合成 `std.start`。JS 侧调用导出的
//! `init` / `frame` / `resize`。

const application = @import("application");

pub const std_options = application.std_options;

comptime {
    _ = application.wasm_app;
}
