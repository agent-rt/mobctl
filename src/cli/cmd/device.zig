//! device 子命令实现。已接线 `list`（Android 真机），其余待填。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const args = @import("../args.zig");
const envelope = @import("../../shared/envelope.zig");
const err = @import("../../shared/error.zig");
const exec = @import("../../shared/exec.zig");
const logfmt = @import("../../shared/logfmt.zig");
const discovery = @import("../../device/discovery.zig");
const wait_mod = @import("../../device/wait_ready.zig");
const handle_mod = @import("../../device/handle.zig");
const logs_mod = @import("../../device/logs.zig");
const connect_mod = @import("../../device/connect.zig");
const disconnect_mod = @import("../../device/disconnect.zig");

/// `mobctl device list`。文本表 / JSON。
pub fn list(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.ListOpts) !void {
    const candidates = try discovery.list(arena, io, env, opts.platform);

    if (opts.json) {
        const Listing = struct {
            schema_version: u32 = 1,
            command: []const u8 = "device list",
            count: usize,
            candidates: []const discovery.Candidate,
        };
        try std.json.Stringify.value(
            Listing{ .count = candidates.len, .candidates = candidates },
            .{ .whitespace = .indent_2 },
            w,
        );
        try w.writeByte('\n');
        return;
    }

    if (candidates.len == 0) {
        try w.writeAll("no physical devices found\n");
        return;
    }
    for (candidates) |c| {
        try w.print("{s:<8} {s:<11} {s:<6} {s:<5} {s}  ({s})\n", .{
            @tagName(c.platform),
            @tagName(c.state),
            c.connection_type,
            if (c.trusted) "trust" else "  -  ",
            c.name,
            c.id,
        });
    }
    try w.print("\n{d} device(s)\n", .{candidates.len});
}

// ---------------- selector 解析 + 信封 ----------------

const Resolution = union(enum) { one: discovery.Candidate, none, ambiguous: usize };

fn resolve(candidates: []const discovery.Candidate, selector: []const u8) Resolution {
    // selector 为空 → 只有一台真机时默认选中（REQ §5.2）。
    if (selector.len == 0) return switch (candidates.len) {
        0 => .none,
        1 => .{ .one = candidates[0] },
        else => .{ .ambiguous = candidates.len },
    };
    for (candidates) |c| {
        if (std.mem.eql(u8, c.id, selector)) return .{ .one = c };
    }
    var hit: ?discovery.Candidate = null;
    var count: usize = 0;
    for (candidates) |c| {
        if (std.mem.eql(u8, c.name, selector)) {
            hit = c;
            count += 1;
        }
    }
    return switch (count) {
        0 => .none,
        1 => .{ .one = hit.? },
        else => .{ .ambiguous = count },
    };
}

fn emit(w: *Io.Writer, json: bool, e: envelope.Envelope, arena: std.mem.Allocator) !void {
    if (json) {
        const s = try e.toJson(arena, true);
        try w.writeAll(s);
        try w.writeByte('\n');
    } else if (e.success) {
        try w.print("{s}  {s} [device]  state={s}\n", .{ @tagName(e.platform), e.device_id, @tagName(e.state) });
        if (e.handle) |h| try w.print("  handle: {s} ({s})\n", .{ h.connection_hint, h.transport });
        for (e.diagnostics) |d| try w.print("  - {s}\n", .{d});
    } else {
        const info = e.@"error".?;
        try w.print("FAILED [{s}] {s}\n", .{ @tagName(info.kind), info.message });
        for (info.diagnostics) |d| try w.print("  - {s}\n", .{d});
    }
}

fn notFound(command: []const u8, selector: []const u8) envelope.Envelope {
    return .{
        .success = false,
        .command = command,
        .kind = .device,
        .platform = .android,
        .device_id = selector,
        .state = .unknown,
        .@"error" = err.Info.fromKind(.device_not_found, "no device matched the selector"),
    };
}

