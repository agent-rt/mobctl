//! 子进程执行 + 输出捕获。所有外部工具（xcrun / adb / emulator）都走这里，
//! 统一成"跑一条命令、拿 stdout/stderr/退出码"的同步模型。
//!
//! argv[0] 解析用父进程 PATH：`xcrun` 在 PATH 上可直接用名字；`adb` /
//! `emulator` 不在 PATH，调用方需传绝对路径。

const std = @import("std");
const Io = std.Io;

pub const Output = struct {
    /// 正常退出的退出码；被信号杀死等异常情况为 null。
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(self: Output) bool {
        return self.exit_code != null and self.exit_code.? == 0;
    }
};

/// 跑 argv 并捕获输出。spawn 失败（如二进制不存在）返回 null —— 调用方据此
/// 把"工具缺失"当成可降级的状态，而不是崩溃。stdout/stderr 用 `gpa` 分配，
/// 通常传 arena，免手动释放。
pub fn capture(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) ?Output {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    const code: ?u8 = switch (r.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .exit_code = code, .stdout = r.stdout, .stderr = r.stderr };
}

/// 以分离方式启动一个长驻进程（如 Android emulator），不等待、不捕获。
/// stdio 全部接 /dev/null，`pgid=0` 让它脱离父进程组——父进程退出 / Ctrl-C
/// 不会连带杀掉它。返回子进程 pid（失败返回 null）。
pub fn spawnDetached(io: Io, argv: []const []const u8) ?u32 {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return null;
    const id = child.id orelse return null;
    return std.math.cast(u32, id) orelse null;
}
