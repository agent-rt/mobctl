//! sim 发现 —— 列出 Android Emulator / iOS Simulator 候选。
//!
//! iOS：`xcrun simctl list devices available -j`，解析 JSON。
//! Android：`<sdk>/emulator/emulator -list-avds` 列出 AVD，再用 `adb devices`
//!          + `adb -s <serial> emu avd name` 把运行中的实例关联回 AVD，
//!          升级其状态为 ready。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");

/// 列表项（REQ §6.1）。`state` 是统一枚举，`raw_state` 保留平台原始字符串。
pub const Candidate = struct {
    platform: envelope.Platform,
    name: []const u8,
    id: []const u8,
    state: envelope.State,
    raw_state: []const u8,
    is_default: bool = false,
    bootable: bool = true,
};

/// 列出全部 sim 候选；`platform_filter` 非 null 时只查该平台。
/// 单平台工具链缺失只是返回更少候选，不报错。
pub fn list(arena: std.mem.Allocator, io: Io, env: *const EnvMap, platform_filter: ?envelope.Platform) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    if (platform_filter == null or platform_filter == .ios)
        try collectIos(arena, io, &out);
    if (platform_filter == null or platform_filter == .android)
        try collectAndroid(arena, io, env, &out);
    return out.toOwnedSlice(arena);
}

// ---------------- iOS ----------------

fn mapIosState(s: []const u8) envelope.State {
    if (std.mem.eql(u8, s, "Booted")) return .ready;
    if (std.mem.eql(u8, s, "Shutdown")) return .available;
    if (std.mem.eql(u8, s, "Creating")) return .booting;
    if (std.mem.eql(u8, s, "Booting")) return .booting;
    return .unknown;
}

fn collectIos(arena: std.mem.Allocator, io: Io, out: *std.ArrayList(Candidate)) !void {
    const res = exec.capture(arena, io, &.{ "xcrun", "simctl", "list", "devices", "available", "-j" }) orelse return;
    if (!res.ok()) return;

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, res.stdout, .{}) catch return;
    const devices = (root.object.get("devices") orelse return).object;

    var it = devices.iterator();
    while (it.next()) |entry| {
        const arr = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |dev_val| {
            const dev = switch (dev_val) {
                .object => |o| o,
                else => continue,
            };
            const avail = if (dev.get("isAvailable")) |v| (v == .bool and v.bool) else false;
            if (!avail) continue;
            const name = if (dev.get("name")) |v| v.string else continue;
            const udid = if (dev.get("udid")) |v| v.string else continue;
            const raw = if (dev.get("state")) |v| v.string else "unknown";
            try out.append(arena, .{
                .platform = .ios,
                .name = name,
                .id = udid,
                .state = mapIosState(raw),
                .raw_state = raw,
                .bootable = true,
                .is_default = false,
            });
        }
    }
}

// ---------------- Android ----------------

fn androidSdkRoot(env: *const EnvMap) ?[]const u8 {
    return env.get("ANDROID_HOME") orelse env.get("ANDROID_SDK_ROOT");
}

/// 定位 emulator 可执行（新版在 emulator/，老版在 tools/）。boot 也复用。
pub fn emulatorBin(arena: std.mem.Allocator, io: Io, env: *const EnvMap) ?[]const u8 {
    const sdk = androidSdkRoot(env) orelse return null;
    const candidates = [_][]const u8{ "emulator/emulator", "tools/emulator" };
    for (candidates) |rel| {
        const p = std.fs.path.join(arena, &.{ sdk, rel }) catch continue;
        std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

/// 定位 adb 可执行。
pub fn adbBin(arena: std.mem.Allocator, io: Io, env: *const EnvMap) ?[]const u8 {
    const sdk = androidSdkRoot(env) orelse return null;
    const adb = std.fs.path.join(arena, &.{ sdk, "platform-tools/adb" }) catch return null;
    std.Io.Dir.accessAbsolute(io, adb, .{}) catch return null;
    return adb;
}

fn collectAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, out: *std.ArrayList(Candidate)) !void {
    const emu = emulatorBin(arena, io, env) orelse return;

    // 1) 列出 AVD —— 默认都是未运行（available）。
    const avds = exec.capture(arena, io, &.{ emu, "-list-avds" }) orelse return;
    if (!avds.ok()) return;
    var lines = std.mem.tokenizeScalar(u8, avds.stdout, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        try out.append(arena, .{
            .platform = .android,
            .name = name,
            .id = name, // AVD 名即标识符（未运行时没有 serial）
            .state = .available,
            .raw_state = "shutdown",
            .bootable = true,
        });
    }

    // 2) 用 adb 把运行中的实例关联回 AVD，升级状态为 ready。
    const adb = adbBin(arena, io, env) orelse return;
    const devs = exec.capture(arena, io, &.{ adb, "devices" }) orelse return;
    if (!devs.ok()) return;
    var dl = std.mem.tokenizeScalar(u8, devs.stdout, '\n');
    while (dl.next()) |line| {
        // 形如 "emulator-5554\tdevice"；跳过表头和非 emulator 行。
        if (!std.mem.startsWith(u8, line, "emulator-")) continue;
        var cols = std.mem.tokenizeAny(u8, line, " \t\r");
        const serial = cols.next() orelse continue;
        const st = cols.next() orelse continue;
        if (!std.mem.eql(u8, st, "device")) continue; // offline/unauthorized 不升级

        const avd_name = runningAvdName(arena, io, adb, serial) orelse continue;
        for (out.items) |*c| {
            if (c.platform == .android and std.mem.eql(u8, c.name, avd_name)) {
                c.state = .ready;
                c.raw_state = "device";
                c.id = arena.dupe(u8, serial) catch serial; // 运行时用 serial 作 id
            }
        }
    }
}

/// `adb -s <serial> emu avd name` 的首行就是 AVD 名（次行是 "OK"）。
fn runningAvdName(arena: std.mem.Allocator, io: Io, adb: []const u8, serial: []const u8) ?[]const u8 {
    const r = exec.capture(arena, io, &.{ adb, "-s", serial, "emu", "avd", "name" }) orelse return null;
    if (!r.ok()) return null;
    var it = std.mem.tokenizeAny(u8, r.stdout, "\r\n");
    const first = it.next() orelse return null;
    const name = std.mem.trim(u8, first, " \t\r");
    return if (name.len == 0) null else name;
}
