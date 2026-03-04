const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const Value = root.Value;
const Entry = root.Entry;

pub fn render(allocator: Allocator, value: Value, options: root.OutputOptions) root.Error![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    renderValue(allocator, &out.writer, value, 0, options, false) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn renderValue(allocator: Allocator, writer: *std.io.Writer, value: Value, indent_level: usize, options: root.OutputOptions, inline_first: bool) !void {
    switch (value) {
        .string => |s| try renderString(writer, s),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) {
                try writer.writeAll(".nan");
            } else if (std.math.isInf(f)) {
                try writer.writeAll(if (f < 0) "-.inf" else ".inf");
            } else {
                try writer.print("{d}", .{f});
            }
        },
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .null_val => try writer.writeAll("null"),
        .array => |arr| {
            if (arr.len == 0) {
                try writer.writeAll("[]");
                return;
            }
            for (arr, 0..) |item, idx| {
                if (idx > 0 or (!inline_first and indent_level > 0)) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, indent_level, options.indent);
                }
                try writer.writeAll("- ");
                if (isCollection(item)) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, indent_level + 1, options.indent);
                    try renderValue(allocator, writer, item, indent_level + 1, options, true);
                } else {
                    try renderValue(allocator, writer, item, indent_level + 1, options, false);
                }
            }
        },
        .object => |entries| {
            if (entries.len == 0) {
                try writer.writeAll("{}");
                return;
            }

            var sort_buf: ?[]Entry = null;
            defer if (sort_buf) |buf| allocator.free(buf);
            const sorted: []const Entry = if (options.sort_keys) blk: {
                sort_buf = try allocator.dupe(Entry, entries);
                std.mem.sortUnstable(Entry, sort_buf.?, {}, struct {
                    fn lessThan(_: void, a: Entry, b: Entry) bool {
                        const ak: []const u8 = switch (a.key) {
                            .string => |s| s,
                            else => "",
                        };
                        const bk: []const u8 = switch (b.key) {
                            .string => |s| s,
                            else => "",
                        };
                        return std.mem.order(u8, ak, bk) == .lt;
                    }
                }.lessThan);
                break :blk sort_buf.?;
            } else entries;

            for (sorted, 0..) |entry, idx| {
                if (idx > 0 or (!inline_first and indent_level > 0)) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, indent_level, options.indent);
                }
                switch (entry.key) {
                    .string => |s| try renderString(writer, s),
                    else => {
                        try writer.writeAll("? ");
                        try renderValue(allocator, writer, entry.key, indent_level + 1, options, false);
                        try writer.writeByte('\n');
                        try writeIndent(writer, indent_level, options.indent);
                    },
                }
                try writer.writeAll(": ");
                if (isCollection(entry.value)) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, indent_level + 1, options.indent);
                    try renderValue(allocator, writer, entry.value, indent_level + 1, options, true);
                } else {
                    try renderValue(allocator, writer, entry.value, indent_level + 1, options, false);
                }
            }
        },
        .binary => |data| {
            try writer.writeAll("!!binary |\n");
            const encoder = std.base64.standard.Encoder;
            const encoded_len = encoder.calcSize(data.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = encoder.encode(encoded, data);

            var i: usize = 0;
            while (i < encoded.len) {
                try writeIndent(writer, indent_level + 1, options.indent);
                const end = @min(i + 76, encoded.len);
                try writer.writeAll(encoded[i..end]);
                try writer.writeByte('\n');
                i = end;
            }
        },
        .tagged => |t| {
            try writer.writeAll(t.tag);
            try writer.writeByte(' ');
            try renderValue(allocator, writer, t.value.*, indent_level, options, false);
        },
    }
}

fn renderString(writer: *std.io.Writer, s: []const u8) !void {
    if (s.len == 0) {
        try writer.writeAll("''");
        return;
    }

    if (needsQuoting(s)) {
        if (needsDoubleQuoting(s)) {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => {
                        try writer.print("\\x{X:0>2}", .{c});
                    },
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        } else {
            try writer.writeByte('\'');
            for (s) |c| {
                if (c == '\'') {
                    try writer.writeAll("''");
                } else {
                    try writer.writeByte(c);
                }
            }
            try writer.writeByte('\'');
        }
    } else {
        try writer.writeAll(s);
    }
}

fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;

    const first = s[0];
    if (first == '-' or first == '?' or first == ':' or first == ',' or
        first == '[' or first == ']' or first == '{' or first == '}' or
        first == '#' or first == '&' or first == '*' or first == '!' or
        first == '|' or first == '>' or first == '\'' or first == '"' or
        first == '%' or first == '@' or first == '`')
    {
        return true;
    }

    if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL") or
        std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "TRUE") or
        std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "False") or std.mem.eql(u8, s, "FALSE") or
        std.mem.eql(u8, s, "~") or
        std.mem.eql(u8, s, ".inf") or std.mem.eql(u8, s, ".Inf") or std.mem.eql(u8, s, ".INF") or
        std.mem.eql(u8, s, "-.inf") or std.mem.eql(u8, s, "-.Inf") or std.mem.eql(u8, s, "-.INF") or
        std.mem.eql(u8, s, ".nan") or std.mem.eql(u8, s, ".NaN") or std.mem.eql(u8, s, ".NAN"))
    {
        return true;
    }

    for (s) |c| {
        if (c == ':' or c == '#' or c == '\n' or c == '\r') return true;
    }

    if (looksLikeNumber(s)) return true;

    return false;
}

fn needsDoubleQuoting(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 and c != '\t') return true;
        if (c == 0x7F) return true;
    }
    return false;
}

fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var start: usize = 0;
    if (s[0] == '-' or s[0] == '+') start = 1;
    if (start >= s.len) return false;
    if (s[start] == '.') return start + 1 < s.len and s[start + 1] >= '0' and s[start + 1] <= '9';
    return s[start] >= '0' and s[start] <= '9';
}

fn isCollection(value: Value) bool {
    return switch (value) {
        .array => |a| a.len > 0,
        .object => |o| o.len > 0,
        else => false,
    };
}

fn writeIndent(writer: *std.io.Writer, level: usize, indent_size: u8) !void {
    try writer.splatByteAll(' ', level * indent_size);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "render: scalars" {
    const alloc = std.testing.allocator;

    const str = try render(alloc, .{ .string = "hello" }, .{});
    defer alloc.free(str);
    try std.testing.expectEqualStrings("hello", str);

    const int = try render(alloc, .{ .integer = 42 }, .{});
    defer alloc.free(int);
    try std.testing.expectEqualStrings("42", int);

    const b = try render(alloc, .{ .boolean = true }, .{});
    defer alloc.free(b);
    try std.testing.expectEqualStrings("true", b);

    const n = try render(alloc, .{ .null_val = {} }, .{});
    defer alloc.free(n);
    try std.testing.expectEqualStrings("null", n);
}

test "render: quoted strings" {
    const alloc = std.testing.allocator;

    const reserved = try render(alloc, .{ .string = "true" }, .{});
    defer alloc.free(reserved);
    try std.testing.expectEqualStrings("'true'", reserved);

    const empty = try render(alloc, .{ .string = "" }, .{});
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("''", empty);
}

test "render: simple map" {
    const alloc = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "Alice" } },
        .{ .key = .{ .string = "age" }, .value = .{ .integer = 30 } },
    };
    const result = try render(alloc, .{ .object = &entries }, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("name: Alice\nage: 30", result);
}

test "render: simple array" {
    const alloc = std.testing.allocator;
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const result = try render(alloc, .{ .array = &items }, .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("- 1\n- 2\n- 3", result);
}

test "render: sort keys" {
    const alloc = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = .{ .string = "z" }, .value = .{ .integer = 1 } },
        .{ .key = .{ .string = "a" }, .value = .{ .integer = 2 } },
    };
    const result = try render(alloc, .{ .object = &entries }, .{ .sort_keys = true });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a: 2\nz: 1", result);
}

test "render: special floats" {
    const alloc = std.testing.allocator;

    const inf = try render(alloc, .{ .float = std.math.inf(f64) }, .{});
    defer alloc.free(inf);
    try std.testing.expectEqualStrings(".inf", inf);

    const nan = try render(alloc, .{ .float = std.math.nan(f64) }, .{});
    defer alloc.free(nan);
    try std.testing.expectEqualStrings(".nan", nan);
}

test "render: empty collections" {
    const alloc = std.testing.allocator;

    const empty_arr = try render(alloc, .{ .array = &[_]Value{} }, .{});
    defer alloc.free(empty_arr);
    try std.testing.expectEqualStrings("[]", empty_arr);

    const empty_obj = try render(alloc, .{ .object = &[_]Entry{} }, .{});
    defer alloc.free(empty_obj);
    try std.testing.expectEqualStrings("{}", empty_obj);
}
