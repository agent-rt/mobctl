//! device 日志采集（Android 真机，REQ §6.16）。`adb logcat`。
//!
//! 支持 dump（`-d -t N`）与 follow（实时）；按 pid / package / tag 在 logcat
//! 层过滤，按 grep 在进程内过滤（流式输出由 shared/exec.streamLogs 负责）。
//!
//! `buildLogcatArgv` 是纯 argv 构建器，device 与 sim-android 共用（不依赖 cli 层）。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");
const discovery = @import("discovery.zig");

pub const Error = error{ NotReady, ToolMissing, OutOfMemory };

/// 日志过滤参数（cli 层从 TargetOpts 拷过来；grep 不在此，单独传 streamLogs）。
pub const Filter = struct {
    follow: bool = false,
    lines: u32 = 200,
    pid: ?[]const u8 = null,
    package: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    level: ?[]const u8 = null, // V/D/I/W/E/F
};

/// 预检 + 构建 `adb logcat` argv。
pub fn prepare(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, f: Filter) Error![]const []const u8 {
    if (cand.state != .ready) return error.NotReady;
    const adb = sim_discovery.adbBin(arena, io, env) orelse return error.ToolMissing;
    return buildLogcatArgv(arena, io, adb, cand.id, f);
}

/// adb logcat argv 构建器（device 与 sim-android 共用）。
pub fn buildLogcatArgv(arena: std.mem.Allocator, io: Io, adb: []const u8, serial: []const u8, f: Filter) Error![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.append(arena, adb);
    try a.append(arena, "-s");
    try a.append(arena, serial);
    try a.append(arena, "logcat");
    if (!f.follow) {
        try a.append(arena, "-d");
        try a.append(arena, "-t");
        try a.append(arena, try std.fmt.allocPrint(arena, "{d}", .{f.lines}));
    }
    // 进程过滤：显式 pid，或按 package 解析（app 可能多进程 → 多个 --pid，借鉴 pidcat）。
    if (f.pid) |p| {
        try a.append(arena, "--pid");
        try a.append(arena, p);
    } else if (f.package) |pkg| {
        for (resolvePids(arena, io, adb, serial, pkg)) |p| {
            try a.append(arena, "--pid");
            try a.append(arena, p);
        }
    }
    // filterspec（放末尾）：tag + 最低优先级。
    //   有 tag：`<tag>:<level|V> *:S`（只看该 tag）
    //   仅 level：`*:<level>`
    const lvl = f.level orelse "V";
    if (f.tag) |t| {
        try a.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ t, lvl }));
        try a.append(arena, "*:S");
    } else if (f.level) |l| {
        try a.append(arena, try std.fmt.allocPrint(arena, "*:{s}", .{l}));
    }
    return a.toOwnedSlice(arena);
}

/// `adb shell pidof <pkg>` → 所有 pid（app 多进程时返回多个）。
fn resolvePids(arena: std.mem.Allocator, io: Io, adb: []const u8, serial: []const u8, pkg: []const u8) []const []const u8 {
    const r = exec.capture(arena, io, &.{ adb, "-s", serial, "shell", "pidof", pkg }) orelse return &.{};
    if (!r.ok()) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, r.stdout, " \t\r\n");
    while (it.next()) |p| out.append(arena, arena.dupe(u8, p) catch continue) catch {};
    return out.toOwnedSlice(arena) catch &.{};
}
