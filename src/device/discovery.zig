//! device 发现 —— 列出真机候选（MVP：Android 真机）。
//!
//! Android：`adb devices -l`，**排除 emulator-\*（那是 sim 子域的东西）**。
//! 区分 device / unauthorized / offline（SPEC §6.1：不得和普通失败混淆），
//! 原始 adb 状态保留在 `raw_state`。
//!
//! iOS 真机为 P1，未实现（见 mvp-scope）。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const envelope = @import("../shared/envelope.zig");
const exec = @import("../shared/exec.zig");
const sim_discovery = @import("../sim/discovery.zig");

/// 真机列表项（REQ §6.7）。
pub const Candidate = struct {
    platform: envelope.Platform,
    name: []const u8,
    id: []const u8,
    connection_type: []const u8, // usb | wifi
    state: envelope.State,
    raw_state: []const u8,
    trusted: bool,
};

pub fn list(arena: std.mem.Allocator, io: Io, env: *const EnvMap, platform_filter: ?envelope.Platform) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    if (platform_filter == null or platform_filter == .android)
        try collectAndroid(arena, io, env, &out);
    // iOS 真机 P1：未实现，platform_filter == .ios 时返回空。
    return out.toOwnedSlice(arena);
}

fn collectAndroid(arena: std.mem.Allocator, io: Io, env: *const EnvMap, out: *std.ArrayList(Candidate)) !void {
    const adb = sim_discovery.adbBin(arena, io, env) orelse return;
    const res = exec.capture(arena, io, &.{ adb, "devices", "-l" }) orelse return;
    if (!res.ok()) return;
    try parseDevices(arena, res.stdout, out);
}

/// 纯解析：把 `adb devices -l` 的输出解析成候选，排除 emulator。
/// 抽出来是为了在没有真机时也能单测。
pub fn parseDevices(arena: std.mem.Allocator, raw: []const u8, out: *std.ArrayList(Candidate)) !void {
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "List of devices")) continue;
        if (std.mem.startsWith(u8, trimmed, "*")) continue; // adb daemon 启动噪声

        var toks = std.mem.tokenizeAny(u8, trimmed, " \t");
        const serial = toks.next() orelse continue;
        if (std.mem.startsWith(u8, serial, "emulator-")) continue; // 真机才进 device 子域
        const raw_state = toks.next() orelse continue;

        // 余下 token 里找 model:<name>
        var name: []const u8 = serial;
        while (toks.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "model:")) {
                const v = kv["model:".len..];
                if (v.len > 0) name = v;
            }
        }

        try out.append(arena, .{
            .platform = .android,
            .name = name,
            .id = serial,
            .connection_type = if (std.mem.indexOfScalar(u8, serial, ':') != null) "wifi" else "usb",
            .state = mapState(raw_state),
            .raw_state = raw_state,
            .trusted = std.mem.eql(u8, raw_state, "device"),
        });
    }
}

/// adb 状态 → 统一枚举（精确语义保留在 raw_state）。
fn mapState(s: []const u8) envelope.State {
    if (std.mem.eql(u8, s, "device")) return .ready;
    if (std.mem.eql(u8, s, "unauthorized")) return .connecting; // 等待用户授权
    if (std.mem.eql(u8, s, "offline")) return .disabled; // 传输在但无响应
    if (std.mem.eql(u8, s, "recovery") or std.mem.eql(u8, s, "sideload") or std.mem.eql(u8, s, "bootloader"))
        return .busy;
    return .unknown;
}

test "parseDevices: usb device, wifi, unauthorized, offline; emulator excluded" {
    const raw =
        \\List of devices attached
        \\* daemon started successfully
        \\1A2B3C4D5E         device product:flame model:Pixel_4 device:flame transport_id:3
        \\192.168.1.42:5555  device product:bullhead model:Pixel_8 device:bullhead transport_id:4
        \\F00DBEEF           unauthorized transport_id:5
        \\DEADBEEF           offline transport_id:6
        \\emulator-5554      device product:sdk model:sdk device:emu64a transport_id:7
        \\
    ;
    var out: std.ArrayList(Candidate) = .empty;
    try parseDevices(std.testing.allocator, raw, &out);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), out.items.len); // emulator 被排除

    try std.testing.expectEqualStrings("Pixel_4", out.items[0].name);
    try std.testing.expectEqualStrings("usb", out.items[0].connection_type);
    try std.testing.expectEqual(envelope.State.ready, out.items[0].state);
    try std.testing.expect(out.items[0].trusted);

    try std.testing.expectEqualStrings("wifi", out.items[1].connection_type);
    try std.testing.expectEqualStrings("192.168.1.42:5555", out.items[1].id);

    try std.testing.expectEqual(envelope.State.connecting, out.items[2].state); // unauthorized
    try std.testing.expect(!out.items[2].trusted);

    try std.testing.expectEqual(envelope.State.disabled, out.items[3].state); // offline
}
