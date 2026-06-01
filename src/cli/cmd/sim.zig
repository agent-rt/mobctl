//! sim 子命令实现。已接线 `list` / `status` / `boot`，其余待填。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const args = @import("../args.zig");
const envelope = @import("../../shared/envelope.zig");
const err = @import("../../shared/error.zig");
const discovery = @import("../../sim/discovery.zig");
const boot_mod = @import("../../sim/boot.zig");
const wait_mod = @import("../../sim/wait_ready.zig");
const shutdown_mod = @import("../../sim/shutdown.zig");
const handle_mod = @import("../../sim/handle.zig");
const reset_mod = @import("../../sim/reset.zig");
const logs_mod = @import("../../sim/logs.zig");

/// `mobctl sim list`。把候选写到 `w`（文本表或 JSON）。
pub fn list(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, w: *Io.Writer, opts: args.ListOpts) !void {
    const candidates = try discovery.list(arena, io, env, opts.platform);

    if (opts.json) {
        const Listing = struct {
            schema_version: u32 = 1,
            command: []const u8 = "sim list",
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

    // 文本视图：每行 `平台  状态  名称  (id)`。
    if (candidates.len == 0) {
        try w.writeAll("no simulators found\n");
        return;
    }
    for (candidates) |c| {
        try w.print("{s:<8} {s:<10} {s}  ({s})\n", .{
            @tagName(c.platform),
            @tagName(c.state),
            c.name,
            c.id,
        });
    }
    try w.print("\n{d} simulator(s)\n", .{candidates.len});
}

// ---------------- selector 解析 ----------------

const Resolution = union(enum) {
    one: discovery.Candidate,
    none,
    /// 多个候选命中（如 iOS 同名设备跨 runtime）；带命中数。
    ambiguous: usize,
};

/// 先按 id 精确匹配（唯一），否则按 name 匹配（可能多个）。
fn resolve(candidates: []const discovery.Candidate, selector: []const u8) Resolution {
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

fn emit(w: *Io.Writer, env_json: bool, e: envelope.Envelope, arena: std.mem.Allocator) !void {
    if (env_json) {
        const s = try e.toJson(arena, true);
        try w.writeAll(s);
        try w.writeByte('\n');
    } else {
        if (e.success) {
            try w.print("{s}  {s} [{s}]  state={s}\n", .{
                @tagName(e.platform), e.device_id, @tagName(e.kind), @tagName(e.state),
            });
            if (e.handle) |h| try w.print("  handle: {s} ({s})\n", .{ h.connection_hint, h.transport });
            for (e.diagnostics) |d| try w.print("  - {s}\n", .{d});
        } else {
            const info = e.@"error".?;
            try w.print("FAILED [{s}] {s}\n", .{ @tagName(info.kind), info.message });
            for (info.diagnostics) |d| try w.print("  - {s}\n", .{d});
        }
    }
}

fn notFound(command: []const u8, selector: []const u8) envelope.Envelope {
    return .{
        .success = false,
        .command = command,
        .kind = .sim,
        .platform = .ios, // 占位；未匹配时平台未知
        .device_id = selector,
        .state = .unknown,
        .@"error" = err.Info.fromKind(.device_not_found, "no simulator matched the selector"),
    };
}

fn ambiguous(arena: std.mem.Allocator, command: []const u8, selector: []const u8, n: usize) envelope.Envelope {
    const msg = std.fmt.allocPrint(arena, "{d} simulators share this name; disambiguate with the udid/id", .{n}) catch "ambiguous selector";
    var info = err.Info.fromKind(.unknown_error, msg);
    info.code = "ambiguous_selector";
    return .{
        .success = false,
        .command = command,
        .kind = .sim,
        .platform = .ios,
        .device_id = selector,
        .state = .unknown,
        .@"error" = info,
    };
}

/// `mobctl sim status <selector>`。
pub fn status(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const e: envelope.Envelope = switch (resolve(candidates, opts.selector)) {
        .none => notFound("sim status", opts.selector),
        .ambiguous => |n| ambiguous(arena, "sim status", opts.selector, n),
        .one => |c| .{
            .success = true,
            .command = "sim status",
            .kind = .sim,
            .platform = c.platform,
            .device_id = c.id,
            .state = c.state,
            .raw_state = c.raw_state,
        },
    };
    try emit(w, opts.json, e, arena);
}

/// `mobctl sim boot <selector>`。
pub fn boot(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const res = resolve(candidates, opts.selector);
    const cand = switch (res) {
        .none => {
            try emit(w, opts.json, notFound("sim boot", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim boot", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };

    const t0 = std.Io.Clock.now(.boot, io).nanoseconds;
    const outcome = boot_mod.boot(arena, io, env, cand) catch |e| {
        const kind: err.Kind = switch (e) {
            error.ToolMissing => .dependency_missing,
            error.BootFailed => .boot_timeout,
        };
        var fail = notFound("sim boot", cand.id);
        fail.platform = cand.platform;
        fail.@"error" = err.Info.fromKind(kind, "failed to boot simulator");
        try emit(w, opts.json, fail, arena);
        return;
    };
    const elapsed_ns = std.Io.Clock.now(.boot, io).nanoseconds - t0;

    const e: envelope.Envelope = .{
        .success = true,
        .command = "sim boot",
        .kind = .sim,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = outcome.state,
        .elapsed_ms = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms)),
        .handle = .{
            .transport = outcome.transport,
            .connection_hint = outcome.connection_hint,
            .process_pid = outcome.pid,
        },
        .warnings = if (outcome.already) dupStr(arena, "already_running") else &.{},
        .diagnostics = outcome.diagnostics,
    };
    try emit(w, opts.json, e, arena);
}

fn dupStr(arena: std.mem.Allocator, s: []const u8) []const []const u8 {
    const one = arena.alloc([]const u8, 1) catch return &.{};
    one[0] = s;
    return one;
}

/// `mobctl sim wait-ready <selector> [--timeout <s>]`。
pub fn waitReady(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("sim wait-ready", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim wait-ready", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const r = wait_mod.waitReady(arena, io, env, cand, opts.timeout_ms);
    try emit(w, opts.json, waitEnvelope(arena, "sim wait-ready", cand, r), arena);
}

/// `mobctl sim ensure <selector>` —— 幂等主入口：已 ready 直接返回；
/// 否则 boot 后 wait-ready（REQ §6.4 / §8.2）。
pub fn ensure(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("sim ensure", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim ensure", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };

    const t0 = std.Io.Clock.now(.boot, io).nanoseconds;

    // Fast path：已 ready，不 boot、不等。
    if (cand.state == .ready) {
        var e = waitEnvelope(arena, "sim ensure", cand, .{
            .ready = true,
            .state = .ready,
            .elapsed_ms = 0,
            .evidence = dupStr(arena, "already ready; reused"),
        });
        e.warnings = dupStr(arena, "already_running");
        try emit(w, opts.json, e, arena);
        return;
    }

    // 否则 boot。
    _ = boot_mod.boot(arena, io, env, cand) catch |e| {
        const kind: err.Kind = switch (e) {
            error.ToolMissing => .dependency_missing,
            error.BootFailed => .boot_timeout,
        };
        var fail = notFound("sim ensure", cand.id);
        fail.platform = cand.platform;
        fail.@"error" = err.Info.fromKind(kind, "ensure failed during boot");
        try emit(w, opts.json, fail, arena);
        return;
    };

    // boot 后用最新候选信息等待 ready（Android boot 后 id 可能从 AVD 名变为
    // serial，但 wait 内部会按 name 重新关联，故沿用原候选即可）。
    const r = wait_mod.waitReady(arena, io, env, cand, opts.timeout_ms);
    const total_ms: u64 = @intCast(@divFloor(std.Io.Clock.now(.boot, io).nanoseconds - t0, std.time.ns_per_ms));
    var e = waitEnvelope(arena, "sim ensure", cand, r);
    e.elapsed_ms = total_ms; // 覆盖成 boot+wait 的总耗时
    try emit(w, opts.json, e, arena);
}

/// 把 wait 结果包成信封。ready→success，超时→success=false + boot_timeout。
fn waitEnvelope(arena: std.mem.Allocator, command: []const u8, cand: discovery.Candidate, r: wait_mod.Result) envelope.Envelope {
    var e: envelope.Envelope = .{
        .success = r.ready,
        .command = command,
        .kind = .sim,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = r.state,
        .elapsed_ms = r.elapsed_ms,
        .diagnostics = r.evidence,
    };
    if (r.ready) {
        e.handle = .{
            .transport = if (cand.platform == .ios) "simctl" else "adb",
            .connection_hint = std.fmt.allocPrint(arena, "{s}:{s}", .{
                if (cand.platform == .ios) "xcrun simctl" else "adb",
                cand.id,
            }) catch cand.id,
            .ready_at = "now",
        };
    } else if (r.timed_out) {
        e.@"error" = err.Info.fromKind(.boot_timeout, "device did not reach ready within timeout");
    }
    return e;
}

/// `mobctl sim shutdown <selector> [--force]`。
pub fn shutdown(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("sim shutdown", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim shutdown", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const outcome = shutdown_mod.shutdown(arena, io, env, cand, opts.force) catch |e| {
        const kind: err.Kind = switch (e) {
            error.ToolMissing => .dependency_missing,
            error.ShutdownFailed => .shutdown_failed,
        };
        var fail = notFound("sim shutdown", cand.id);
        fail.platform = cand.platform;
        fail.@"error" = err.Info.fromKind(kind, "failed to shut down simulator");
        try emit(w, opts.json, fail, arena);
        return;
    };
    const e: envelope.Envelope = .{
        .success = true,
        .command = "sim shutdown",
        .kind = .sim,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = outcome.state,
        .warnings = if (outcome.already) dupStr(arena, "already_stopped") else &.{},
        .diagnostics = outcome.diagnostics,
    };
    try emit(w, opts.json, e, arena);
}

/// `mobctl sim handle <selector>` —— 导出稳定句柄（command:"sim handle" 信封）。
pub fn handle(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("sim handle", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim handle", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const e: envelope.Envelope = .{
        .success = true,
        .command = "sim handle",
        .kind = .sim,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = cand.state,
        .raw_state = cand.raw_state,
        .handle = handle_mod.forSim(arena, io, env, cand),
    };
    try emit(w, opts.json, e, arena);
}

/// `mobctl sim reset <selector>` —— 显式重置（清数据）。
pub fn reset(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("sim reset", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim reset", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const outcome = reset_mod.reset(arena, io, env, cand) catch |e| {
        const kind: err.Kind = switch (e) {
            error.ToolMissing => .dependency_missing,
            error.DeviceBusy => .device_busy,
            error.ResetFailed => .reset_failed,
        };
        var fail = notFound("sim reset", cand.id);
        fail.platform = cand.platform;
        var info = err.Info.fromKind(kind, "failed to reset simulator");
        if (kind == .device_busy) info.diagnostics = dupStr(arena, "shut it down before reset");
        fail.@"error" = info;
        try emit(w, opts.json, fail, arena);
        return;
    };
    const e: envelope.Envelope = .{
        .success = true,
        .command = "sim reset",
        .kind = .sim,
        .platform = cand.platform,
        .device_id = cand.id,
        .state = outcome.state,
        .handle = if (outcome.pid) |p| .{ .transport = "adb", .connection_hint = "(booting)", .process_pid = p } else null,
        .diagnostics = outcome.diagnostics,
    };
    try emit(w, opts.json, e, arena);
}

/// `mobctl sim logs <selector> [--lines N] [--json]` —— 采集日志。
/// 默认原始文本；`--json` 输出 NDJSON（每行一个 {"line":...}）。
pub fn logs(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, opts: args.TargetOpts) !void {
    const candidates = try discovery.list(arena, io, env, null);
    const cand = switch (resolve(candidates, opts.selector)) {
        .none => {
            try emit(w, opts.json, notFound("sim logs", opts.selector), arena);
            return;
        },
        .ambiguous => |n| {
            try emit(w, opts.json, ambiguous(arena, "sim logs", opts.selector, n), arena);
            return;
        },
        .one => |c| c,
    };
    const text = logs_mod.collect(arena, io, env, cand, opts.lines) catch |e| {
        const kind: err.Kind = switch (e) {
            error.ToolMissing => .dependency_missing,
            error.NotReady => .device_busy,
            error.NoLogs => .unknown_error,
        };
        var fail = notFound("sim logs", cand.id);
        fail.platform = cand.platform;
        var info = err.Info.fromKind(kind, "could not collect logs");
        if (kind == .device_busy) info.diagnostics = dupStr(arena, "device not ready; boot it first");
        fail.@"error" = info;
        try emit(w, opts.json, fail, arena);
        return;
    };

    if (opts.json) {
        const Line = struct { line: []const u8 };
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            try std.json.Stringify.value(Line{ .line = ln }, .{}, w);
            try w.writeByte('\n');
        }
    } else {
        try w.writeAll(text);
        if (text.len > 0 and text[text.len - 1] != '\n') try w.writeByte('\n');
    }
}
