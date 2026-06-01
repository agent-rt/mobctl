//! report —— 导出聚合环境报告（REQ §6.17 / SPEC §9.2）。
//! 聚合 doctor 的 checks + sim/device 清单 + summary，支持 JSON / NDJSON /
//! Markdown。Android / iOS 证据格式一致，来源差异保留在各候选的 raw_state。

const std = @import("std");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;
const report = @import("../../shared/report.zig");
const doctor = @import("doctor.zig");
const sim_discovery = @import("../../sim/discovery.zig");
const device_discovery = @import("../../device/discovery.zig");
const args = @import("../args.zig");

pub fn run(arena: std.mem.Allocator, io: Io, env: *const EnvMap, w: *Io.Writer, format: args.ReportFormat) !void {
    const checks = (try doctor.gather(arena, io, env)).items;
    const s = doctor.summarize(arena, checks);
    const sims = sim_discovery.list(arena, io, env, null) catch &.{};
    const devices = device_discovery.list(arena, io, env, null) catch &.{};

    switch (format) {
        .json => try emitJson(arena, w, s.ok, s.summary, checks, sims, devices),
        .ndjson => try emitNdjson(w, s.ok, s.summary, checks, sims, devices),
        .md => try emitMd(w, s.ok, s.summary, checks, sims, devices),
    }
}

fn emitJson(
    arena: std.mem.Allocator,
    w: *Io.Writer,
    ok: bool,
    summary: []const u8,
    checks: []const report.Check,
    sims: []const sim_discovery.Candidate,
    devices: []const device_discovery.Candidate,
) !void {
    const Out = struct {
        schema_version: u32 = 1,
        command: []const u8 = "report",
        ok: bool,
        summary: []const u8,
        checks: []const report.Check,
        simulators: []const sim_discovery.Candidate,
        devices: []const device_discovery.Candidate,
    };
    _ = arena;
    try std.json.Stringify.value(Out{
        .ok = ok,
        .summary = summary,
        .checks = checks,
        .simulators = sims,
        .devices = devices,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

fn emitNdjson(
    w: *Io.Writer,
    ok: bool,
    summary: []const u8,
    checks: []const report.Check,
    sims: []const sim_discovery.Candidate,
    devices: []const device_discovery.Candidate,
) !void {
    const opt: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    try std.json.Stringify.value(.{ .type = "summary", .ok = ok, .summary = summary }, opt, w);
    try w.writeByte('\n');
    for (checks) |c| {
        try std.json.Stringify.value(.{ .type = "check", .data = c }, opt, w);
        try w.writeByte('\n');
    }
    for (sims) |c| {
        try std.json.Stringify.value(.{ .type = "sim", .data = c }, opt, w);
        try w.writeByte('\n');
    }
    for (devices) |c| {
        try std.json.Stringify.value(.{ .type = "device", .data = c }, opt, w);
        try w.writeByte('\n');
    }
}

fn emitMd(
    w: *Io.Writer,
    ok: bool,
    summary: []const u8,
    checks: []const report.Check,
    sims: []const sim_discovery.Candidate,
    devices: []const device_discovery.Candidate,
) !void {
    try w.print("# mobctl report\n\n**{s}** — {s}\n\n", .{ if (ok) "OK" else "PROBLEMS", summary });

    try w.writeAll("## Checks\n\n| status | name | detail | fix |\n|---|---|---|---|\n");
    for (checks) |c| {
        try w.print("| {s} | {s} | {s} | {s} |\n", .{ @tagName(c.status), c.name, c.detail, c.fix orelse "" });
    }

    try w.print("\n## Simulators ({d})\n\n", .{sims.len});
    if (sims.len == 0) try w.writeAll("_none_\n");
    for (sims) |c| {
        try w.print("- `{s}` **{s}** {s} (`{s}`)\n", .{ @tagName(c.platform), @tagName(c.state), c.name, c.id });
    }

    try w.print("\n## Devices ({d})\n\n", .{devices.len});
    if (devices.len == 0) try w.writeAll("_none_\n");
    for (devices) |c| {
        try w.print("- `{s}` **{s}** {s} {s} {s} (`{s}`)\n", .{
            @tagName(c.platform),
            @tagName(c.state),
            c.connection_type,
            if (c.trusted) "trusted" else "untrusted",
            c.name,
            c.id,
        });
    }
}
