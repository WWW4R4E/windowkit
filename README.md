# windowkit

GLFW 式的 **Zig 纯窗口库**：三个平台的窗口创建 + 事件循环 + 输入/IME/DPI + 文件拖放 + vsync 帧节拍。
**不包含渲染**——Vulkan / Metal 归消费方，windowkit 只把窗口发出去的
事件和原生对象交给你：帧回调、原生句柄、物理像素尺寸。

| 平台 | 后端 | 来源 | 说明 |
|---|---|---|---|
| Linux | Wayland（xdg-shell / decoration / viewporter / text-input-v3） | `src/platform/linux/` | `pump()`/`waitEvent()` 泵 poll/dispatch |
| macOS | AppKit（NSWindow + NSView/NSTextInputClient + delegate + 玻璃效果 + CVDisplayLink） | `src/platform/macos/` | `pump()`/`waitEvent()` 泵 NSApp 事件 |
| Windows | Win32（WNDCLASSEXW + PerMonitorV2 DPI + DWM 玻璃 + `DwmFlush` vsync + OLE `IDropTarget`） | `src/platform/windows/` | `pump()`/`waitEvent()` 泵 `PeekMessage` |

## 构建

需要 **Zig 0.17**。

```sh
cd windowkit
zig build run          # 跑起来：Esc/关闭按钮退出，打印 handles 与 framebuffer 尺寸
zig build test         # 单元测试
zig build typecheck-macos   # 从任意主机交叉分析 macOS 后端（只出 object，不链接 framework）
zig build typecheck-windows # 从任意主机交叉分析 Windows 后端（只出 object，不链接）
```

Linux 只需要 `wayland-client` + libc（协议绑定全是手写 extern，不需要 wayland 头文件）。
macOS 需要 objc 运行时 + AppKit / Foundation / CoreFoundation / CoreGraphics / QuartzCore / CoreVideo。
Windows **零额外依赖**：`extern "user32" fn` 带 DLL 名，Zig 链接器自动挂对应 import 库，
不需要 MinGW/MSVC SDK，也不需要 Windows SDK 头文件。

## 用法

回调用糖（最短路径，适合独立小应用）：

```zig
const windowkit = @import("windowkit");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var plat: windowkit.Platform = undefined;   // 地址必须稳定，栈上原地初始化
    try plat.initInPlace(gpa.allocator());
    defer plat.deinit();

    const win = try windowkit.PlatformWindow.init(gpa.allocator(), &plat, &.{
        .title = "Hello",
        .width = 800,
        .height = 600,
        .file_drop = true, // 不收拖放就填 false,运行期用 setFileDropEnabled 切
    });
    defer win.deinit();

    win.setInputCallback(onInput);
    win.setRenderCallback(onFrame);             // 每帧节拍，见下
    plat.run();                                 // 阻塞到所有窗口关闭 / quit()
}
```

过程式循环（引擎/嵌入宿主用这个——循环主权在你手里）：

```zig
pub fn main() !void {
    // ... initInPlace / PlatformWindow.init 同上 ...

    win.setInputCallback(onInput);              // pump 时的顺手分派，可省
    win.setResizeCallback(onResize);            // 交换链重建挂这里

    plat.start();                               // 进入运行状态（run() 的糖会自动做）
    while (plat.isRunning()) {                  // 窗口标题栏关闭 → onClose 回调里 quit()
        _ = plat.waitEvent(16);                 // 无事件睡 16ms；有事件立即醒
        engine.tick(dt);                        // 你的模拟 / 网络一切逻辑
        engine.render();                        // 你的 present 兜底帧节拍（FIFO present 阻塞处）
    }
}
```

三个原语（三平台同义，契约全文见 `src/platform/interface.zig`）：

- **`plat.pump()`** — 非阻塞排空当前就绪的事件并把回调走完（输入/关闭/缩放）。**不做渲染调度**——帧节奏归你的循环。
- **`plat.waitEvent(timeout_ms)`** — 至多阻塞 `timeout_ms` 毫秒等事件就绪，返回是否就绪（分派仍归随之而来的 `pump()`）。`interface.wait_infinite` 表示无限期；已退出（quit）状态恒 false。工具价值：Wayland 窗口被 occlude 时没有 frame callback、没有事件，`waitEvent` 自然睡住——"被遮挡即暂停"免费送。
- **`plat.run()`** — 回调糖：内部循环 = 阻塞等待 + 帧节拍派发 + owner 回合钩子，语义与旧版逐平台一致。`quit()` 仍是标准停法。

回调签名三个平台一致（`input.InputEvent` 是同一个类型）：`setInputCallback` /
`setCloseCallback` / `setResizeCallback` / `setRenderCallback` / `setPostInputCallback`。
用 `setUserData` / `getUserData` 挂自己的渲染对象，帧回调里取回。

