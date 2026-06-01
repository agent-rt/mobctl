//! sim 日志采集（REQ §6.16）。返回有界的原始日志文本，由 cmd 决定落盘 /
//! NDJSON 包装。需设备 ready（日志来自运行中的实例）。
//!
//! Android：`adb -s <serial> logcat -d -t <lines>`（-d 立即返回，-t 限行）。
//! iOS：`xcrun simctl spawn <udid> log show --last 2m --style compact`，
//!      取末尾 <lines> 行。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const exec = @import("../shared/exec.zig");
const discovery = @import("discovery.zig");

pub const Error = error{ NotReady, ToolMissing, NoLogs };

pub fn collect(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, lines: u32) Error![]const u8 {
    if (cand.state != .ready) return error.NotReady;
    return switch (cand.platform) {
        .ios => collectIos(arena, io, cand, lines),
        .android => collectAndroid(arena, io, env, cand, lines),
    };
}

fn collectAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate, lines: u32) Error![]const u8 {
    const adb = discovery.adbBin(arena, io, env) orelse return error.ToolMissing;
    const t = std.fmt.allocPrint(arena, "{d}", .{lines}) catch return error.NoLogs;
    const r = exec.capture(arena, io, &.{ adb, "-s", cand.id, "logcat", "-d", "-t", t }) orelse return error.ToolMissing;
    if (!r.ok()) return error.NoLogs;
    return r.stdout;
}

fn collectIos(arena: std.mem.Allocator, io: Io, cand: discovery.Candidate, lines: u32) Error![]const u8 {
    const r = exec.capture(arena, io, &.{
        "xcrun", "simctl", "spawn", cand.id, "log", "show", "--last", "2m", "--style", "compact",
    }) orelse return error.ToolMissing;
    if (!r.ok()) return error.NoLogs;
    return lastLines(r.stdout, lines);
}

/// 取文本末尾 n 行。
fn lastLines(text: []const u8, n: u32) []const u8 {
    if (n == 0 or text.len == 0) return text;
    var count: u32 = 0;
    var i: usize = text.len;
    // 跳过结尾换行
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
