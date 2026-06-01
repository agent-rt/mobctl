//! doctor —— 诊断 iOS / Android 工具链、SDK、依赖、可发现性。
//! 每项返回 status:ok|warn|fail + detail + 可选 fix（REQ §6.15）。
//!
//! 状态语义：缺某个平台的工具链 → warn（你可能只用另一平台）；
//! 工具链存在但坏了（如 xcrun 在但 simctl 跑不动）→ fail。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const exec = @import("../../shared/exec.zig");
const report = @import("../../shared/report.zig");
const discovery = @import("../../sim/discovery.zig");

const Check = report.Check;

/// 跑全部诊断检查并返回 checks 列表。doctor / report 共用。
pub fn gather(arena: std.mem.Allocator, io: Io, env: *const EnvMap) !std.ArrayList(Check) {
    var checks: std.ArrayList(Check) = .empty;

    // ---- iOS 工具链 ----
    if (exec.capture(arena, io, &.{ "xcrun", "simctl", "help" })) |r| {
        if (r.ok()) {
            try checks.append(arena, .{ .name = "ios.simctl", .status = .ok, .detail = "xcrun simctl available" });
            try checks.append(arena, iosRuntimes(arena, io));
        } else {
            try checks.append(arena, .{
                .name = "ios.simctl",
                .status = .fail,
                .detail = "xcrun present but `simctl` failed",
                .fix = "open Xcode once to finish setup, or run `xcode-select --install`",
            });
        }
    } else {
        try checks.append(arena, .{
            .name = "ios.simctl",
            .status = .warn,
            .detail = "xcrun/simctl not found — iOS simulators unavailable",
            .fix = "install Xcode (App Store) then `xcode-select --install`",
        });
    }

    // ---- iOS device（P1，仅探测可用性）----
    if (exec.capture(arena, io, &.{ "xcrun", "devicectl", "--version" })) |r| {
        const st: report.Status = if (r.ok()) .ok else .warn;
        try checks.append(arena, .{
            .name = "ios.devicectl",
            .status = st,
            .detail = if (r.ok()) "xcrun devicectl available (iOS device, P1)" else "devicectl present but errored",
        });
    } else {
        try checks.append(arena, .{ .name = "ios.devicectl", .status = .warn, .detail = "devicectl not found (iOS device support is P1)" });
    }

    // ---- Android SDK ----
    const sdk = env.get("ANDROID_HOME") orelse env.get("ANDROID_SDK_ROOT");
    if (sdk) |path| {
        try checks.append(arena, .{ .name = "android.sdk", .status = .ok, .detail = path });
    } else {
        try checks.append(arena, .{
            .name = "android.sdk",
            .status = .warn,
            .detail = "ANDROID_HOME / ANDROID_SDK_ROOT not set — Android emulators unavailable",
            .fix = "export ANDROID_HOME=~/Library/Android/sdk",
        });
    }

    // ---- Android emulator ----
    if (discovery.emulatorBin(arena, io, env)) |bin| {
        try checks.append(arena, .{ .name = "android.emulator", .status = .ok, .detail = bin });
    } else if (sdk != null) {
        try checks.append(arena, .{
            .name = "android.emulator",
            .status = .warn,
            .detail = "emulator binary not found under SDK",
            .fix = "install via Android Studio SDK Manager (Emulator package)",
        });
    }

    // ---- adb ----
    if (discovery.adbBin(arena, io, env)) |adb| {
        const ver = exec.capture(arena, io, &.{ adb, "version" });
        if (ver != null and ver.?.ok()) {
            try checks.append(arena, .{ .name = "android.adb", .status = .ok, .detail = adb });
        } else {
            try checks.append(arena, .{ .name = "android.adb", .status = .fail, .detail = "adb present but failed to run", .fix = "reinstall platform-tools" });
        }
    } else if (sdk != null) {
        try checks.append(arena, .{
            .name = "android.adb",
            .status = .warn,
            .detail = "adb not found under SDK/platform-tools",
            .fix = "install Platform-Tools via SDK Manager",
        });
    }

    // ---- 可发现性（信息项）----
    const cands = discovery.list(arena, io, env, null) catch &.{};
    try checks.append(arena, .{
        .name = "discovery",
        .status = if (cands.len > 0) .ok else .warn,
        .detail = std.fmt.allocPrint(arena, "{d} simulator candidate(s) discoverable", .{cands.len}) catch "discovery ran",
    });

    return checks;
}

/// 统计 checks 的 ok/warn/fail，返回 (summary 文本, 无 fail)。doctor / report 共用。
pub fn summarize(arena: std.mem.Allocator, checks: []const Check) struct { summary: []const u8, ok: bool } {
    var fails: usize = 0;
    var warns: usize = 0;
    for (checks) |c| switch (c.status) {
        .fail => fails += 1,
        .warn => warns += 1,
        .ok => {},
    };
    const summary = std.fmt.allocPrint(arena, "{d} ok, {d} warn, {d} fail", .{
        checks.len - fails - warns, warns, fails,
    }) catch "complete";
    return .{ .summary = summary, .ok = fails == 0 };
}

/// 返回 ok（无 fail）。调用方据此决定退出码。
pub fn run(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, json: bool) !bool {
    const checks = try gather(arena, io, env);
    const s = summarize(arena, checks.items);
    const rep = report.Report{ .ok = s.ok, .summary = s.summary, .checks = checks.items };

    if (json) {
        const j = try rep.toJson(arena, true);
        try w.writeAll(j);
        try w.writeByte('\n');
    } else {
        try rep.writeText(w);
    }
    return rep.ok;
}

fn iosRuntimes(arena: std.mem.Allocator, io: Io) Check {
    const r = exec.capture(arena, io, &.{ "xcrun", "simctl", "list", "runtimes", "-j" }) orelse
        return .{ .name = "ios.runtimes", .status = .warn, .detail = "could not query runtimes" };
    if (!r.ok()) return .{ .name = "ios.runtimes", .status = .warn, .detail = "simctl list runtimes failed" };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, r.stdout, .{}) catch
        return .{ .name = "ios.runtimes", .status = .warn, .detail = "could not parse runtimes" };
    var n: usize = 0;
    if (root.object.get("runtimes")) |rt| switch (rt) {
        .array => |a| for (a.items) |item| {
            const o = switch (item) {
                .object => |obj| obj,
                else => continue,
            };
            const avail = if (o.get("isAvailable")) |v| (v == .bool and v.bool) else false;
            if (avail) n += 1;
        },
        else => {},
    };
    return .{
        .name = "ios.runtimes",
        .status = if (n > 0) .ok else .warn,
        .detail = std.fmt.allocPrint(arena, "{d} available iOS runtime(s)", .{n}) catch "runtimes queried",
        .fix = if (n == 0) "install a runtime: Xcode > Settings > Components" else null,
    };
}