## 接入方自己渲染

windowkit **不定义任何渲染接口**——你不需要实现它，它也不知道你的 renderer 长什么样。
接入只靠四样东西：

### 1. 帧节拍：`setRenderCallback`

平台按自己的 vsync/时钟派发 `fn (*PlatformWindow) void`：

| 平台 | 派发线程 | 默认节拍 | `requestRender()` |
|---|---|---|---|
| Linux | Wayland 事件线程 | `continuous_render = true`：每个 frame callback 派发一次 | 置 `needs_redraw` 并预约下一个 frame callback（按需渲染模式） |
| macOS | CVDisplayLink 线程，**持 `render_mutex`** | `benchmark_mode = true`：每个 vsync 派发一次 | 置 `needs_render`，下个 vsync 生效 |
| Windows | UI 线程（消息循环线程，**无锁**） | 每个 `DwmFlush` 节拍（阻塞到合成帧）派发一次 | 置 `needs_render`，下个节拍生效 |

（这张表描述的是回调糖模式 `run()` 下的调度；过程式循环里渲染时机完全归调用方。）

两个特例：macOS live-resize 期间 DisplayLink 被跳过，改由 `handleResize`
在主线程**同步**派发一次 `on_render`（同样持 `render_mutex`）；`use_display_link = false`
时 macOS 没有时钟，调用方用 `win.render()` 手动派发。Windows 没有后台渲染线程：
消息泵、`on_render`、输入回调全在 UI 线程上串行，`DwmFlush` 返回 0（DWM 禁用/
远程会话）时退化为 16ms 睡眠。

### 2. 原生句柄：`nativeHandles()`

```zig
switch (win.nativeHandles()) {
    .wayland => |wl| // vkCreateWaylandSurfaceKHR(wl.display, wl.surface) / wgpu surface
        _ = wl,
    .appkit => |mac| // CAMetalLayer → nextDrawable；NSWindow/NSView 自由 msgSend
        _ = mac,
    .win32 => |w| // vkCreateWin32SurfaceKHR(w.hinstance, w.hwnd)；D3D12 只用 hwnd
        _ = w,
}
```

- macOS 的 `metal_layer` 由窗口层创建，并随缩放 / DPR 变化同步
  `contentsScale` 与 `drawableSize`；**像素格式、`maximumDrawableCount` 等其余配置**
  由你拿句柄自行 msgSend 设置（本期不进 `WindowOptions`）。
- 句柄只在窗口 `init` 成功之后、`deinit` 之前有效。

### 3. 物理像素尺寸：`framebufferSize()`

swapchain / render target 只认它（`width()`/`height()` 是逻辑像素，DPR ≠ 1 时两者不同）：

- Linux：`逻辑尺寸 × scale_factor`（Wayland `configure` 给的是逻辑像素）
- macOS：直接读 `CAMetalLayer.drawableSize`（窗口层刚同步过的真实值）
- Windows：`GetClientRect`（进程已按 **PerMonitorV2** DPI 感知初始化，
  拿到的本来就是物理像素；`WM_DPICHANGED` 跨屏拖动后自动跟随）

尺寸变化走 `setResizeCallback`——在那里重建 swapchain。

### 4. 清屏色与销毁时序

- `win.getClearColor()`：玻璃窗口（`GlassStyle != .none`）返回**透明**，
  依赖方必须用它清屏，宿主的背景模糊才会透出来。
- 销毁顺序：**先销毁你自己的渲染资源，再 `win.deinit()`**：

```zig
defer {
    renderer.deinit(); // surface / swapchain / drawable 全在这里
    win.deinit();
}
```

### 5. 文件拖放：`InputEvent.file_drop`

被动接收——文件从外部（Explorer/Finder/文件管理器）拖进窗口，库不出数据、
不弹 UI。四个 phase 走同一个窗口输入回调：

```zig
fn onInput(win: *PlatformWindow, event: input.InputEvent) bool {
    switch (event) {
        .file_drop => |d| switch (d.phase) {
            .entered => {},           // 拖进窗口，paths 为空
            .moved => _ = d.position, // 拖动中（客户区逻辑像素）
            .exited => {},
            .dropped => {             // 放下，paths 此时非空
                defer for (d.paths) |p| gpa.free(p); // 要留存就自己拷
                openModels(d.paths, d.position, d.modifiers);
            },
        },
        else => {},
    }
    return false;
}
```

- **`paths` 生命周期**：仅在本次回调执行期间有效，回调返回后立即失效
  （Windows/Windows-webkit 的通用契约：后端派发完就释放）。只想记住
  文件列表就当场拷贝。