fn ambiguous(arena: std.mem.Allocator, command: []const u8, selector: []const u8, n: usize) envelope.Envelope {
    const msg = std.fmt.allocPrint(arena, "{d} devices share this name; disambiguate with the serial", .{n}) catch "ambiguous selector";
    var info = err.Info.fromKind(.unknown_error, msg);
    info.code = "ambiguous_selector";
    return .{ .success = false, .command = command, .kind = .device, .platform = .android, .device_id = selector, .state = .unknown, .@"error" = info };
}

/// `mobctl device status <selector>`。
pub fn status(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const e: envelope.Envelope = switch (resolve(candidates, opts.selector)) {
        .none => notFound("device status", opts.selector),
        .ambiguous => |n| ambiguous(arena, "device status", opts.selector, n),
        .one => |c| .{
            .success = true,
            .command = "device status",
            .kind = .device,
            .platform = c.platform,
            .device_id = c.id,
            .state = c.state,
            .raw_state = c.raw_state,
        },
    };
    try emit(w, opts.json, e, arena);
}

/// `mobctl device wait-ready <selector> [--timeout <s>]`。
pub fn waitReady(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("device wait-ready", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "device wait-ready", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };

    const r = wait_mod.waitReady(arena, io, env, cand.id, opts.timeout_ms);
    try emit(w, opts.json, waitEnvelope(arena, io, env, "device wait-ready", cand, r), arena);
}

/// 把 wait 结果包成信封（wait-ready / ensure 共用）。
/// ready→success+handle；blocked→对应 error.kind；超时→connect_timeout。
fn waitEnvelope(arena: std.mem.Allocator, io: Io, env: *const EnvMap, command: []const u8, cand: discovery.Candidate, r: wait_mod.Result) envelope.Envelope {
    var e: envelope.Envelope = .{
        .success = r.ready,
        .command = command,
        .kind = .device,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = r.state,
        .elapsed_ms = r.elapsed_ms,
        .diagnostics = r.evidence,
    };
    if (r.ready) {
        e.handle = handle_mod.forDevice(arena, io, env, cand, true);
    } else if (r.blocked) |k| {
        e.@"error" = err.Info.fromKind(k, "device blocked from reaching ready");
    } else if (r.timed_out) {
        e.@"error" = err.Info.fromKind(.connect_timeout, "device did not reach ready within timeout");
    }
    return e;
}

/// `mobctl device ensure <selector>` —— 真机幂等主入口。真机无 boot：
/// 已 ready 直接复用，否则 wait-ready（unauthorized 等阻断显式上报）。
pub fn ensure(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("device ensure", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "device ensure", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };

    if (cand.state == .ready) {
        const e: envelope.Envelope = .{
            .success = true,
            .command = "device ensure",
            .kind = .device,
            .platform = cand.platform,
            .device_id = cand.id,
            .state = .ready,
            .raw_state = cand.raw_state,
            .handle = handle_mod.forDevice(arena, io, env, cand, true),
            .warnings = dupStr(arena, "already_connected"),
            .diagnostics = dupStr(arena, "already ready; reused"),
        };
        try emit(w, opts.json, e, arena);
        return;
    }

    const r = wait_mod.waitReady(arena, io, env, cand.id, opts.timeout_ms);
    try emit(w, opts.json, waitEnvelope(arena, io, env, "device ensure", cand, r), arena);
}

