//! device ready 判定（Android 真机）。
//!
//! ready = adb 可见为 `device`（已授权+在线）+ `getprop sys.boot_completed`==1。
//!
//! 关键：`unauthorized` 是需人工确认的步骤，**立即显式上报 permission_denied，
//! 不静默重试**（SPEC §6.2）。`offline` 视为瞬态，继续轮询到超时。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const err = @import("../shared/error.zig");
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");
const discovery = @import("discovery.zig");

const poll_interval_ms = 500;

pub const Result = struct {
    ready: bool,
    state: envelope.State,
    elapsed_ms: u64,
    timed_out: bool = false,
    /// 非 null：遇到需显式上报、不应静默重试的阻断（如 unauthorized）。
    blocked: ?err.Kind = null,
    evidence: []const []const u8,
};

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.boot, io).nanoseconds, std.time.ns_per_ms));
}

pub fn waitReady(arena: std.mem.Allocator, io: Io, env: *const EnvMap, serial: []const u8, timeout_ms: u64) Result {
    const start = nowMs(io);
    const deadline = start + @as(i64, @intCast(timeout_ms));
    while (true) {
        const p = probe(arena, io, env, serial);
        if (p.blocked) |k| return .{
            .ready = false,
            .state = .failed,
            .elapsed_ms = @intCast(nowMs(io) - start),
            .blocked = k,
            .evidence = p.evidence,
        };
        if (p.ready) return .{
            .ready = true,
            .state = .ready,
            .elapsed_ms = @intCast(nowMs(io) - start),
            .evidence = p.evidence,
        };
        if (nowMs(io) >= deadline) return .{
            .ready = false,
            .state = .connecting,
            .elapsed_ms = @intCast(nowMs(io) - start),
            .timed_out = true,
            .evidence = p.evidence,
        };
        std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .boot) catch {};
    }
}

const Probe = struct {
    ready: bool = false,
    blocked: ?err.Kind = null,
    evidence: []const []const u8,
};

fn probe(arena: std.mem.Allocator, io: Io, env: *const EnvMap, serial: []const u8) Probe {
    const cands = discovery.list(arena, io, env, .android) catch
        return .{ .evidence = lit(arena, "discovery failed") };

    var found: ?discovery.Candidate = null;
    for (cands) |c| {
        if (std.mem.eql(u8, c.id, serial)) found = c;
    }
    const c = found orelse return .{ .evidence = lit(arena, "device not visible to adb") };

    // 需人工授权 —— 显式上报，不静默重试。
    if (std.mem.eql(u8, c.raw_state, "unauthorized"))
        return .{ .blocked = .permission_denied, .evidence = lit(arena, "unauthorized — accept the USB debugging prompt on the device") };

    if (!std.mem.eql(u8, c.raw_state, "device"))
        return .{ .evidence = lits(arena, &.{ "adb state=", c.raw_state }) };

    // 已授权在线 → 查 boot_completed。
    const adb = sim_discovery.adbBin(arena, io, env) orelse return .{ .evidence = lit(arena, "adb not found") };
    const bc = exec.capture(arena, io, &.{ adb, "-s", serial, "shell", "getprop", "sys.boot_completed" }) orelse
        return .{ .evidence = lit(arena, "adb shell unavailable") };
    if (!bc.ok()) return .{ .evidence = lit(arena, "adb shell failed") };
    const v = std.mem.trim(u8, bc.stdout, " \t\r\n");
    if (!std.mem.eql(u8, v, "1")) return .{ .evidence = lit(arena, "sys.boot_completed != 1") };

    return .{ .ready = true, .evidence = lits(arena, &.{ "adb state=device", "sys.boot_completed=1" }) };
}

fn lit(arena: std.mem.Allocator, s: []const u8) []const []const u8 {
    return lits(arena, &.{s});
}

fn lits(arena: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    return arena.dupe([]const u8, items) catch &.{};
}
