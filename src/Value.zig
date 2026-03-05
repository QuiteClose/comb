//! YAML value types with full fidelity: scalars, collections, binary, and tags.
//! Provides conversion to `std.json.Value` for JSON interop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// A key-value pair in a YAML mapping, preserving insertion order.
pub const Entry = struct {
    key: Value,
    value: Value,

    /// Comparator for sorting entries by string key. Non-string keys sort as empty string.
    pub fn keyLessThan(_: void, a: Entry, b: Entry) bool {
        const ak: []const u8 = switch (a.key) { .string => |s| s, else => "" };
        const bk: []const u8 = switch (b.key) { .string => |s| s, else => "" };
        return std.mem.order(u8, ak, bk) == .lt;
    }
};

/// A tagged YAML node (e.g. `!custom value`).
pub const Tagged = struct {
    tag: []const u8,
    value: *const Value,
};

/// A YAML value with full fidelity: scalars, collections, binary, and tags.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null_val: void,
    array: []const Value,
    object: []const Entry,
    binary: []const u8,
    tagged: Tagged,

    /// Convert to std.json.Value (lossy). YAML-only features are flattened:
    /// inf/nan -> null, binary -> base64 string, complex keys -> string,
    /// custom tags unwrapped.
    pub fn toStdJsonValue(self: Value, allocator: Allocator) error{OutOfMemory}!json.Value {
        return switch (self) {
            .string => |s| .{ .string = s },
            .integer => |i| .{ .integer = i },
            .float => |f| if (std.math.isNan(f) or std.math.isInf(f)) .null else .{ .float = f },
            .boolean => |b| .{ .bool = b },
            .null_val => .null,
            .array => |arr| {
                var json_arr = json.Array.init(allocator);
                try json_arr.ensureTotalCapacity(arr.len);
                for (arr) |item| {
                    json_arr.appendAssumeCapacity(try item.toStdJsonValue(allocator));
                }
                return .{ .array = json_arr };
            },
            .object => |entries| {
                var map = json.ObjectMap.init(allocator);
                try map.ensureTotalCapacity(@intCast(entries.len));
                for (entries) |entry| {
                    const key_str = try entry.key.toKeyString(allocator);
                    const val = try entry.value.toStdJsonValue(allocator);
                    map.putAssumeCapacity(key_str, val);
                }
                return .{ .object = map };
            },
            .binary => |data| .{ .string = data },
            .tagged => |t| t.value.toStdJsonValue(allocator),
        };
    }

    /// Convert a Value to a string for use as a JSON object key.
    pub fn toKeyString(self: Value, allocator: Allocator) error{OutOfMemory}![]const u8 {
        return switch (self) {
            .string => |s| s,
            .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| blk: {
                if (std.math.isNan(f)) break :blk try allocator.dupe(u8, ".nan");
                if (std.math.isInf(f)) break :blk try allocator.dupe(u8, if (f < 0) "-.inf" else ".inf");
                break :blk std.fmt.allocPrint(allocator, "{d}", .{f});
            },
            .boolean => |b| allocator.dupe(u8, if (b) "true" else "false"),
            .null_val => allocator.dupe(u8, "null"),
            else => {
                const jv = try self.toStdJsonValue(allocator);
                var out: std.io.Writer.Allocating = .init(allocator);
                errdefer out.deinit();
                var jw: json.Stringify = .{ .writer = &out.writer, .options = .{} };
                jw.write(jv) catch return error.OutOfMemory;
                return out.toOwnedSlice();
            },
        };
    }

    /// Deep structural equality. NaN == NaN for structural comparison.
    pub fn eql(self: Value, other: Value) bool {
        const self_tag: std.meta.Tag(Value) = self;
        const other_tag: std.meta.Tag(Value) = other;
        if (self_tag != other_tag) return false;

        return switch (self) {
            .string => |s| std.mem.eql(u8, s, other.string),
            .integer => |i| i == other.integer,
            .float => |f| {
                const of = other.float;
                if (std.math.isNan(f) and std.math.isNan(of)) return true;
                return f == of;
            },
            .boolean => |b| b == other.boolean,
            .null_val => true,
            .array => |arr| {
                const o = other.array;
                if (arr.len != o.len) return false;
                for (arr, o) |a, b| {
                    if (!a.eql(b)) return false;
                }
                return true;
            },
            .object => |entries| {
                const o = other.object;
                if (entries.len != o.len) return false;
                for (entries, o) |a, b| {
                    if (!a.key.eql(b.key) or !a.value.eql(b.value)) return false;
                }
                return true;
            },
            .binary => |data| std.mem.eql(u8, data, other.binary),
            .tagged => |t| {
                const ot = other.tagged;
                return std.mem.eql(u8, t.tag, ot.tag) and t.value.eql(ot.value.*);
            },
        };
    }

    /// Look up a key in an object. Returns null if self is not `.object`
    /// or if no entry has a `.string` key matching `key`.
    pub fn get(self: Value, key: []const u8) ?Value {
        const entries = switch (self) { .object => |o| o, else => return null };
        for (entries) |entry| {
            switch (entry.key) {
                .string => |k| if (std.mem.eql(u8, k, key)) return entry.value,
                else => {},
            }
        }
        return null;
    }

    /// Look up a string value by key. Returns null if the key is missing
    /// or the value is not `.string`.
    pub fn getStr(self: Value, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) { .string => |s| s, else => null };
    }

    /// Look up an array value by key. Returns null if the key is missing
    /// or the value is not `.array`.
    pub fn getArray(self: Value, key: []const u8) ?[]const Value {
        return switch (self.get(key) orelse return null) { .array => |a| a, else => null };
    }

    /// Look up an object value by key. Returns null if the key is missing
    /// or the value is not `.object`.
    pub fn getObject(self: Value, key: []const u8) ?[]const Entry {
        return switch (self.get(key) orelse return null) { .object => |o| o, else => null };
    }

    /// Debug formatting via std.fmt.
    pub fn format(self: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| {
                if (std.math.isNan(f)) return writer.writeAll(".nan");
                if (std.math.isInf(f)) return writer.writeAll(if (f < 0) "-.inf" else ".inf");
                try writer.print("{d}", .{f});
            },
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .null_val => try writer.writeAll("null"),
            .array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(']');
            },
            .object => |entries| {
                try writer.writeByte('{');
                for (entries, 0..) |entry, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try entry.key.format("", .{}, writer);
                    try writer.writeAll(": ");
                    try entry.value.format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .binary => |data| try writer.print("!!binary ({d} bytes)", .{data.len}),
            .tagged => |t| {
                try writer.print("{s} ", .{t.tag});
                try t.value.format("", .{}, writer);
            },
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "toStdJsonValue: scalars" {
    const alloc = std.testing.allocator;

    const str_json = try (Value{ .string = "hello" }).toStdJsonValue(alloc);
    try std.testing.expectEqualStrings("hello", str_json.string);

    const int_json = try (Value{ .integer = 42 }).toStdJsonValue(alloc);
    try std.testing.expectEqual(@as(i64, 42), int_json.integer);

    const flt_json = try (Value{ .float = 3.14 }).toStdJsonValue(alloc);
    try std.testing.expectEqual(@as(f64, 3.14), flt_json.float);

    const b_json = try (Value{ .boolean = true }).toStdJsonValue(alloc);
    try std.testing.expect(b_json.bool);

    const n_json = try (Value{ .null_val = {} }).toStdJsonValue(alloc);
    try std.testing.expectEqual(json.Value.null, n_json);
}

test "toStdJsonValue: inf and nan become null" {
    const alloc = std.testing.allocator;

    try std.testing.expectEqual(json.Value.null, try (Value{ .float = std.math.inf(f64) }).toStdJsonValue(alloc));
    try std.testing.expectEqual(json.Value.null, try (Value{ .float = -std.math.inf(f64) }).toStdJsonValue(alloc));
    try std.testing.expectEqual(json.Value.null, try (Value{ .float = std.math.nan(f64) }).toStdJsonValue(alloc));
}

test "toStdJsonValue: array" {
    const alloc = std.testing.allocator;
    const items = [_]Value{
        .{ .integer = 1 },
        .{ .string = "two" },
        .{ .boolean = false },
    };
    const result = try (Value{ .array = &items }).toStdJsonValue(alloc);
    var arr = result.array;
    defer arr.deinit();

    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].integer);
    try std.testing.expectEqualStrings("two", arr.items[1].string);
    try std.testing.expect(!arr.items[2].bool);
}