/// `mobctl device handle <selector>` —— 导出稳定句柄。
pub fn handle(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("device handle", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "device handle", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const e: envelope.Envelope = .{
        .success = true,
        .command = "device handle",
        .kind = .device,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = cand.state,
        .raw_state = cand.raw_state,
        .handle = handle_mod.forDevice(arena, io, env, cand, cand.state == .ready),
    };
    try emit(w, opts.json, e, arena);
}

fn dupStr(arena: std.mem.Allocator, s: []const u8) []const []const u8 {
    const one = arena.alloc([]const u8, 1) catch return &.{};
    one[0] = s;
    return one;
}

/// `mobctl device connect <ip[:port]>` —— wifi 连接（target 是地址，不经发现解析）。
pub fn connect(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    if (opts.selector.len == 0) {
        var e = notFound("device connect", "");
        e.@"error" = err.Info.fromKind(.device_not_found, "connect requires an address, e.g. `device connect 192.168.1.42:5555`");
        try emit(w, opts.json, e, arena);
        return;
    }
    const oc = connect_mod.connect(arena, io, env, opts.selector) orelse {
        var fail = notFound("device connect", opts.selector);
        fail.@"error" = err.Info.fromKind(.dependency_missing, "adb not found");
        try emit(w, opts.json, fail, arena);
        return;
    };
    var e: envelope.Envelope = .{
        .success = oc.ok,
        .command = "device connect",
        .kind = .device,
        .platform = .android,
        .device_id = oc.serial,
        .state = oc.state,
        .diagnostics = dupStr(arena, oc.message),
        .warnings = if (oc.already) dupStr(arena, "already_connected") else &.{},
    };
    if (oc.ok) {
        e.handle = .{
            .transport = "adb",
            .connection_hint = std.fmt.allocPrint(arena, "adb:{s}", .{oc.serial}) catch oc.serial,
            .connection_type = "wifi",
        };
    } else {
        e.@"error" = err.Info.fromKind(.connect_timeout, "adb connect failed");
    }
    try emit(w, opts.json, e, arena);
}

/// `mobctl device disconnect <serial>` —— 断开 wifi 连接。
pub fn disconnect(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    if (opts.selector.len == 0) {
        var e = notFound("device disconnect", "");
        e.@"error" = err.Info.fromKind(.device_not_found, "disconnect requires a serial, e.g. `device disconnect 192.168.1.42:5555`");
        try emit(w, opts.json, e, arena);
        return;
    }
    const oc = disconnect_mod.disconnect(arena, io, env, opts.selector) orelse {
        var fail = notFound("device disconnect", opts.selector);
        fail.@"error" = err.Info.fromKind(.dependency_missing, "adb not found");
        try emit(w, opts.json, fail, arena);
        return;
    };
    var e: envelope.Envelope = .{
        .success = oc.ok,
        .command = "device disconnect",
        .kind = .device,
        .platform = .android,
        .device_id = opts.selector,
        .state = oc.state,
        .diagnostics = dupStr(arena, oc.message),
    };
    if (!oc.ok) e.@"error" = err.Info.fromKind(.unknown_error, "adb disconnect failed");
    try emit(w, opts.json, e, arena);
}

/// `mobctl device logs [selector] [-f] [--lines N] [--grep S] [--pid N] [--package P] [--tag T] [--json]`。
pub fn logs(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("device logs", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "device logs", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const f: logs_mod.Filter = .{
        .follow = opts.follow,
        .lines = opts.lines,
        .pid = opts.pid,
        .package = opts.package,
        .tag = opts.tag,
        .level = opts.level,
    };
    const argv = logs_mod.prepare(arena, io, env, cand, f) catch |e| {
        const kind: err.Kind = switch (e) {
            error.NotReady => .device_busy,
            error.ToolMissing => .dependency_missing,
            error.OutOfMemory => .unknown_error,
        };
        var fail = notFound("device logs", cand.id);
        fail.platform = cand.platform;
        var info = err.Info.fromKind(kind, "could not collect logs");
        if (kind == .device_busy) info.diagnostics = dupStr(arena, "device not ready (unauthorized/offline?); authorize it first");
        fail.@"error" = info;
        try emit(w, opts.json, fail, arena);
        return;
    };
    // 真机恒为 Android：JSON→结构化记录；TTY/--color→pretty 着色对齐（借鉴 pidcat）。
    const tty = std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false;
    var printer: logfmt.Printer = .{
        .format = logfmt.chooseFormat(opts.json, true, tty, opts.color),
        .width = opts.width orelse 100,
    };
    printer.color = printer.format == .pretty;
    exec.streamLogs(io, argv, w, opts.grep, &printer);
}
