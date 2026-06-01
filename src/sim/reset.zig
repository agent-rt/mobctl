//! sim 重置（REQ §6.6，必须显式触发）。
//!
//! iOS：`simctl erase <udid>` 清空内容与设置。erase 要求设备 Shutdown，
//!      故运行中先 `simctl shutdown` 再 erase。
//! Android：detached 冷启动 `emulator -avd <name> -wipe-data -no-snapshot-load`。
//!      运行中拒绝（device_busy），要求先 shutdown，避免起第二个实例。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const discovery = @import("discovery.zig");

pub const Outcome = struct {
    state: envelope.State,
    pid: ?u32 = null,
    diagnostics: []const []const u8,
};

pub const Error = error{ ResetFailed, ToolMissing, DeviceBusy };

pub fn reset(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate) Error!Outcome {
    return switch (cand.platform) {
        .ios => resetIos(arena, io, cand),
        .android => resetAndroid(arena, io, env, cand),
    };
}

fn resetIos(arena: std.mem.Allocator, io: Io, cand: discovery.Candidate) Error!Outcome {
    // erase 要求 Shutdown：运行中先关，best-effort。
    var shut = false;
    if (cand.state == .ready or cand.state == .booting) {
        _ = exec.capture(arena, io, &.{ "xcrun", "simctl", "shutdown", cand.id });
        shut = true;
    }
    const res = exec.capture(arena, io, &.{ "xcrun", "simctl", "erase", cand.id }) orelse return error.ToolMissing;
    if (!res.ok()) return error.ResetFailed;
    const note: []const u8 = if (shut) "shut down then erased to factory state" else "erased to factory state";
    return .{ .state = .available, .diagnostics = dup(arena, &.{note}) };
}

fn resetAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate) Error!Outcome {
    // 运行中拒绝：先 shutdown 再 reset，避免起第二个实例。
    if (std.mem.startsWith(u8, cand.id, "emulator-") or cand.state == .ready or cand.state == .booting)
        return error.DeviceBusy;
    const emu = discovery.emulatorBin(arena, io, env) orelse return error.ToolMissing;
    const pid = exec.spawnDetached(io, &.{ emu, "-avd", cand.name, "-wipe-data", "-no-snapshot-load" }) orelse return error.ResetFailed;
    return .{
        .state = .booting,
        .pid = pid,
        .diagnostics = dup(arena, &.{"cold boot with data wipe launched; poll with `sim wait-ready`"}),
    };
}

fn dup(arena: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    return arena.dupe([]const u8, items) catch &.{};
}
