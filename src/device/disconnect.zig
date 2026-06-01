//! device 断开（Android wifi）。`adb disconnect <serial>`。
//! 仅对 TCP/IP（wifi）连接有意义；USB 设备无法 disconnect。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");

pub const Outcome = struct {
    state: envelope.State,
    ok: bool,
    message: []const u8,
};

/// null = adb 缺失。
pub fn disconnect(arena: std.mem.Allocator, io: Io, env: *const EnvMap, target: []const u8) ?Outcome {
    const adb = sim_discovery.adbBin(arena, io, env) orelse return null;
    const r = exec.capture(arena, io, &.{ adb, "disconnect", target }) orelse return null;
    const out = std.mem.trim(u8, r.stdout, " \t\r\n");
    const e = std.mem.trim(u8, r.stderr, " \t\r\n");

    if (r.ok() and std.mem.indexOf(u8, out, "error") == null) {
        return .{ .state = .stopped, .ok = true, .message = if (out.len > 0) out else "disconnected" };
    }
    const msg = if (e.len > 0) e else if (out.len > 0) out else "disconnect failed";
    return .{ .state = .failed, .ok = false, .message = msg };
}
