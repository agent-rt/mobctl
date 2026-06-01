//! 参数解析 —— argv → 结构化 `Command`。不塞业务逻辑，只做路由前的解析。
//! 当前覆盖 `mobctl sim list [--platform android|ios] [--json]`，其余子命令
//! 解析成 `.unknown` 占位，等实现接线时填充。

const std = @import("std");
const envelope = @import("../shared/envelope.zig");

pub const ListOpts = struct {
    platform: ?envelope.Platform = null,
    json: bool = false,
};

pub const ReportFormat = enum { json, ndjson, md };

/// 针对单个目标的命令共用选项：selector（id 或 name）+ json + 超时。
pub const TargetOpts = struct {
    selector: []const u8,
    json: bool = false,
    /// ready 等待超时（毫秒）。默认 120s。
    timeout_ms: u64 = 120_000,
    /// shutdown 是否强制。
    force: bool = false,
    /// logs 采集行数上限。
    lines: u32 = 200,
};

pub const Command = union(enum) {
    sim_list: ListOpts,
    sim_status: TargetOpts,
    sim_boot: TargetOpts,
    sim_wait_ready: TargetOpts,
    sim_ensure: TargetOpts,
    sim_shutdown: TargetOpts,
    sim_handle: TargetOpts,
    sim_reset: TargetOpts,
    sim_logs: TargetOpts,
    device_list: ListOpts,
    device_status: TargetOpts,
    device_wait_ready: TargetOpts,
    device_ensure: TargetOpts,
    device_handle: TargetOpts,
    device_logs: TargetOpts,
    device_connect: TargetOpts,
    device_disconnect: TargetOpts,
    doctor: bool, // json?
    report: ReportFormat,
    help,
    /// 未识别 / 未实现的子命令，带上原始 token 供报错。
    unknown: []const u8,
};

fn parsePlatform(s: []const u8) ?envelope.Platform {
    if (std.mem.eql(u8, s, "android")) return .android;
    if (std.mem.eql(u8, s, "ios")) return .ios;
    return null;
}

/// 解析 `<selector> [--json] [--timeout <seconds>]`；缺 selector 返回 null。
fn parseTarget(rest: []const []const u8) ?TargetOpts {
    var opts: TargetOpts = .{ .selector = "" };
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            if (i + 1 < rest.len) {
                if (std.fmt.parseInt(u64, rest[i + 1], 10)) |secs| {
                    opts.timeout_ms = secs * 1000;
                } else |_| {}
                i += 1;
            }
        } else if (std.mem.eql(u8, a, "--lines")) {
            if (i + 1 < rest.len) {
                if (std.fmt.parseInt(u32, rest[i + 1], 10)) |n| {
                    opts.lines = n;
                } else |_| {}
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, a, "-") and opts.selector.len == 0) {
            opts.selector = a;
        }
    }
    return if (opts.selector.len == 0) null else opts;
}

