//! mobctl —— AgentFirst 的移动模拟器 / 真机管理 CLI。
//! 入口：解析 argv → 路由到子命令。当前接线 `sim list`。

const std = @import("std");
const Io = std.Io;
const envelope = @import("shared/envelope.zig");
const err = @import("shared/error.zig");
const args_mod = @import("cli/args.zig");
const sim_cmd = @import("cli/cmd/sim.zig");
const device_cmd = @import("cli/cmd/device.zig");
const doctor_cmd = @import("cli/cmd/doctor.zig");
const report_cmd = @import("cli/cmd/report.zig");

const usage =
    \\mobctl — AgentFirst 移动模拟器 / 真机管理
    \\
    \\用法:
    \\  mobctl sim list   [--platform android|ios] [--json]
    \\  mobctl sim status     <id|name> [--json]
    \\  mobctl sim boot       <id|name> [--json]
    \\  mobctl sim wait-ready <id|name> [--json] [--timeout <s>]
    \\  mobctl sim ensure     <id|name> [--json] [--timeout <s>]
    \\  mobctl sim shutdown   <id|name> [--json] [--force]
    \\  mobctl sim handle     <id|name> [--json]
    \\  mobctl sim reset      <id|name> [--json]
    \\  mobctl sim logs       [id|name] [-f] [--lines N] [--grep S] [--json]
    \\  mobctl device list       [--platform android] [--json]
    \\  mobctl device status     <serial|name> [--json]
    \\  mobctl device wait-ready <serial|name> [--json] [--timeout <s>]
    \\  mobctl device ensure     <serial|name> [--json] [--timeout <s>]
    \\  mobctl device handle     <serial|name> [--json]
    \\  mobctl device logs       [serial|name] [-f] [--lines N] [--grep S] [--pid N] [--package P] [--tag T] [--level W] [--json]
    \\  mobctl device connect    <ip[:port]> [--json]
    \\  mobctl device disconnect <serial> [--json]
    \\  mobctl doctor         [--json]
    \\  mobctl report         [--format json|ndjson|md]
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const cmd = args_mod.parse(if (argv.len > 1) argv[1..] else &.{});

    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const w = &fw.interface;
    defer w.flush() catch {};

    switch (cmd) {
        .sim_list => |opts| try sim_cmd.list(arena, init.io, init.environ_map, w, opts),
        .sim_status => |opts| try sim_cmd.status(arena, init.io, init.environ_map, w, opts),
        .sim_boot => |opts| try sim_cmd.boot(arena, init.io, init.environ_map, w, opts),
        .sim_wait_ready => |opts| try sim_cmd.waitReady(arena, init.io, init.environ_map, w, opts),
        .sim_ensure => |opts| try sim_cmd.ensure(arena, init.io, init.environ_map, w, opts),
        .sim_shutdown => |opts| try sim_cmd.shutdown(arena, init.io, init.environ_map, w, opts),
        .sim_handle => |opts| try sim_cmd.handle(arena, init.io, init.environ_map, w, opts),
        .sim_reset => |opts| try sim_cmd.reset(arena, init.io, init.environ_map, w, opts),
        .sim_logs => |opts| try sim_cmd.logs(arena, init.io, init.environ_map, w, opts),
        .device_list => |opts| try device_cmd.list(arena, init.io, init.environ_map, w, opts),
        .device_status => |opts| try device_cmd.status(arena, init.io, init.environ_map, w, opts),
        .device_wait_ready => |opts| try device_cmd.waitReady(arena, init.io, init.environ_map, w, opts),
        .device_ensure => |opts| try device_cmd.ensure(arena, init.io, init.environ_map, w, opts),
        .device_handle => |opts| try device_cmd.handle(arena, init.io, init.environ_map, w, opts),
        .device_logs => |opts| try device_cmd.logs(arena, init.io, init.environ_map, w, opts),
        .device_connect => |opts| try device_cmd.connect(arena, init.io, init.environ_map, w, opts),
        .device_disconnect => |opts| try device_cmd.disconnect(arena, init.io, init.environ_map, w, opts),
        .doctor => |json| {
            const ok = try doctor_cmd.run(arena, init.io, init.environ_map, w, json);
            if (!ok) {
                w.flush() catch {};
                std.process.exit(1);
            }
        },
        .report => |fmt| try report_cmd.run(arena, init.io, init.environ_map, w, fmt),
        .help => try w.writeAll(usage),
        .unknown => |tok| {
            var ew: Io.File.Writer = .init(.stderr(), init.io, &buf);
            try ew.interface.print("unknown command: {s}\n\n", .{tok});
            try ew.interface.writeAll(usage);
            try ew.interface.flush();
            std.process.exit(1);
        },
    }
}

// 把整棵 SPEC §11 模块树纳入编译 / 测试。`_ = @import(...)` 会强制解析
// 对应文件，语法错误会在 `zig build` 时暴露；test 块还会聚合各文件里的 test。
test {
    _ = envelope;
    _ = err;
    _ = @import("shared/exec.zig");
    _ = @import("shared/artifact.zig");
    _ = @import("shared/report.zig");
    _ = @import("cli/args.zig");
    _ = @import("cli/cmd/sim.zig");
    _ = @import("cli/cmd/device.zig");
    _ = @import("cli/cmd/doctor.zig");
    _ = @import("cli/cmd/report.zig");
    _ = @import("sim/discovery.zig");
    _ = @import("sim/resolver.zig");
    _ = @import("sim/boot.zig");
    _ = @import("sim/wait_ready.zig");
    _ = @import("sim/shutdown.zig");
    _ = @import("sim/reset.zig");
    _ = @import("sim/logs.zig");
    _ = @import("sim/handle.zig");
    _ = @import("device/discovery.zig");
    _ = @import("device/resolver.zig");
    _ = @import("device/connect.zig");
    _ = @import("device/pair.zig");
    _ = @import("device/trust.zig");
    _ = @import("device/wait_ready.zig");
    _ = @import("device/disconnect.zig");
    _ = @import("device/handle.zig");
    _ = @import("device/logs.zig");
}