test "toStdJsonValue: object" {
    const alloc = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "Alice" } },
        .{ .key = .{ .string = "age" }, .value = .{ .integer = 30 } },
    };
    const result = try (Value{ .object = &entries }).toStdJsonValue(alloc);
    var m = result.object;
    defer m.deinit();

    try std.testing.expectEqualStrings("Alice", m.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 30), m.get("age").?.integer);
}

test "toStdJsonValue: binary returns original text" {
    const result = try (Value{ .binary = "aGVsbG8=" }).toStdJsonValue(std.testing.allocator);
    try std.testing.expectEqualStrings("aGVsbG8=", result.string);
}

test "toStdJsonValue: tagged unwraps" {
    const alloc = std.testing.allocator;
    const inner = Value{ .string = "data" };
    const result = try (Value{ .tagged = .{ .tag = "!custom", .value = &inner } }).toStdJsonValue(alloc);
    try std.testing.expectEqualStrings("data", result.string);
}

test "eql: matching values" {
    try std.testing.expect((Value{ .string = "abc" }).eql(.{ .string = "abc" }));
    try std.testing.expect((Value{ .integer = 42 }).eql(.{ .integer = 42 }));
    try std.testing.expect((Value{ .float = 1.5 }).eql(.{ .float = 1.5 }));
    try std.testing.expect((Value{ .boolean = true }).eql(.{ .boolean = true }));
    try std.testing.expect((Value{ .null_val = {} }).eql(.{ .null_val = {} }));
}

