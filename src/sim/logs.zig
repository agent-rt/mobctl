//! sim 日志采集（REQ §6.16）。
//!
//! Android：复用 device/logs 的 `adb logcat` argv 构建器（dump / follow / pid / tag）。
//! iOS：follow → `simctl spawn <udid> log stream`（流式）；dump → `log show` 取末尾 N 行。
//! grep 在进程内过滤；pid/tag/package 是 Android-only，iOS 忽略。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("discovery.zig");
const device_logs = @import("../device/logs.zig");

pub const Error = device_logs.Error;
pub const Filter = device_logs.Filter;

/// 该候选是否走流式输出：Android 任意 / iOS follow。iOS dump 走 collectIosDump。
pub fn isStream(cand: sim_discovery.Candidate, follow: bool) bool {
    return cand.platform == .android or follow;
}

/// 流式 argv：Android `adb logcat` / iOS `simctl spawn log stream`。
pub fn prepareStream(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: sim_discovery.Candidate, f: Filter) Error![]const []const u8 {
    if (cand.state != .ready) return error.NotReady;
    if (cand.platform == .android) {
        const adb = sim_discovery.adbBin(arena, io, env) orelse return error.ToolMissing;
        return device_logs.buildLogcatArgv(arena, io, adb, cand.id, f);
    }
    // iOS follow
    var a: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "xcrun", "simctl", "spawn", cand.id, "log", "stream", "--style", "compact" }) |tok|
        try a.append(arena, tok);
    return a.toOwnedSlice(arena);
}

/// iOS dump：`log show --last 2m` 取末尾 N 行。
pub fn collectIosDump(arena: std.mem.Allocator, io: Io, cand: sim_discovery.Candidate, lines: u32) Error![]const u8 {
    if (cand.state != .ready) return error.NotReady;
    const r = exec.capture(arena, io, &.{
        "xcrun", "simctl", "spawn", cand.id, "log", "show", "--last", "2m", "--style", "compact",
    }) orelse return error.ToolMissing;
    if (!r.ok()) return error.ToolMissing;
    return lastLines(r.stdout, lines);
}

/// 取文本末尾 n 行。
fn lastLines(text: []const u8, n: u32) []const u8 {
    if (n == 0 or text.len == 0) return text;
    var count: u32 = 0;
    var i: usize = text.len;
    if (i > 0 and text[i - 1] == '\n') i -= 1;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            count += 1;
            if (count >= n) return text[i..];
        }
    }
    return text;
}

test "lastLines returns tail" {
    const t = "a\nb\nc\nd\n";
    try std.testing.expectEqualStrings("c\nd\n", lastLines(t, 2));
    try std.testing.expectEqualStrings(t, lastLines(t, 10));
}
