//! 统一输出信封 —— SPEC §7。所有命令的结构化返回都用 `Envelope`。
//!
//! 设计：直接靠 `std.json.Stringify.value` 默认序列化。字段名即 JSON 键，
//! enum 字段自动写成 `@tagName` 字符串（`state` / `kind` / `platform` 因此
//! 天然满足"必须是枚举，不可自由文本漂移"）。序列化时传
//! `.emit_null_optional_fields = false`，让成功路径省略 `error`、失败路径
//! 省略 `handle`，与 SPEC 示例一致。

const std = @import("std");
const err = @import("error.zig");

pub const Kind = enum { sim, device };
pub const Platform = enum { android, ios };

/// 统一设备状态（SPEC §3.2）。平台原始态另放 `raw_state`，不污染这个枚举。
pub const State = enum {
    unknown,
    not_installed,
    available,
    connecting,
    booting,
    ready,
    busy,
    stopped,
    failed,
    disabled,
};

/// 稳定句柄（REQ §6.14 / SPEC §3.3）。身份字段（kind/platform/device_id/
/// state/schema_version）在信封顶层，这里只放连接 / 运行时线索。
///
/// 字段分两层：
///   - **必选**（无默认值，构造时强制提供）：`transport` / `connection_hint`。
///   - **平台 / kind 可选**（默认 null，序列化省略）：其余字段，只在该平台
///     真正适用时填，避免给 Agent 喂 `"pairing_state": null` 这种噪音。
pub const Handle = struct {
    // —— 必选 ——
    transport: []const u8, // adb | simctl | devicectl
    connection_hint: []const u8, // downstream 可直接消费的连接线索
    // —— 平台 / kind 可选 ——
    ready_at: ?[]const u8 = null, // 已 ready 的时刻（RFC3339）
    process_pid: ?u32 = null, // 有宿主进程的 sim
    runtime: ?[]const u8 = null, // iOS runtime 版本 / Android API level
    connection_type: ?[]const u8 = null, // usb | wifi | virtual（仅 device）
    pairing_state: ?[]const u8 = null, // 仅 iOS device
    trust_state: ?[]const u8 = null, // 仅 iOS device
    app_container_hint: ?[]const u8 = null, // 仅 iOS sim
};

/// 证据落盘项（SPEC §9.1）。`type` 取 log/json/ndjson/text/trace。
pub const Artifact = struct {
    type: []const u8,
    path: []const u8,
};

pub const Envelope = struct {
    schema_version: u32 = 1,
    success: bool,
    command: []const u8,
    kind: Kind,
    platform: Platform,
    device_id: []const u8,
    state: State,
    elapsed_ms: u64 = 0,
    /// 平台原始状态（如 android `"unauthorized"`、ios `"Booted"`）。
    /// 统一 `state` 已枚举化，这里保留平台语义供排障，可空即省略。
    raw_state: ?[]const u8 = null,
    handle: ?Handle = null,
    // `error` 是 Zig 关键字，字段名用 @"error"，序列化后键仍是 "error"。
    @"error": ?err.Info = null,
    warnings: []const []const u8 = &.{},
    artifacts: []const Artifact = &.{},
    diagnostics: []const []const u8 = &.{},

    /// 序列化成 JSON 字符串。返回的 slice 归调用方所有（用 `alloc` 释放）。
    pub fn toJson(self: Envelope, alloc: std.mem.Allocator, pretty: bool) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try std.json.Stringify.value(self, .{
            .whitespace = if (pretty) .indent_2 else .minified,
            .emit_null_optional_fields = false,
        }, &aw.writer);
        return aw.toOwnedSlice();
    }
};

test "成功信封省略 error 字段" {
    const e = Envelope{
        .success = true,
        .command = "ensure",
        .kind = .sim,
        .platform = .android,
        .device_id = "Pixel_7_API_34",
        .state = .ready,
        .elapsed_ms = 18432,
        .handle = .{ .transport = "adb", .connection_hint = "adb:emulator-5554", .process_pid = 12345 },
    };
    const s = try e.toJson(std.testing.allocator, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"state\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"pairing_state\"") == null);
}

test "失败信封省略 handle、带 error.kind" {
    const e = Envelope{
        .success = false,
        .command = "connect",
        .kind = .device,
        .platform = .ios,
        .device_id = "iPhone 15",
        .state = .failed,
        .@"error" = err.Info.fromKind(.runtime_missing, "Requested iOS runtime is not installed"),
    };
    const s = try e.toJson(std.testing.allocator, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"error\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"kind\":\"runtime_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"retryable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"handle\"") == null);
}
