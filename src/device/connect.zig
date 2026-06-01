//! device 连接（Android wifi）。USB 设备插上即被 list 发现，无需 connect；
//! connect 主要用于 wifi：`adb connect <ip[:port]>`（默认端口 5555）。
//!
//! adb connect 的退出码在不同版本不可靠，故按 stdout 文本判定：
//!   "already connected to ..." → 幂等复用
//!   "connected to ..."         → 新建连接
//!   其余                        → 失败（把 adb 的话原样回传）

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");

pub const Outcome = struct {
    serial: []const u8,
    state: envelope.State,
    ok: bool,
    already: bool = false,
    message: []const u8,
};

/// 返回 null 表示 adb 缺失（工具问题）；其余情况都进 Outcome（含失败）。
pub fn connect(arena: std.mem.Allocator, io: Io, env: *const EnvMap, target: []const u8) ?Outcome {
    const adb = sim_discovery.adbBin(arena, io, env) orelse return null;
    const addr = normalize(arena, target);
    const r = exec.capture(arena, io, &.{ adb, "connect", addr }) orelse return null;
    const out = std.mem.trim(u8, r.stdout, " \t\r\n");

    if (std.mem.indexOf(u8, out, "already connected") != null)
        return .{ .serial = addr, .state = .connecting, .ok = true, .already = true, .message = "already connected; reused" };
    if (std.mem.indexOf(u8, out, "connected to") != null)
        return .{ .serial = addr, .state = .connecting, .ok = true, .message = "connected; verify readiness with `device wait-ready`" };

    // 失败：把 adb 的原文回传（"failed to connect..."/"cannot connect..."）。
    const msg = if (out.len > 0) out else "adb connect failed";
    return .{ .serial = addr, .state = .failed, .ok = false, .message = msg };
}

/// 无端口则补 :5555（adb wifi 默认端口）。
fn normalize(arena: std.mem.Allocator, target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, ':') != null) return target;
    return std.fmt.allocPrint(arena, "{s}:5555", .{target}) catch target;
}
