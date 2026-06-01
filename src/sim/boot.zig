//! sim 启动。
//!
//! iOS：`xcrun simctl boot <udid>` —— 同步返回，设备随后进入 Booted。
//! Android：detached 启动 `emulator -avd <name>` —— 长驻进程，立即返回 booting，
//!          ready 判定留给 wait-ready（待实现）。
//!
//! 幂等：已 ready 的候选直接返回 `already`，不重复 boot（REQ §6.2 / §6.4）。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const discovery = @import("discovery.zig");

pub const Outcome = struct {
    state: envelope.State,
    /// 已在运行、未重复启动。
    already: bool = false,
    pid: ?u32 = null,
    transport: []const u8,
    connection_hint: []const u8,
    diagnostics: []const []const u8 = &.{},
};

pub const Error = error{ BootFailed, ToolMissing };

pub fn boot(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate) Error!Outcome {
    if (cand.state == .ready) {
        return .{
            .state = .ready,
            .already = true,
            .transport = if (cand.platform == .ios) "simctl" else "adb",
            .connection_hint = connHint(arena, cand),
            .diagnostics = dup(arena, &.{"already running; reused without re-boot"}),
        };
    }
    return switch (cand.platform) {
        .ios => bootIos(arena, io, cand),
        .android => bootAndroid(arena, io, env, cand),
    };
}

fn bootIos(arena: std.mem.Allocator, io: Io, cand: discovery.Candidate) Error!Outcome {
    const res = exec.capture(arena, io, &.{ "xcrun", "simctl", "boot", cand.id }) orelse return error.ToolMissing;
    if (!res.ok()) {
        // simctl 对已 booted 设备会报 "Unable to boot device in current state: Booted"。
        if (std.mem.indexOf(u8, res.stderr, "Booted") != null) {
            return .{
                .state = .ready,
                .already = true,
                .transport = "simctl",
                .connection_hint = connHint(arena, cand),
                .diagnostics = dup(arena, &.{"already booted"}),
            };
        }
        return error.BootFailed;
    }
    return .{
        .state = .booting,
        .transport = "simctl",
        .connection_hint = connHint(arena, cand),
        .diagnostics = dup(arena, &.{"boot issued; poll readiness with `sim wait-ready` (未实现)"}),
    };
}

fn bootAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate) Error!Outcome {
    const emu = discovery.emulatorBin(arena, io, env) orelse return error.ToolMissing;
    const pid = exec.spawnDetached(io, &.{ emu, "-avd", cand.name }) orelse return error.BootFailed;
    return .{
        .state = .booting,
        .pid = pid,
        .transport = "adb",
        .connection_hint = "(booting; serial assigned once adb sees it)",
        .diagnostics = dup(arena, &.{"emulator launching in background; poll readiness with `sim wait-ready` (未实现)"}),
    };
}

fn connHint(arena: std.mem.Allocator, cand: discovery.Candidate) []const u8 {
    return switch (cand.platform) {
        .ios => std.fmt.allocPrint(arena, "xcrun simctl {s}", .{cand.id}) catch "xcrun simctl",
        .android => std.fmt.allocPrint(arena, "adb:{s}", .{cand.id}) catch "adb",
    };
}

/// 把字面量切片复制到 arena，匹配 Outcome.diagnostics 的生命周期。
fn dup(arena: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    return arena.dupe([]const u8, items) catch &.{};
}
