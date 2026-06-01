//! device 句柄导出（handle-fields 定稿，Android 真机）。
//!
//! 必选：transport / connection_hint。device 专属可选：connection_type
//! (usb|wifi) / trust_state。ready 时附 ready_at + runtime(Android 版本)。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");
const discovery = @import("discovery.zig");

/// `ready` 显式传入：wait-ready / ensure 成功后设备已 ready，但 cand.state
/// 可能还是轮询前的旧值，故不直接用 cand.state。
pub fn forDevice(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, ready: bool) envelope.Handle {
    return .{
        .transport = "adb",
        .connection_hint = std.fmt.allocPrint(arena, "adb:{s}", .{cand.id}) catch cand.id,
        .connection_type = cand.connection_type,
        .trust_state = if (cand.trusted) "trusted" else "untrusted",
        .ready_at = if (ready) "now" else null,
        .runtime = if (ready) androidRelease(arena, io, env, cand.id) else null,
    };
}

fn androidRelease(arena: std.mem.Allocator, io: Io, env: *const EnvMap, serial: []const u8) ?[]const u8 {
    const adb = sim_discovery.adbBin(arena, io, env) orelse return null;
    const r = exec.capture(arena, io, &.{ adb, "-s", serial, "shell", "getprop", "ro.build.version.release" }) orelse return null;
    if (!r.ok()) return null;
    const v = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (v.len == 0) return null;
    return std.fmt.allocPrint(arena, "Android {s}", .{v}) catch null;
}
