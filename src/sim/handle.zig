//! sim 句柄导出（handle-fields 定稿）。
//!
//! 必选：transport / connection_hint（身份字段由 cmd 放信封顶层）。
//! 平台可选：ready_at（已 ready）、runtime（iOS 版本 / Android release）、
//! app_container_hint（仅 iOS sim）。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const discovery = @import("discovery.zig");

pub fn forSim(arena: std.mem.Allocator, io: Io, env: *const EnvMap, cand: discovery.Candidate) envelope.Handle {
    const ready = cand.state == .ready;
    return switch (cand.platform) {
        .ios => .{
            .transport = "simctl",
            .connection_hint = std.fmt.allocPrint(arena, "xcrun simctl {s}", .{cand.id}) catch "xcrun simctl",
            .ready_at = if (ready) "now" else null,
            .runtime = iosRuntime(arena, io, cand.id),
            .app_container_hint = if (ready) "booted" else null,
        },
        .android => blk: {
            const running = std.mem.startsWith(u8, cand.id, "emulator-");
            break :blk .{
                .transport = "adb",
                .connection_hint = if (running)
                    (std.fmt.allocPrint(arena, "adb:{s}", .{cand.id}) catch "adb")
                else
                    "adb (not running)",
                .ready_at = if (ready) "now" else null,
                .runtime = if (running) androidRelease(arena, io, env, cand.id) else null,
            };
        },
    };
}

/// 从 simctl JSON 里找出该 udid 所属的 runtime 标识，prettify 成 "iOS 26.4"。
fn iosRuntime(arena: std.mem.Allocator, io: Io, udid: []const u8) ?[]const u8 {
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
            if (std.mem.eql(u8, id, udid)) return prettyRuntime(arena, entry.key_ptr.*);
        }
    }
    return null;
}

/// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" → "iOS 26.4"
fn prettyRuntime(arena: std.mem.Allocator, key: []const u8) []const u8 {
    const marker = "SimRuntime.";
    const idx = std.mem.lastIndexOf(u8, key, marker) orelse return key;
    const tail = key[idx + marker.len ..]; // "iOS-26-4"
    const buf = arena.dupe(u8, tail) catch return tail;
    // 第一个 '-' 变空格（iOS-26 → iOS 26），其余 '-' 变 '.'（26-4 → 26.4）。
    var seen_space = false;
    for (buf) |*ch| {
        if (ch.* == '-') {
            if (!seen_space) {
                ch.* = ' ';
                seen_space = true;
            } else ch.* = '.';
        }
    }
    return buf;
}

fn androidRelease(arena: std.mem.Allocator, io: Io, env: *const EnvMap, serial: []const u8) ?[]const u8 {
    const adb = discovery.adbBin(arena, io, env) orelse return null;
    const r = exec.capture(arena, io, &.{ adb, "-s", serial, "shell", "getprop", "ro.build.version.release" }) orelse return null;
    if (!r.ok()) return null;
    const v = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (v.len == 0) return null;
    return std.fmt.allocPrint(arena, "Android {s}", .{v}) catch null;
}