- **effect 协商**（源视觉反馈，GLFW 风格）：默认 COPY；Shift→MOVE、
  Ctrl→COPY、Ctrl+Shift→LINK。平台差异：Windows `dropped` 同步派发，
  Wayland 的 `dropped` 要经 pipe 读 `text/uri-list`（异步读文件列表时受限半拍，
  `paths` 契约不受影响）。
- **能力矩阵**：`capabilities.file_drop` 在 Windows / macOS / Linux(Wayland)
  三个后端都为 `true`。
- **开关**：窗口创建用 `WindowOptions.file_drop`（默认 `true`），运行期
  `win.setFileDropEnabled(false)` 随时切换。关闭后窗口以平台原生方式
  “拒绝”拖入——Windows `DragEnter` 报 `DROPEFFECT_NONE`、macOS 回
  `NSDragOperationNone`、Wayland 发 `accept(serial, null)`——光标显示
  不可放下，且不再派发 `.file_drop` 事件。

### 线程契约

- Linux `on_render`：Wayland 事件线程。
- macOS `on_render` / live-resize 同步渲染：持 `render_mutex`；
  输入回调也在**这把锁**里分发——所以**输入回调与渲染回调从不并发**，
  你的共享数据在这两个回调之间不需要额外加锁。回调内不要调用会再取
  `render_mutex` 的窗口方法（当前没有这样的方法；`os_unfair_lock` 不可递归）。
- Windows `on_render`：UI 线程。消息泵、输入回调、渲染回调天然串行
  （没有后台渲染线程，`Window` 里也就没有 `render_mutex`），回调间同样无需加锁；
  回调内可安全地调用窗口方法。
- 过程式模式（`pump`/`waitEvent`）下一切都在调用方线程：macOS 的
  `render_mutex` 只在 `setRenderCallback` 仍被注册时才有意义，引擎接入
  通常不注册它，输入与渲染也就天然同线程。

## 目录

```
src/
├── root.zig              # 对外 API（含 NativeHandles / FramebufferSize 导出）
├── geometry.zig          # Color / Size / Rect / Point(窗口 API 的几何与颜色词汇)
├── examples/
│   └── demo.zig          # 原生 demo：打印 handles + framebuffer 尺寸
├── input/                # InputEvent / KeyCode / keymap / actions（声明式键位）
└── platform/
    ├── mod.zig           # 编译期选后端
    ├── interface.zig     # WindowOptions / PlatformCapabilities / GlassStyle 等共享类型
    ├── native_handles.zig    # NativeHandles + FramebufferSize 契约
    ├── window_registry.zig / mutex.zig
    ├── linux/            # wayland / platform / window / input / dnd(data-device)
    ├── macos/            # objc 运行时 / appkit / input_view(含拖放) / window_delegate /
    │                     #   window / platform / display_link
    └── windows/          # win32 手写绑定 / platform / window(WndProc) / input(VK→kVK) /
                          #   drop_target(OLE IDropTarget)
```

## 已知边界

- **文件拖放**：Windows（OLE `IDropTarget`，真机验证过）、macOS
  （NSView `NSDraggingDestination`）、Linux （Wayland `wl_data_device`）都通。
- **macOS 像素格式/`maximumDrawableCount` 不在 `WindowOptions`**：拿 `nativeHandles()`
  的 `metal_layer` 自己 msgSend（本期有意不做，避免窗口层开始解释渲染语义）。
- **Windows 按内容拖动 / 深色标题栏 / 系统菜单**：`capabilities.window_drag_by_content`
  如实标 `false`（`WM_NCLBUTTONDOWN`+`HTCAPTION` 能做，但 `PlatformWindow` 没这个入口，
  不虚标）；`DWMWA_USE_IMMERSIVE_DARK_MODE` 常量已绑定、暂未接进 `WindowOptions`。
  IME 候选窗只做了 `ImmSetCandidateWindow` 定位（`setImeCursorRect`），
  组合窗内的装饰（下划线/选区高亮）由系统默认画。
- **`input/actions.zig`（声明式键位）去留未定**：纯输入域、无渲染依赖，暂保留。
- **macOS 只做了交叉编译验证**：`typecheck-macos` 通过，但没在真机跑过
  （Windows 后端在 Windows 机器上真机跑通）。
- **过程式内核的 macOS 真机回归待做**：`pump()`/`waitEvent()` 走
  `nextEventMatchingMask:` 手泵，语义与旧 `run()` 相同（旧 `run` 本来就是
  手泵而非 `[NSApp run]`），但 live-resize 的嵌套追踪、IME、菜单仍需要在
  真机上按过程式用法回归一遍。
