//! mobctl 统一错误模型 —— Zig 0.16 形态
//!
//! 背景：Zig 的 error 值是不可携带数据的纯枚举（error set），无法挂
//! `message` / `retryable` / `diagnostics`。而 REQ §8 / SPEC §8 要求每个
//! 错误进入统一信封时必须带这些字段。因此这里把"错误"拆成三层，各司其职：
//!
//!   1. `Error`     —— Zig error set，**只用于控制流**（`try` / `catch`）。
//!                     一个执行函数返回 `Error!T`，调用方用 `catch` 决策。
//!   2. `Kind`      —— 可穷举的错误分类（普通 enum），进 JSON 的 `error.kind`。
//!                     与 `Error` 一一对应，靠 `Kind.fromError` / `kind.toError`
//!                     互转。enum 而非 error set，因为它要能携带方法、能进信封、
//!                     能 `@tagName` 直接序列化成稳定字符串。
//!   3. `Info`      —— 携带 message / code / retryable / fatal / diagnostics 的
//!                     结构体，**这才是进信封 `error` 字段的东西**。
//!
//! 用法约定：
//!   - 内部失败用 `return error.BootTimeout;`（便宜、可 `try` 传播）。
//!   - 到信封边界时 `Info.fromError(err, .{ .message = "..." })` 兜成 `Info`。
//!   - 需要附带细分 code / 建议时直接构造 `Info{ ... }`。

const std = @import("std");

/// Zig error set —— 仅用于控制流。与 `Kind` 严格一一对应。
pub const Error = error{
    RuntimeMissing,
    DeviceNotFound,
    BootTimeout,
    ConnectTimeout,
    PermissionDenied,
    DependencyMissing,
    DeviceBusy,
    AlreadyRunning,
    AlreadyConnected,
    ShutdownFailed,
    ResetFailed,
    PairingFailed,
    TrustRequired,
    UnknownError,
};