/// `args` 是去掉程序名后的 argv（即 `argv[1..]`）。
pub fn parse(args: []const []const u8) Command {
    if (args.len == 0) return .help;
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return .help;

    if (std.mem.eql(u8, args[0], "doctor")) {
        var json = false;
        for (args[1..]) |a| {
            if (std.mem.eql(u8, a, "--json")) json = true;
        }
        return .{ .doctor = json };
    }

    if (std.mem.eql(u8, args[0], "report")) {
        var fmt: ReportFormat = .json;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                const f = args[i + 1];
                if (std.mem.eql(u8, f, "ndjson")) fmt = .ndjson;
                if (std.mem.eql(u8, f, "md")) fmt = .md;
                if (std.mem.eql(u8, f, "json")) fmt = .json;
                i += 1;
            }
        }
        return .{ .report = fmt };
    }

    if (std.mem.eql(u8, args[0], "sim")) {
        if (args.len < 2) return .{ .unknown = "sim" };
        if (std.mem.eql(u8, args[1], "list")) {
            return .{ .sim_list = parseListOpts(args[2..]) };
        }
        const sub = args[1];
        const is_target = std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "boot") or
            std.mem.eql(u8, sub, "wait-ready") or std.mem.eql(u8, sub, "ensure") or
            std.mem.eql(u8, sub, "shutdown") or std.mem.eql(u8, sub, "handle") or
            std.mem.eql(u8, sub, "reset") or std.mem.eql(u8, sub, "logs");
        if (is_target) {
            const opts = parseTarget(args[2..]) orelse return .{ .unknown = sub };
            if (std.mem.eql(u8, sub, "status")) return .{ .sim_status = opts };
            if (std.mem.eql(u8, sub, "boot")) return .{ .sim_boot = opts };
            if (std.mem.eql(u8, sub, "wait-ready")) return .{ .sim_wait_ready = opts };
            if (std.mem.eql(u8, sub, "ensure")) return .{ .sim_ensure = opts };
            if (std.mem.eql(u8, sub, "shutdown")) return .{ .sim_shutdown = opts };
            if (std.mem.eql(u8, sub, "handle")) return .{ .sim_handle = opts };
            if (std.mem.eql(u8, sub, "reset")) return .{ .sim_reset = opts };
            return .{ .sim_logs = opts };
        }
        return .{ .unknown = sub };
    }

    if (std.mem.eql(u8, args[0], "device")) {
        if (args.len < 2) return .{ .unknown = "device" };
        const sub = args[1];
        if (std.mem.eql(u8, sub, "list")) return .{ .device_list = parseListOpts(args[2..]) };
        const is_target = std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "wait-ready") or
            std.mem.eql(u8, sub, "ensure") or std.mem.eql(u8, sub, "handle") or std.mem.eql(u8, sub, "logs") or
            std.mem.eql(u8, sub, "connect") or std.mem.eql(u8, sub, "disconnect");
        if (is_target) {
            const opts = parseTarget(args[2..]) orelse return .{ .unknown = sub };
            if (std.mem.eql(u8, sub, "status")) return .{ .device_status = opts };
            if (std.mem.eql(u8, sub, "wait-ready")) return .{ .device_wait_ready = opts };
            if (std.mem.eql(u8, sub, "ensure")) return .{ .device_ensure = opts };
            if (std.mem.eql(u8, sub, "handle")) return .{ .device_handle = opts };
            if (std.mem.eql(u8, sub, "logs")) return .{ .device_logs = opts };
            if (std.mem.eql(u8, sub, "connect")) return .{ .device_connect = opts };
            return .{ .device_disconnect = opts };
        }
        return .{ .unknown = sub };
    }

    return .{ .unknown = args[0] };
}

/// 解析 list 类命令的 `[--platform android|ios] [--json]`。
fn parseListOpts(rest: []const []const u8) ListOpts {
    var opts: ListOpts = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--platform")) {
            if (i + 1 < rest.len) {
                opts.platform = parsePlatform(rest[i + 1]);
                i += 1;
            }
        }
    }
    return opts;
}

test "parse sim list with flags" {
    const c = parse(&.{ "sim", "list", "--platform", "ios", "--json" });
    try std.testing.expect(c == .sim_list);
    try std.testing.expectEqual(envelope.Platform.ios, c.sim_list.platform.?);
    try std.testing.expect(c.sim_list.json);
}

test "parse bare sim list defaults" {
    const c = parse(&.{ "sim", "list" });
    try std.testing.expect(c == .sim_list);
    try std.testing.expect(c.sim_list.platform == null);
    try std.testing.expect(!c.sim_list.json);
}

test "parse unknown subcommand" {
    const c = parse(&.{ "frobnicate" });
    try std.testing.expect(c == .unknown);
}

test "parse sim boot / status with selector" {
    const b = parse(&.{ "sim", "boot", "Pixel_8_API_35", "--json" });
    try std.testing.expect(b == .sim_boot);
    try std.testing.expectEqualStrings("Pixel_8_API_35", b.sim_boot.selector);
    try std.testing.expect(b.sim_boot.json);

    const s = parse(&.{ "sim", "status", "emulator-5554" });
    try std.testing.expect(s == .sim_status);
    try std.testing.expectEqualStrings("emulator-5554", s.sim_status.selector);
    try std.testing.expect(!s.sim_status.json);
}

test "parse sim boot without selector is unknown" {
    const c = parse(&.{ "sim", "boot" });
    try std.testing.expect(c == .unknown);
}
