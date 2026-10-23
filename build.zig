//! windowkit 构建脚本。
//!
//! 步骤：
//! - `zig build`            构建当前目标的原生 demo（Linux/macOS）
//! - `zig build run`        运行原生 demo
//! - `zig build test`       跑单元测试
//! - `zig build typecheck-macos`  从任意主机交叉分析 macOS 后端（只出目标文件，不链接）
//!
//! 系统依赖只有窗口本身需要的：Linux 是 `wayland-client` + libc（所有绑定都是
//! 手写 extern，不需要 wayland 头文件）；macOS 是 objc 运行时 + AppKit 系框架；
//! Windows 零依赖（`extern "user32" fn` 带 DLL 名，Zig 链接器自动带上对应的
//! import 库，不需要 MinGW/MSVC SDK）。
//! 渲染相关的 vulkan / Metal / freetype 一概不链接。
//!
//! 各平台分支：
//! - `zig build` / `zig build run`     原生 demo（目标机上是 Windows 就出 Win32 窗口）
//! - `zig build test`                  单元测试
//! - `zig build typecheck-macos`       从任意主机交叉分析 macOS 后端（只出目标文件）
//! - `zig build typecheck-windows`     从任意主机交叉分析 Windows 后端（只出目标文件）

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // 原生 demo
    // =========================================================================

    const native = createWindowkit(b, target, optimize, .{ .register = true });

    const exe = b.addExecutable(.{
        .name = "windowkit-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "windowkit", .module = native.wk }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the native demo");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // 单元测试（纯 std：契约类型、图集、事件、桩渲染器）
    // =========================================================================

    const tests = b.addTest(.{ .root_module = native.wk });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // =========================================================================
    // macOS 交叉分析：只 emit object，不进链接器，所以本机没有 macOS SDK 也行
    // =========================================================================

    const macos_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const macos = createWindowkit(b, macos_target, optimize, .{ .link = false });
    const macos_obj = b.addObject(.{
        .name = "typecheck-macos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/demo.zig"),
            .target = macos_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "windowkit", .module = macos.wk }},
        }),
    });
    const macos_step = b.step(
        "typecheck-macos",
        "Analyze the macOS backend from any host (object only, no linking)",
    );
    macos_step.dependOn(&macos_obj.step);

    // =========================================================================
    // Windows 交叉分析：只 emit object，不进链接器，从 macOS/Linux 主机也能
    // 分析 Win32 后端（本机有 Windows 时直接 `zig build` 就覆盖了）
    // =========================================================================

    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows });
    const windows = createWindowkit(b, windows_target, optimize, .{ .link = false });
    const windows_obj = b.addObject(.{
        .name = "typecheck-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/demo.zig"),
            .target = windows_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "windowkit", .module = windows.wk }},
        }),
    });
    const windows_step = b.step(
        "typecheck-windows",
        "Analyze the Windows backend from any host (object only, no linking)",
    );
    windows_step.dependOn(&windows_obj.step);

}

// =============================================================================
// 目标相关的模块组装
// =============================================================================

const CreateOptions = struct {
    /// 以 `windowkit` 之名注册成包模块，供 `b.dependency` 的下游导入。
    register: bool = false,

    /// 附加系统库/框架（wayland-client、objc、AppKit …）。
    ///
    /// 只在最终要**链接**的步骤上开：框架查找发生在链接期，交叉分析
    /// （`typecheck-macos` 出 object、不进链接器）必须关掉，否则本机没有
    /// macOS SDK 就会报 `unable to find system framework "AppKit"`。
    link: bool = true,
};

const Modules = struct {
    wk: *std.Build.Module,
};

/// 按目标组装 `windowkit` 模块：macOS 挂 objc 模块与框架，Linux 挂 wayland。
fn createWindowkit(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: CreateOptions,
) Modules {
    const root_source = b.path("src/root.zig");
    const wk = if (options.register)
        b.addModule("windowkit", .{
            .root_source_file = root_source,
            .target = target,
            .optimize = optimize,
        })
    else
        b.createModule(.{
            .root_source_file = root_source,
            .target = target,
            .optimize = optimize,
        });

    switch (target.result.os.tag) {
        .macos => {
            // 手写 extern 的 ObjC 运行时封装（不需要 Apple SDK 头文件）。
            const objc_mod = b.createModule(.{
                .root_source_file = b.path("src/platform/macos/objc/main.zig"),
                .target = target,
                .optimize = optimize,
            });
            if (options.link) {
                objc_mod.linkSystemLibrary("objc", .{});
                objc_mod.linkFramework("Foundation", .{});
                linkMacosFrameworks(wk);
            }
            wk.addImport("objc", objc_mod);
        },
        .linux => if (options.link) linkLinux(wk),
        .windows => {
            // 零额外链接步骤：绑定是 `extern "user32" / kernel32 / dwmapi /`
            // `imm32 / ole32 / shell32 / gdi32`，带 DLL 名的 extern 由 Zig
            // 链接器自动挂上对应 import 库（system libs），不走本机 SDK。
            // macOS 上交叉出 Windows object 也一样，不需要 MinGW/MSVC。
        },
        else => {},
    }

    return .{ .wk = wk };
}

/// 窗口层用到的 macOS 框架。
///
/// 没有 Metal / CoreText：渲染没搬过来（`metal/metal.zig` 是桩）。QuartzCore
/// 留着是因为 `window.zig` 创建 `CAMetalLayer`，CoreVideo 是 `display_link.zig`。
fn linkMacosFrameworks(mod: *std.Build.Module) void {
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.link_libc = true;
}

/// 窗口层用到的 Linux 库：wayland 绑定全是手写 extern，不需要协议头文件。
fn linkLinux(mod: *std.Build.Module) void {
    mod.linkSystemLibrary("wayland-client", .{});
    mod.link_libc = true;
}