test "eql: non-matching values" {
    try std.testing.expect(!(Value{ .string = "abc" }).eql(.{ .string = "xyz" }));
    try std.testing.expect(!(Value{ .integer = 1 }).eql(.{ .integer = 2 }));
    try std.testing.expect(!(Value{ .string = "1" }).eql(.{ .integer = 1 }));
}

test "eql: NaN equals NaN" {
    const nan = Value{ .float = std.math.nan(f64) };
    try std.testing.expect(nan.eql(nan));
}

test "eql: arrays" {
    const a = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const b = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const c = [_]Value{ .{ .integer = 1 }, .{ .integer = 3 } };

    try std.testing.expect((Value{ .array = &a }).eql(.{ .array = &b }));
    try std.testing.expect(!(Value{ .array = &a }).eql(.{ .array = &c }));
}

test "eql: objects" {
    const a = [_]Entry{.{ .key = .{ .string = "k" }, .value = .{ .integer = 1 } }};
    const b = [_]Entry{.{ .key = .{ .string = "k" }, .value = .{ .integer = 1 } }};
    const c = [_]Entry{.{ .key = .{ .string = "k" }, .value = .{ .integer = 2 } }};

    try std.testing.expect((Value{ .object = &a }).eql(.{ .object = &b }));
    try std.testing.expect(!(Value{ .object = &a }).eql(.{ .object = &c }));
}

// ── Lookup method tests ─────────────────────────────────────────────────

const test_entries = [_]Entry{
    .{ .key = .{ .string = "name" }, .value = .{ .string = "Alice" } },
    .{ .key = .{ .string = "age" }, .value = .{ .integer = 30 } },
    .{ .key = .{ .string = "items" }, .value = .{ .array = &[_]Value{ .{ .integer = 1 }, .{ .integer = 2 } } } },
    .{ .key = .{ .string = "nested" }, .value = .{ .object = &[_]Entry{
        .{ .key = .{ .string = "x" }, .value = .{ .integer = 10 } },
    } } },
    .{ .key = .{ .integer = 42 }, .value = .{ .string = "int-key" } },
};

const test_obj = Value{ .object = &test_entries };
const empty_obj = Value{ .object = &[_]Entry{} };

test "get: finds existing key" {
    const val = test_obj.get("name").?;
    try std.testing.expectEqualStrings("Alice", val.string);
}

test "get: returns null for missing key" {
    try std.testing.expect(test_obj.get("missing") == null);
}

test "get: skips non-string keys" {
    try std.testing.expect(test_obj.get("42") == null);
}

test "get: returns null on non-object receiver" {
    try std.testing.expect((Value{ .string = "hello" }).get("x") == null);
    try std.testing.expect((Value{ .integer = 1 }).get("x") == null);
    try std.testing.expect((Value{ .null_val = {} }).get("x") == null);
    try std.testing.expect((Value{ .array = &[_]Value{} }).get("x") == null);
}

test "get: returns null on empty object" {
    try std.testing.expect(empty_obj.get("anything") == null);
}

test "getStr: returns string value" {
    try std.testing.expectEqualStrings("Alice", test_obj.getStr("name").?);
}

test "getStr: returns null for non-string value" {
    try std.testing.expect(test_obj.getStr("age") == null);
}

test "getStr: returns null for missing key" {
    try std.testing.expect(test_obj.getStr("missing") == null);
}

test "getStr: returns null on non-object receiver" {
    try std.testing.expect((Value{ .integer = 5 }).getStr("x") == null);
}

test "getStr: returns null on empty object" {
    try std.testing.expect(empty_obj.getStr("x") == null);
}

test "getArray: returns array value" {
    const arr = test_obj.getArray("items").?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
}

test "getArray: returns null for non-array value" {
    try std.testing.expect(test_obj.getArray("name") == null);
}

test "getArray: returns null for missing key" {
    try std.testing.expect(test_obj.getArray("missing") == null);
}

test "getArray: returns null on non-object receiver" {
    try std.testing.expect((Value{ .boolean = true }).getArray("x") == null);
}

test "getArray: returns null on empty object" {
    try std.testing.expect(empty_obj.getArray("x") == null);
}

test "getObject: returns object value" {
    const inner = test_obj.getObject("nested").?;
    try std.testing.expectEqual(@as(usize, 1), inner.len);
    try std.testing.expectEqualStrings("x", inner[0].key.string);
}

test "getObject: returns null for non-object value" {
    try std.testing.expect(test_obj.getObject("name") == null);
}

test "getObject: returns null for missing key" {
    try std.testing.expect(test_obj.getObject("missing") == null);
}

test "getObject: returns null on non-object receiver" {
    try std.testing.expect((Value{ .float = 1.0 }).getObject("x") == null);
}

test "getObject: returns null on empty object" {
    try std.testing.expect(empty_obj.getObject("x") == null);
}
