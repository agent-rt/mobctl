//! device 日志采集（Android 真机，REQ §6.16）。
//! `adb -s <serial> logcat -d -t <lines>`（-d 立即返回，-t 限行）。需 ready。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");
const discovery = @import("discovery.zig");

pub const Error = error{ NotReady, ToolMissing, NoLogs };

pub fn collect(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, lines: u32) Error![]const u8 {
    if (cand.state != .ready) return error.NotReady;
    const adb = sim_discovery.adbBin(arena, io, env) orelse return error.ToolMissing;
    const t = std.fmt.allocPrint(arena, "{d}", .{lines}) catch return error.NoLogs;
    const r = exec.capture(arena, io, &.{ adb, "-s", cand.id, "logcat", "-d", "-t", t }) orelse return error.ToolMissing;
    if (!r.ok()) return error.NoLogs;
    return r.stdout;
}
