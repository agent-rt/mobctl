//! sim 关闭。
//!
//! iOS：`xcrun simctl shutdown <udid>`。
//! Android：`adb -s <serial> emu kill`（graceful）。
//!
//! 幂等：已停止的对象直接返回 `already`（REQ §6.5 / §8.2）。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const discovery = @import("discovery.zig");

pub const Outcome = struct {
    state: envelope.State = .stopped,
    /// 调用时已经是停止状态，未执行关闭动作。
    already: bool = false,
    diagnostics: []const []const u8 = &.{},
};

pub const Error = error{ ShutdownFailed, ToolMissing };

pub fn shutdown(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, force: bool) Error!Outcome {
    // 未运行（available/stopped）即视为已停止，幂等返回。
    if (cand.state != .ready and cand.state != .booting) {
        return .{ .already = true, .diagnostics = dup(arena, &.{"already stopped"}) };
    }
    return switch (cand.platform) {
        .ios => shutdownIos(arena, io, cand),
        .android => shutdownAndroid(arena, io, env, cand, force),
    };
}

fn shutdownIos(arena: std.mem.Allocator, io: Io, cand: discovery.Candidate) Error!Outcome {
    const res = exec.capture(arena, io, &.{ "xcrun", "simctl", "shutdown", cand.id }) orelse return error.ToolMissing;
    if (!res.ok()) {
        if (std.mem.indexOf(u8, res.stderr, "current state: Shutdown") != null)
            return .{ .already = true, .diagnostics = dup(arena, &.{"already shut down"}) };
        return error.ShutdownFailed;
    }
    return .{ .diagnostics = dup(arena, &.{"simctl shutdown issued"}) };
}

fn shutdownAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, force: bool) Error!Outcome {
    const adb = discovery.adbBin(arena, io, env) orelse return error.ToolMissing;
    // 运行中的候选 id 已是 emulator-XXXX serial。
    const res = exec.capture(arena, io, &.{ adb, "-s", cand.id, "emu", "kill" }) orelse return error.ToolMissing;
    if (!res.ok()) return error.ShutdownFailed;
    const note = if (force) "adb emu kill issued (force requested)" else "adb emu kill issued";
    return .{ .diagnostics = dup(arena, &.{note}) };
}

fn dup(arena: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    return arena.dupe([]const u8, items) catch &.{};
}
