//! windowkit 的渲染线程阻塞互斥锁。
//!
//! ## 为什么还需要这个垫片
//!
//! Zig 0.16 引入的 `std.Io.Mutex` 要求把 `Io` 实例穿进每一次
//! `.lock()` / `.unlock()` 调用。迁到 `std.Io.Mutex` 后，唯一剩下
//! 的是 macOS 的 `Window.render_mutex`：它由 CVDisplayLink 回调线程
//! 加锁——该线程由 CoreVideo 创建并持有，不是窗口的线程，因此拿不到
//! 天然的 `Io` 实例。本文件只服务渲染回调同步这一个场景。
//!
//! ## 底层原语
//!
//!   • macOS / Darwin — `os_unfair_lock`
//!   • Linux / POSIX  — `pthread_mutex_t`（Linux 上必链 libc）
//!   • Windows        — `SRWLOCK`（kernel32，无堆、无内核对象）
//!
//! ## 为什么不用 `std.atomic.Mutex`？
//!
//! 它只暴露 `tryLock`（一次 CAS）和 `unlock`，没有阻塞式 `lock`。
//! 用 tryLock 自旋会白白烧 CPU；渲染线程同步的临界区可能短暂阻塞在
//! GPU 命令提交上，不可接受。

const std = @import("std");
const builtin = @import("builtin");

/// 渲染线程同步用的阻塞互斥锁。
///
/// **其他场景请用 `std.Io.Mutex`。** 本垫片只为 macOS 上拿不到
/// `Io` 实例的 CVDisplayLink 线程而存在，完整理由见模块头注释。
///
/// 默认即未锁定状态（API 兼容原 `std.Thread.Mutex`）。
pub const Mutex = switch (builtin.os.tag) {
    .macos => DarwinMutex,
    .windows => SrwMutex,
    .linux => PosixMutex,
    else => PosixMutex,
};

// ---------------------------------------------------------------------------
// Darwin: os_unfair_lock
// ---------------------------------------------------------------------------

const DarwinMutex = struct {
    oul: std.c.os_unfair_lock = .{},

    pub fn lock(self: *DarwinMutex) void {
        std.c.os_unfair_lock_lock(&self.oul);
    }

    pub fn unlock(self: *DarwinMutex) void {
        std.c.os_unfair_lock_unlock(&self.oul);
    }

    pub fn tryLock(self: *DarwinMutex) bool {
        return std.c.os_unfair_lock_trylock(&self.oul);
    }
};

// ---------------------------------------------------------------------------
// POSIX: pthread_mutex_t
// ---------------------------------------------------------------------------

const PosixMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *PosixMutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn tryLock(self: *PosixMutex) bool {
        const rc = std.c.pthread_mutex_trylock(&self.inner);
        if (rc == .SUCCESS) return true;
        std.debug.assert(rc == .BUSY);
        return false;
    }
};

// ---------------------------------------------------------------------------
// Windows: SRWLOCK (kernel32)
// ---------------------------------------------------------------------------

/// Slim reader/writer lock —— Windows 上的轻量阻塞互斥:零堆分配、无内核
/// 对象,`SRWLOCK_INIT` 即默认未锁定。API 里没有错误码(失败即为锁已被
/// 持有,`Try*` 返回假),所以这里无 assert 可写。
///
/// 声明是手写的(与 `platform/windows/win32.zig` 同风格),带 DLL 名的
/// extern 由链接器自动挂 kernel32,不依赖 Windows SDK 头文件。
const SrwMutex = struct {
    inner: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn lock(self: *SrwMutex) void {
        AcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *SrwMutex) void {
        ReleaseSRWLockExclusive(&self.inner);
    }

    pub fn tryLock(self: *SrwMutex) bool {
        return TryAcquireSRWLockExclusive(&self.inner) != 0;
    }
};

extern "kernel32" fn AcquireSRWLockExclusive(*std.os.windows.SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*std.os.windows.SRWLOCK) callconv(.winapi) void;
/// 返回 BOOLEAN(u8):非零 = 拿到锁。
extern "kernel32" fn TryAcquireSRWLockExclusive(*std.os.windows.SRWLOCK) callconv(.winapi) u8;


