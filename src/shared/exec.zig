//! 子进程执行 + 输出捕获。所有外部工具（xcrun / adb / emulator）都走这里，
//! 统一成"跑一条命令、拿 stdout/stderr/退出码"的同步模型。
//!
//! argv[0] 解析用父进程 PATH：`xcrun` 在 PATH 上可直接用名字；`adb` /
//! `emulator` 不在 PATH，调用方需传绝对路径。

const std = @import("std");
const Io = std.Io;

pub const Output = struct {
    /// 正常退出的退出码；被信号杀死等异常情况为 null。
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(self: Output) bool {
        return self.exit_code != null and self.exit_code.? == 0;
    }
};

/// 跑 argv 并捕获输出。spawn 失败（如二进制不存在）返回 null —— 调用方据此
/// 把"工具缺失"当成可降级的状态，而不是崩溃。stdout/stderr 用 `gpa` 分配，
/// 通常传 arena，免手动释放。
pub fn capture(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) ?Output {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    const code: ?u8 = switch (r.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .exit_code = code, .stdout = r.stdout, .stderr = r.stderr };
}

/// 流式跑 argv（如 `adb logcat` / `simctl log stream`），逐行读 stdout，按
/// `grep` 子串过滤后**实时**写出（每行 flush，follow 模式下持续到子进程退出
/// 或被信号杀掉——父进程被 Ctrl-C 时同进程组的子进程一起收到 SIGINT）。
/// `fmt` 决定每行输出（text / ndjson_raw / ndjson_logcat）。spawn 失败静默返回。
pub fn streamLogs(io: Io, argv: []const []const u8, w: *Io.Writer, grep: ?[]const u8, fmt: LineFormat) void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return;
    defer child.kill(io); // 0.16 的 kill 含 wait，兼顾 follow 中止与 dump 收尸

    if (child.stdout) |*so| {
        var buf: [1 << 16]u8 = undefined;
        var r = so.readerStreaming(io, &buf);
        while (true) {
            // takeDelimiter 消费 '\n'、EOF 返回 null；exclusive 变体不消费分隔符会死循环。
            const maybe = r.interface.takeDelimiter('\n') catch |e| switch (e) {
                error.StreamTooLong => {
                    r.interface.tossBuffered(); // 丢弃超长行残段，继续
                    continue;
                },
                error.ReadFailed => break,
            };
            const line = maybe orelse break; // null = EOF
            if (grep) |g| {
                if (std.mem.indexOf(u8, line, g) == null) continue;
            }
            emitLine(w, line, fmt) catch break;
            w.flush() catch break; // 实时
        }
    }
}

/// 日志行输出格式。
pub const LineFormat = enum {
    /// 原始文本行。
    text,
    /// 每行包成 `{"line":...}`。
    ndjson_raw,
    /// 解析 Android logcat threadtime 行成结构化记录（解析失败回退 `{"raw":...}`）。
    ndjson_logcat,
};

fn emitLine(w: *Io.Writer, line: []const u8, fmt: LineFormat) !void {
    switch (fmt) {
        .text => {
            try w.writeAll(line);
            try w.writeByte('\n');
        },
        .ndjson_raw => {
            try std.json.Stringify.value(.{ .line = line }, .{}, w);
            try w.writeByte('\n');
        },
        .ndjson_logcat => {
            if (parseLogcat(line)) |rec| {
                try std.json.Stringify.value(rec, .{}, w);
            } else {
                try std.json.Stringify.value(.{ .raw = line }, .{}, w);
            }
            try w.writeByte('\n');
        },
    }
}

/// 解析后的 logcat 记录（threadtime 格式）。
pub const LogcatRecord = struct {
    time: []const u8, // "MM-DD HH:MM:SS.mmm"
    pid: u32,
    tid: u32,
    level: []const u8, // V/D/I/W/E/F
    tag: []const u8,
    message: []const u8,
};

/// 解析 `MM-DD HH:MM:SS.mmm  PID  TID L TAG: message`。分隔行 / 异常行返回 null。
pub fn parseLogcat(line: []const u8) ?LogcatRecord {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const date = it.next() orelse return null;
    const time = it.next() orelse return null;
    const pid_s = it.next() orelse return null;
    const tid_s = it.next() orelse return null;
    const level = it.next() orelse return null;
    if (level.len != 1) return null; // 单字符优先级
    const pid = std.fmt.parseInt(u32, pid_s, 10) catch return null;
    const tid = std.fmt.parseInt(u32, tid_s, 10) catch return null;

    // 剩余 = "TAG: message"；按首个 ": " 切分。
    const rest = std.mem.trimStart(u8, it.rest(), " ");
    const sep = std.mem.indexOf(u8, rest, ": ") orelse return null;
    const tag = std.mem.trimEnd(u8, rest[0..sep], " ");
    const message = rest[sep + 2 ..];

    // time 字段拼回 "date time"，借用原始 buffer 的连续片段。
    const time_full = line[@intFromPtr(date.ptr) - @intFromPtr(line.ptr) .. @intFromPtr(time.ptr) - @intFromPtr(line.ptr) + time.len];
    return .{ .time = time_full, .pid = pid, .tid = tid, .level = level, .tag = tag, .message = message };
}

test "parseLogcat threadtime line" {
    const line = "06-01 16:02:45.831  2074  6508 D CompatibilityInfo: applicationScale - 1.0";
    const rec = parseLogcat(line).?;
    try std.testing.expectEqualStrings("06-01 16:02:45.831", rec.time);
    try std.testing.expectEqual(@as(u32, 2074), rec.pid);
    try std.testing.expectEqual(@as(u32, 6508), rec.tid);
    try std.testing.expectEqualStrings("D", rec.level);
    try std.testing.expectEqualStrings("CompatibilityInfo", rec.tag);
    try std.testing.expectEqualStrings("applicationScale - 1.0", rec.message);
}

test "parseLogcat separator line → null" {
    try std.testing.expect(parseLogcat("--------- beginning of main") == null);
}

/// 把已捕获的文本按 `grep` 过滤后写出（dump 模式，非流式）。与 streamLogs
/// 共享同一套 grep / 格式语义。
pub fn writeFilteredText(w: *Io.Writer, text: []const u8, grep: ?[]const u8, fmt: LineFormat) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (grep) |g| {
            if (std.mem.indexOf(u8, line, g) == null) continue;
        }
        emitLine(w, line, fmt) catch return;
    }
}

/// 以分离方式启动一个长驻进程（如 Android emulator），不等待、不捕获。
/// stdio 全部接 /dev/null，`pgid=0` 让它脱离父进程组——父进程退出 / Ctrl-C
/// 不会连带杀掉它。返回子进程 pid（失败返回 null）。
pub fn spawnDetached(io: Io, argv: []const []const u8) ?u32 {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return null;
    const id = child.id orelse return null;
    return std.math.cast(u32, id) orelse null;
}
