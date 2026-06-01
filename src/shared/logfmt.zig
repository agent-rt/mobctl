//! 日志行格式化 —— 解析 Android logcat threadtime 行，按四种格式输出：
//! raw_text / pretty（着色+对齐，借鉴 JakeWharton/pidcat）/ ndjson_raw / ndjson_logcat。
//!
//! pretty 布局：`<tag 右对齐着色> <level 色块> <message 按宽度缩进换行>`，连续
//! 同 tag 留空。颜色按 tag 名 hash 取自调色板，level 按优先级取背景色。

const std = @import("std");
const Io = std.Io;

pub const Format = enum { raw_text, pretty, ndjson_raw, ndjson_logcat };

/// logcat threadtime 记录。
pub const Record = struct {
    time: []const u8, // "MM-DD HH:MM:SS.mmm"
    pid: u32,
    tid: u32,
    level: []const u8, // V/D/I/W/E/F
    tag: []const u8,
    message: []const u8,
};

/// 解析 `MM-DD HH:MM:SS.mmm  PID  TID L TAG: message`。分隔行 / 异常行返回 null。
pub fn parseLogcat(line: []const u8) ?Record {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const date = it.next() orelse return null;
    const time = it.next() orelse return null;
    const pid_s = it.next() orelse return null;
    const tid_s = it.next() orelse return null;
    const level = it.next() orelse return null;
    if (level.len != 1) return null;
    const pid = std.fmt.parseInt(u32, pid_s, 10) catch return null;
    const tid = std.fmt.parseInt(u32, tid_s, 10) catch return null;

    const rest = std.mem.trimStart(u8, it.rest(), " ");
    const sep = std.mem.indexOf(u8, rest, ": ") orelse return null;
    const tag = std.mem.trimEnd(u8, rest[0..sep], " ");
    const message = rest[sep + 2 ..];

    const base = @intFromPtr(line.ptr);
    const time_full = line[@intFromPtr(date.ptr) - base .. @intFromPtr(time.ptr) - base + time.len];
    return .{ .time = time_full, .pid = pid, .tid = tid, .level = level, .tag = tag, .message = message };
}

/// 根据上下文选择输出格式。
pub fn chooseFormat(json: bool, android: bool, tty: bool, color: ?bool) Format {
    if (json) return if (android) .ndjson_logcat else .ndjson_raw;
    if (color == false) return .raw_text; // --no-color → 纯文本（利于 grep/脚本）
    if (tty or color == true) return .pretty;
    return .raw_text; // 管道默认纯文本
}

const tag_w = 23;
const header = tag_w + 1 + 3 + 1; // tag + ' ' + ' X ' + ' '

/// 有状态打印器（pretty 模式跨行记忆上一个 tag 以便留空）。
pub const Printer = struct {
    format: Format = .raw_text,
    color: bool = false,
    width: usize = 100,
    last_tag: [128]u8 = undefined,
    last_len: usize = 0,
    has_last: bool = false,

    pub fn emit(self: *Printer, w: *Io.Writer, line: []const u8) !void {
        switch (self.format) {
            .raw_text => {
                try w.writeAll(line);
                try w.writeByte('\n');
            },
            .ndjson_raw => {
                try std.json.Stringify.value(.{ .line = line }, .{}, w);
                try w.writeByte('\n');
            },
            .ndjson_logcat => {
                if (parseLogcat(line)) |r|
                    try std.json.Stringify.value(r, .{}, w)
                else
                    try std.json.Stringify.value(.{ .raw = line }, .{}, w);
                try w.writeByte('\n');
            },
            .pretty => try self.pretty(w, line),
        }
    }

    fn pretty(self: *Printer, w: *Io.Writer, line: []const u8) !void {
        const r = parseLogcat(line) orelse {
            // 非 logcat（分隔行 / iOS）→ 原样输出
            try w.writeAll(line);
            try w.writeByte('\n');
            return;
        };

        // tag（右对齐到 tag_w；超长取末尾；连续同 tag 留空）
        const shown = if (r.tag.len > tag_w) r.tag[r.tag.len - tag_w ..] else r.tag;
        try w.splatByteAll(' ', tag_w - shown.len);
        const same = self.has_last and std.mem.eql(u8, r.tag, self.last_tag[0..self.last_len]);
        if (same) {
            try w.splatByteAll(' ', shown.len);
        } else if (self.color) {
            try w.print("\x1b[3{d}m{s}\x1b[0m", .{ tagColor(r.tag), shown });
        } else {
            try w.writeAll(shown);
        }
        if (!same) {
            const n = @min(r.tag.len, self.last_tag.len);
            @memcpy(self.last_tag[0..n], r.tag[0..n]);
            self.last_len = n;
            self.has_last = true;
        }

        try w.writeByte(' ');
        try self.writeLevel(w, r.level[0]);
        try w.writeByte(' ');
        try self.writeMessage(w, r.message);
    }

    fn writeLevel(self: *Printer, w: *Io.Writer, ch: u8) !void {
        if (self.color) {
            if (levelBg(ch)) |bg| {
                try w.print("\x1b[30;4{d}m {c} \x1b[0m", .{ bg, ch });
                return;
            }
        }
        try w.print(" {c} ", .{ch});
    }

    fn writeMessage(self: *Printer, w: *Io.Writer, msg: []const u8) !void {
        if (self.width <= header + 8) { // 太窄不换行
            try w.writeAll(msg);
            try w.writeByte('\n');
            return;
        }
        const avail = self.width - header;
        var i: usize = 0;
        var first = true;
        while (i < msg.len) {
            if (!first) try w.splatByteAll(' ', header);
            const end = @min(i + avail, msg.len);
            try w.writeAll(msg[i..end]);
            try w.writeByte('\n');
            i = end;
            first = false;
        }
        if (msg.len == 0) try w.writeByte('\n');
    }
};

/// tag 名 → 前景色 1..7（红…白，跳过黑）。djb2 hash 保证同 tag 同色。
fn tagColor(tag: []const u8) u8 {
    var h: u32 = 5381;
    for (tag) |c| h = (h *% 33) +% c;
    return @intCast(1 + (h % 7));
}

/// level → 背景色（黑字色块）。
fn levelBg(ch: u8) ?u8 {
    return switch (ch) {
        'V' => 7, // white
        'D' => 4, // blue
        'I' => 2, // green
        'W' => 3, // yellow
        'E', 'F' => 1, // red
        else => null,
    };
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

test "parseLogcat separator → null" {
    try std.testing.expect(parseLogcat("--------- beginning of main") == null);
}

test "chooseFormat" {
    try std.testing.expectEqual(Format.ndjson_logcat, chooseFormat(true, true, false, null));
    try std.testing.expectEqual(Format.ndjson_raw, chooseFormat(true, false, false, null));
    try std.testing.expectEqual(Format.pretty, chooseFormat(false, true, true, null)); // tty
    try std.testing.expectEqual(Format.pretty, chooseFormat(false, true, false, true)); // --color
    try std.testing.expectEqual(Format.raw_text, chooseFormat(false, true, true, false)); // --no-color
    try std.testing.expectEqual(Format.raw_text, chooseFormat(false, true, false, null)); // piped
}

test "pretty renders aligned colored line" {
    var p: Printer = .{ .format = .pretty, .color = true, .width = 100 };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try p.emit(&aw.writer, "06-01 16:02:45.831  2074  6508 E ActivityManager: boom");
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "ActivityManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null); // 含 ANSI
    try std.testing.expect(std.mem.indexOf(u8, out, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " E ") != null); // level 块
}
