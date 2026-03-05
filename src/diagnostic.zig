//! Error-location utilities for populating Diagnostics from a byte position
//! in source text. Shared by Parser (and available to future tools like Wig).

const std = @import("std");
const Diagnostics = @import("options.zig").Diagnostics;

/// Populate a Diagnostics struct with line, column, source line excerpt, and
/// error message computed from a byte position in the input.
pub fn setError(diag: *Diagnostics, input: []const u8, pos: usize, comptime message: []const u8) void {
    var line: usize = 1;
    var col: usize = 1;
    var line_start: usize = 0;
    for (input[0..@min(pos, input.len)], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            col = 1;
            line_start = i + 1;
        } else {
            col += 1;
        }
    }
    var line_end = line_start;
    while (line_end < input.len and input[line_end] != '\n') line_end += 1;
    diag.line = line;
    diag.column = col;
    diag.message = message;
    diag.source_line = input[line_start..line_end];
}

const testing = std.testing;

test "setError populates diagnostics" {
    var diag: Diagnostics = .{};
    setError(&diag, "hello\nworld", 7, "TestError");
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectEqual(@as(usize, 2), diag.column);
    try testing.expectEqualStrings("TestError", diag.message);
    try testing.expectEqualStrings("world", diag.source_line);
}

test "setError at start of input" {
    var diag: Diagnostics = .{};
    setError(&diag, "hello", 0, "TestError");
    try testing.expectEqual(@as(usize, 1), diag.line);
    try testing.expectEqual(@as(usize, 1), diag.column);
    try testing.expectEqualStrings("hello", diag.source_line);
}

test "setError at end of input" {
    var diag: Diagnostics = .{};
    setError(&diag, "ab\ncd", 5, "TestError");
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectEqual(@as(usize, 3), diag.column);
    try testing.expectEqualStrings("cd", diag.source_line);
}
