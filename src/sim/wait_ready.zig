//! sim ready 判定（轮询 + 超时 + 证据）。
//!
//! iOS：simctl 报 Booted，且能在设备里 spawn 一个进程（核心服务已起）。
//! Android：adb 可见为 device，且 `getprop sys.boot_completed` == 1。
//!
//! 返回明确的 ready 证据（REQ §6.3 / SPEC §5.2），超时则带 timed_out。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const discovery = @import("discovery.zig");

const poll_interval_ms = 500;

pub const Result = struct {
    ready: bool,
    state: envelope.State,
    elapsed_ms: u64,
    timed_out: bool = false,
    /// ready 判定依据；未 ready 时是"还差什么"的线索。
    evidence: []const []const u8,
};

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.boot, io).nanoseconds, std.time.ns_per_ms));
}

pub fn waitReady(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, timeout_ms: u64) Result {
    const start = nowMs(io);
    const deadline = start + @as(i64, @intCast(timeout_ms));
    while (true) {
        const probe = switch (cand.platform) {
            .ios => probeIos(arena, io, cand.id),
            .android => probeAndroid(arena, io, env, cand),
        };
        if (probe.ready) {
            return .{
                .ready = true,
                .state = .ready,
                .elapsed_ms = @intCast(nowMs(io) - start),
                .evidence = probe.evidence,
            };
        }
        if (nowMs(io) >= deadline) {
            return .{
                .ready = false,
                .state = .booting,
                .elapsed_ms = @intCast(nowMs(io) - start),
                .timed_out = true,
                .evidence = probe.evidence,
            };
        }
        std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .boot) catch {};
    }
}

const Probe = struct {
    ready: bool,
    evidence: []const []const u8,
};

// ---------------- iOS ----------------

fn iosState(arena: std.mem.Allocator, io: Io, udid: []const u8) ?[]const u8 {
    const res = exec.capture(arena, io, &.{ "xcrun", "simctl", "list", "devices", "-j" }) orelse return null;
    if (!res.ok()) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, res.stdout, .{}) catch return null;
    const devices = (root.object.get("devices") orelse return null).object;
    var it = devices.iterator();
    while (it.next()) |entry| {
        const arr = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |dv| {
            const o = switch (dv) {
                .object => |obj| obj,
                else => continue,
            };
            const id = if (o.get("udid")) |v| v.string else continue;
            if (std.mem.eql(u8, id, udid))
                return if (o.get("state")) |v| v.string else null;
        }
    }
    return null;
}

fn probeIos(arena: std.mem.Allocator, io: Io, udid: []const u8) Probe {
    const state = iosState(arena, io, udid) orelse
        return .{ .ready = false, .evidence = lit(arena, "device not found in simctl list") };
    if (!std.mem.eql(u8, state, "Booted"))
        return .{ .ready = false, .evidence = lit(arena, "simctl state != Booted") };
    // Booted 后再验证能在设备里 spawn 进程 —— 核心服务已就绪的硬证据。
    const t = exec.capture(arena, io, &.{ "xcrun", "simctl", "spawn", udid, "/usr/bin/true" }) orelse
        return .{ .ready = false, .evidence = lit(arena, "simctl spawn unavailable") };
    if (!t.ok())
        return .{ .ready = false, .evidence = lit(arena, "Booted but services not ready (spawn failed)") };
    return .{ .ready = true, .evidence = lits(arena, &.{ "simctl state=Booted", "spawn /usr/bin/true ok" }) };
}

// ---------------- Android ----------------

fn probeAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate) Probe {
    const adb = discovery.adbBin(arena, io, env) orelse
        return .{ .ready = false, .evidence = lit(arena, "adb not found") };

    // 解析 serial：cand.id 已是 emulator-XXXX 就直接用；否则按 AVD 名在
    // adb devices 里找刚启动的实例。
    const serial = if (std.mem.startsWith(u8, cand.id, "emulator-"))
        cand.id
    else
        serialForAvd(arena, io, adb, cand.name) orelse
            return .{ .ready = false, .evidence = lit(arena, "emulator not yet visible to adb") };

    // boot_completed?
    const bc = exec.capture(arena, io, &.{ adb, "-s", serial, "shell", "getprop", "sys.boot_completed" }) orelse
        return .{ .ready = false, .evidence = lit(arena, "adb shell unavailable") };
    if (!bc.ok())
        return .{ .ready = false, .evidence = lit(arena, "device offline/unauthorized") };
    const v = std.mem.trim(u8, bc.stdout, " \t\r\n");
    if (!std.mem.eql(u8, v, "1"))
        return .{ .ready = false, .evidence = lit(arena, "sys.boot_completed != 1") };
    return .{ .ready = true, .evidence = lits(arena, &.{ "adb state=device", "sys.boot_completed=1" }) };
}

fn serialForAvd(arena: std.mem.Allocator, io: Io, adb: []const u8, avd: []const u8) ?[]const u8 {
    const devs = exec.capture(arena, io, &.{ adb, "devices" }) orelse return null;
    if (!devs.ok()) return null;
    var dl = std.mem.tokenizeScalar(u8, devs.stdout, '\n');
    while (dl.next()) |line| {
        if (!std.mem.startsWith(u8, line, "emulator-")) continue;
        var cols = std.mem.tokenizeAny(u8, line, " \t\r");
        const serial = cols.next() orelse continue;
        const st = cols.next() orelse continue;
        if (!std.mem.eql(u8, st, "device")) continue;
        const r = exec.capture(arena, io, &.{ adb, "-s", serial, "emu", "avd", "name" }) orelse continue;
        if (!r.ok()) continue;
        var it = std.mem.tokenizeAny(u8, r.stdout, "\r\n");
        const name = std.mem.trim(u8, it.next() orelse "", " \t\r");
        if (std.mem.eql(u8, name, avd)) return arena.dupe(u8, serial) catch serial;
    }
    return null;
}

// ---------------- helpers ----------------

fn lit(arena: std.mem.Allocator, s: []const u8) []const []const u8 {
    return lits(arena, &.{s});
}

fn lits(arena: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    return arena.dupe([]const u8, items) catch &.{};
}