/// 错误分类。进 JSON 时 `std.json` 直接把 tag 名写成字符串
/// （如 `.runtime_missing` → `"runtime_missing"`），正好就是 `error.kind`。
pub const Kind = enum {
    runtime_missing,
    device_not_found,
    boot_timeout,
    connect_timeout,
    permission_denied,
    dependency_missing,
    device_busy,
    already_running,
    already_connected,
    shutdown_failed,
    reset_failed,
    pairing_failed,
    trust_required,
    unknown_error,

    /// 默认是否可重试。`Info` 构造时取这个值作初值，调用方仍可覆盖
    /// （例如同一个 boot_timeout，首次可重试、第三次标 false）。
    pub fn defaultRetryable(self: Kind) bool {
        return switch (self) {
            .boot_timeout, .connect_timeout, .device_busy => true,
            // already_* 不是"失败"，是幂等命中，调用方通常当成功处理；
            // 真当错误抛时也不该重试。
            else => false,
        };
    }

    /// 是否致命：连 `doctor` / 重连都救不了，需要人工或环境介入。
    pub fn fatal(self: Kind) bool {
        return switch (self) {
            .runtime_missing,
            .dependency_missing,
            .permission_denied,
            .trust_required,
            => true,
            else => false,
        };
    }

    /// 进程退出码。Agent 不解析 JSON 时也能靠退出码粗分。
    pub fn exitCode(self: Kind) u8 {
        return switch (self) {
            .runtime_missing, .dependency_missing => 3,
            .permission_denied, .trust_required => 4,
            .device_not_found => 5,
            .boot_timeout, .connect_timeout => 6,
            .device_busy => 7,
            // already_* 视为成功路径，不该走到这里；保守给 0。
            .already_running, .already_connected => 0,
            else => 1,
        };
    }

    /// 默认细分 code（`Info.code` 的兜底值）。与 SPEC 示例里的
    /// `ios_runtime_not_found` / `adb_unauthorized` 这种平台细分码不同，
    /// 这是分类级的稳定字符串。
    pub fn defaultCode(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn fromError(err: Error) Kind {
        return switch (err) {
            error.RuntimeMissing => .runtime_missing,
            error.DeviceNotFound => .device_not_found,
            error.BootTimeout => .boot_timeout,
            error.ConnectTimeout => .connect_timeout,
            error.PermissionDenied => .permission_denied,
            error.DependencyMissing => .dependency_missing,
            error.DeviceBusy => .device_busy,
            error.AlreadyRunning => .already_running,
            error.AlreadyConnected => .already_connected,
            error.ShutdownFailed => .shutdown_failed,
            error.ResetFailed => .reset_failed,
            error.PairingFailed => .pairing_failed,
            error.TrustRequired => .trust_required,
            error.UnknownError => .unknown_error,
        };
    }

    pub fn toError(self: Kind) Error {
        return switch (self) {
            .runtime_missing => error.RuntimeMissing,
            .device_not_found => error.DeviceNotFound,
            .boot_timeout => error.BootTimeout,
            .connect_timeout => error.ConnectTimeout,
            .permission_denied => error.PermissionDenied,
            .dependency_missing => error.DependencyMissing,
            .device_busy => error.DeviceBusy,
            .already_running => error.AlreadyRunning,
            .already_connected => error.AlreadyConnected,
            .shutdown_failed => error.ShutdownFailed,
            .reset_failed => error.ResetFailed,
            .pairing_failed => error.PairingFailed,
            .trust_required => error.TrustRequired,
            .unknown_error => error.UnknownError,
        };
    }
};

/// 进信封 `error` 字段的富错误。所有字段都按 SPEC §7/§8 直接序列化。
/// 字符串字段都是借用（不持有内存）——通常指向 arena 或字面量，
/// 由信封的生命周期统一管理。
pub const Info = struct {
    /// 分类。序列化为 `"kind": "boot_timeout"`。
    kind: Kind,
    /// 细分 code，比 kind 更具体（`"adb_unauthorized"` / `"ios_runtime_not_found"`）。
    /// 默认取 `kind.defaultCode()`。
    code: []const u8,
    /// 人类 / Agent 可读的失败描述。
    message: []const u8,
    /// 是否值得重试。Agent 重试决策的主依据。
    retryable: bool,
    /// 是否致命（需环境/人工介入）。
    fatal: bool,
    /// 下一步建议。可空切片，序列化为 `[]`。
    diagnostics: []const []const u8 = &.{},

    /// 从 Kind 构造，retryable/fatal 取分类默认值。
    pub fn fromKind(kind: Kind, message: []const u8) Info {
        return .{
            .kind = kind,
            .code = kind.defaultCode(),
            .message = message,
            .retryable = kind.defaultRetryable(),
            .fatal = kind.fatal(),
        };
    }

    /// 从 Zig error 兜底构造（信封边界最常用）。
    pub fn fromError(err: Error, message: []const u8) Info {
        return fromKind(Kind.fromError(err), message);
    }
};

test "kind <-> error 往返一致" {
    inline for (std.meta.fields(Kind)) |f| {
        const k: Kind = @enumFromInt(f.value);
        try std.testing.expectEqual(k, Kind.fromError(k.toError()));
    }
}

test "Info 默认值取自分类" {
    const info = Info.fromError(error.BootTimeout, "boot 超时");
    try std.testing.expectEqual(Kind.boot_timeout, info.kind);
    try std.testing.expect(info.retryable); // boot_timeout 默认可重试
    try std.testing.expect(!info.fatal);
    try std.testing.expectEqualStrings("boot_timeout", info.code);
}

test "runtime_missing 致命且不可重试" {
    const info = Info.fromKind(.runtime_missing, "no sdk");
    try std.testing.expect(info.fatal);
    try std.testing.expect(!info.retryable);
    try std.testing.expectEqual(@as(u8, 3), info.kind.exitCode());
}
