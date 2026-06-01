//! 机器可读报告 / 诊断结果 —— REQ §6.15 §6.17 / SPEC §9.2。
//!
//! `Check` 是诊断的最小单元（status/detail/fix），`Report` 聚合一组 check
//! 加总体结论。doctor / report 都复用这套类型，保证 Android / iOS 证据格式
//! 一致（来源差异由 detail 文本承载）。

const std = @import("std");

pub const Status = enum { ok, warn, fail };

/// 单项检查。`fix` 可空——仅在有可操作建议时给出，null 序列化省略。
pub const Check = struct {
    name: []const u8,
    status: Status,
    detail: []const u8,
    fix: ?[]const u8 = null,
};

pub const Report = struct {
    schema_version: u32 = 1,
    command: []const u8 = "doctor",
    /// 无任何 fail 即 true（warn 不影响 ok）。
    ok: bool,
    summary: []const u8,
    checks: []const Check,

    pub fn toJson(self: Report, alloc: std.mem.Allocator, pretty: bool) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try std.json.Stringify.value(self, .{
            .whitespace = if (pretty) .indent_2 else .minified,
            .emit_null_optional_fields = false,
        }, &aw.writer);
        return aw.toOwnedSlice();
    }

    /// 人类排障视图。
    pub fn writeText(self: Report, w: *std.Io.Writer) !void {
        for (self.checks) |c| {
            const mark = switch (c.status) {
                .ok => "OK  ",
                .warn => "WARN",
                .fail => "FAIL",
            };
            try w.print("[{s}] {s}: {s}\n", .{ mark, c.name, c.detail });
            if (c.fix) |f| try w.print("       fix: {s}\n", .{f});
        }
        try w.print("\n{s}: {s}\n", .{ if (self.ok) "OK" else "PROBLEMS", self.summary });
    }
};

test "report ok when no fails, json omits null fix" {
    const checks = [_]Check{
        .{ .name = "xcrun", .status = .ok, .detail = "present" },
        .{ .name = "android-sdk", .status = .warn, .detail = "not set", .fix = "export ANDROID_HOME=..." },
    };
    const r = Report{ .ok = true, .summary = "1 warn", .checks = &checks };
    const s = try r.toJson(std.testing.allocator, false);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"status\":\"warn\"") != null);
    // ok 的 check 无 fix，应省略；warn 的有 fix，应保留。
    try std.testing.expect(std.mem.indexOf(u8, s, "export ANDROID_HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"fix\":null") == null);
}
