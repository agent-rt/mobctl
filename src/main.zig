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
    \\`<cmd> --help` 查看某命令详情（如 `mobctl device logs --help`）。
    \\
;

const logs_help =
    \\mobctl <sim|device> logs — 采集日志（调试利器）
    \\
    \\用法:
    \\  mobctl device logs [serial|name] [选项]
    \\  mobctl sim logs    [id|name]     [选项]
    \\
    \\目标:
    \\  省略 selector 时，若只有一个候选则自动选中。
    \\
    \\过滤（可组合）:
    \\  --grep <子串>          只输出包含该子串的行（进程内，跨平台）
    \\  --pid <pid>            只看该进程（Android logcat --pid）
    \\  --package <pkg>        只看该包的进程（pidof 解析，支持多进程）
    \\  --tag <tag>            只看该 tag（Android logcat filterspec）
    \\  --level <V|D|I|W|E|F>  最低优先级（Android）
    \\
    \\模式:
    \\  -f, --follow           实时跟随（tail -f 式），Ctrl-C 结束
    \\  --lines <N>            dump 模式行数上限（默认 200）
    \\
    \\输出:
    \\  --json                 结构化 NDJSON（Android 解析成 time/pid/tid/level/tag/message）
    \\  --color / --no-color   强制 / 关闭着色（默认 TTY 自动开 pidcat 风格着色对齐）
    \\  --width <N>            pretty 换行宽度（默认 100）
    \\
    \\示例:
    \\  mobctl device logs --package com.example.app -f      # 跟随某 app 的日志
    \\  mobctl device logs --level E --lines 500             # 最近 500 行里的错误
    \\  mobctl device logs --grep ANR --json                 # 含 ANR 的行，结构化输出
    \\
;

const list_help =
    \\mobctl <sim|device> list — 列出候选
    \\
    \\用法:
    \\  mobctl sim list    [--platform android|ios] [--json]
    \\  mobctl device list [--platform android] [--json]
    \\
    \\选项:
    \\  --platform <p>   只列该平台（android / ios）
    \\  --json           结构化输出
    \\
    \\说明:
    \\  sim list 列出模拟器并关联运行中的实例；device list 列出物理真机
    \\  （排除模拟器），区分 usb/wifi 连接与 trusted 授权状态。
    \\
;

const status_help =
    \\mobctl <sim|device> status [selector] — 查询单个目标的当前状态
    \\
    \\  [selector]   id / name / serial；省略时若唯一候选则自动选中
    \\  --json       结构化信封输出（含统一 state 与平台 raw_state）
    \\
;

const boot_help =
    \\mobctl sim boot [id|name] — 启动模拟器
    \\
    \\  已运行则幂等复用（不重启）。iOS 用 `simctl boot`；Android 后台拉起 emulator。
    \\  启动后用 `sim wait-ready` / `sim ensure` 等待就绪。
    \\
    \\  --json   结构化输出（含耗时、句柄）
    \\  省略 selector 时若唯一候选则自动选中。
    \\
;

const wait_ready_help =
    \\mobctl <sim|device> wait-ready [selector] — 轮询直到 ready，返回判定证据
    \\
    \\  --timeout <秒>   超时（默认 120）
    \\  --json           结构化输出（含 ready 证据 / 超时原因）
    \\
    \\就绪判定:
    \\  iOS sim：状态 Booted 且可在设备内 spawn 进程（核心服务已起）
    \\  Android：adb 可见为 device 且 `getprop sys.boot_completed` == 1
    \\  真机 unauthorized 会立即上报（需在设备上确认 USB 调试授权），不静默重试；
    \\  offline 视为瞬态，继续轮询到超时。
    \\
;

const ensure_help =
    \\mobctl <sim|device> ensure [selector] — 幂等确保 ready（推荐主入口）
    \\
    \\  已 ready：直接复用并返回。
    \\  未就绪：sim 先 boot 再 wait-ready；真机直接 wait-ready（无 boot）。
    \\
    \\  --timeout <秒>   超时（默认 120）
    \\  --json           结构化输出
    \\
;

const shutdown_help =
    \\mobctl sim shutdown [id|name] — 关闭模拟器
    \\
    \\  --force   强制关闭
    \\  --json    结构化输出
    \\  已停止则幂等返回（already_stopped）。
    \\
;

const reset_help =
    \\mobctl sim reset [id|name] — 重置到可复用状态（清数据，显式操作）
    \\
    \\  iOS：shutdown 后 `simctl erase`；Android：`-wipe-data` 冷启动。
    \\  运行中的 Android 会被拒绝（device_busy）——请先 shutdown。
    \\  --json   结构化输出
    \\
;

const handle_help =
    \\mobctl <sim|device> handle [selector] — 导出稳定句柄给下游工具
    \\
    \\  必选：transport / connection_hint（+ 信封顶层 kind/platform/device_id/state）
    \\  平台可选：ready_at / runtime / connection_type / trust_state / app_container_hint
    \\  --json   结构化输出
    \\
;

const connect_help =
    \\mobctl device connect <ip[:port]> — 通过 wifi 连接真机
    \\
    \\  `adb connect`，默认端口 5555。已连接则幂等复用。
    \\  注意：USB 设备插上即被 `device list` 发现，无需 connect。
    \\  --json   结构化输出
    \\
;

const disconnect_help =
    \\mobctl device disconnect <serial> — 断开 wifi 连接
    \\
    \\  --json   结构化输出
    \\
;

const doctor_help =
    \\mobctl doctor — 诊断 iOS / Android 工具链、SDK、依赖、可发现性
    \\
    \\  每项检查返回 status: ok|warn|fail + detail + 可操作 fix。
    \\  缺某平台工具链 = warn（可只用另一平台）；工具链损坏 = fail。
    \\  有 fail 时进程退出码为 1。
    \\  --json   结构化报告
    \\
;

const report_help =
    \\mobctl report — 导出环境聚合报告
    \\
    \\  聚合 doctor 检查 + 模拟器/真机清单 + 概要，一次性交给 Agent 决策。
    \\  --format json|ndjson|md   输出格式（默认 json）
    \\
;

const HelpTopic = struct { name: []const u8, text: []const u8 };
const help_topics = [_]HelpTopic{
    .{ .name = "list", .text = list_help },
    .{ .name = "status", .text = status_help },
    .{ .name = "boot", .text = boot_help },
    .{ .name = "wait-ready", .text = wait_ready_help },
    .{ .name = "ensure", .text = ensure_help },
    .{ .name = "shutdown", .text = shutdown_help },
    .{ .name = "reset", .text = reset_help },
    .{ .name = "handle", .text = handle_help },
    .{ .name = "logs", .text = logs_help },
    .{ .name = "connect", .text = connect_help },
    .{ .name = "disconnect", .text = disconnect_help },
    .{ .name = "doctor", .text = doctor_help },
    .{ .name = "report", .text = report_help },
};

fn printHelp(w: *std.Io.Writer, topic: []const u8) !void {
    for (help_topics) |t| {
        if (std.mem.eql(u8, topic, t.name)) {
            try w.writeAll(t.text);
            return;
        }
    }
    try w.writeAll(usage); // "" 或未知 topic → 总览
}

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
        .help => |topic| try printHelp(w, topic),
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
    _ = @import("shared/logfmt.zig");
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
