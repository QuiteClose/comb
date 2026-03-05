//! Comb: YAML 1.2 parser, renderer, and JSON interop library for Zig.
//!
//! Parses YAML into either `comb.Value` (full YAML fidelity) or
//! `std.json.Value` (seamless JSON interop). Supports block and flow
//! collections, all scalar styles, anchors/aliases, merge keys, tags,
//! multi-document streams, and the YAML 1.2 Core Schema.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("Value.zig");
const opts = @import("options.zig");

/// A YAML value with full fidelity: scalars, collections, binary, and tags.
pub const Value = value_mod.Value;

/// A key-value pair in a YAML mapping, preserving insertion order.
pub const Entry = value_mod.Entry;

/// A tagged YAML node (e.g. `!custom value`).
pub const Tagged = value_mod.Tagged;

/// Options controlling how YAML is parsed.
pub const ParseOptions = opts.ParseOptions;

/// Strategy for handling duplicate keys within a single mapping.
pub const DuplicateKeyBehavior = opts.DuplicateKeyBehavior;

/// Error location details populated when parsing fails.
pub const Diagnostics = opts.Diagnostics;

/// Options controlling output formatting for JSON and YAML rendering.
pub const OutputOptions = opts.OutputOptions;

/// Wrapper for a parsed result that owns an arena allocator.
/// Call `deinit()` to free all memory when done.
pub const Parsed = opts.Parsed;

/// All errors that can occur during YAML parsing.
pub const Error = opts.Error;

/// Parse YAML into T (either std.json.Value or comb.Value).
/// When T is std.json.Value, returns std.json.Parsed for maximum interop.
pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: ParseOptions,
) Error!if (T == std.json.Value) std.json.Parsed(std.json.Value) else Parsed(T) {
    const Parser = @import("Parser.zig");

    if (T == std.json.Value) {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena_ptr.deinit();
            allocator.destroy(arena_ptr);
        }
        const aa = arena_ptr.allocator();
        var parser = Parser.init(aa, input, options);
        const comb_val = try parser.parseDocument();
        const json_val = try comb_val.toStdJsonValue(aa);
        return .{ .arena = arena_ptr, .value = json_val };
    } else {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var parser = Parser.init(aa, input, options);
        const val = try parser.parseDocument();
        return .{ .arena = arena, .value = val };
    }
}

/// Parse first YAML document into comb.Value.
pub fn parse(allocator: Allocator, input: []const u8) Error!Parsed(Value) {
    return parseFromSlice(Value, allocator, input, .{});
}

/// Parse all YAML documents.
pub fn parseAll(allocator: Allocator, input: []const u8, options: ParseOptions) Error!Parsed([]const Value) {
    const Parser = @import("Parser.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var parser = Parser.init(aa, input, options);
    const docs = try parser.parseAllDocuments();
    return .{ .arena = arena, .value = docs };
}

/// Parse YAML and return JSON string.
pub fn toJson(allocator: Allocator, input: []const u8, options: OutputOptions) Error![]const u8 {
    var parsed = try parse(allocator, input);
    defer parsed.deinit();
    return valueToJson(allocator, parsed.value, options);
}

/// Parse YAML and render back to normalized YAML.
pub fn toYaml(allocator: Allocator, input: []const u8, options: OutputOptions) Error![]const u8 {
    var parsed = try parse(allocator, input);
    defer parsed.deinit();
    return render(allocator, parsed.value, options);
}

/// Render a comb.Value to YAML string.
pub fn render(allocator: Allocator, value: Value, options: OutputOptions) Error![]const u8 {
    const Renderer = @import("Renderer.zig");
    return Renderer.render(allocator, value, options);
}

/// Serialize a comb.Value to a JSON string.
pub fn valueToJson(allocator: Allocator, value: Value, options: OutputOptions) error{OutOfMemory}![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const json_val = if (options.sort_keys)
        try sortedToStdJson(aa, value)
    else
        try value.toStdJsonValue(aa);

    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const ws = indentToWhitespace(options.indent);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = ws } };
    jw.write(json_val) catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn sortedToStdJson(allocator: Allocator, value: Value) error{OutOfMemory}!std.json.Value {
    switch (value) {
        .object => |entries| {
            const sorted = try allocator.dupe(Entry, entries);
            std.mem.sortUnstable(Entry, sorted, {}, Entry.keyLessThan);
            var map = std.json.ObjectMap.init(allocator);
            try map.ensureTotalCapacity(@intCast(sorted.len));
            for (sorted) |entry| {
                const key_str = try entry.key.toKeyString(allocator);
                const val = try sortedToStdJson(allocator, entry.value);
                map.putAssumeCapacity(key_str, val);
            }
            return .{ .object = map };
        },
        .array => |arr| {
            var json_arr = std.json.Array.init(allocator);
            try json_arr.ensureTotalCapacity(arr.len);
            for (arr) |item| {
                json_arr.appendAssumeCapacity(try sortedToStdJson(allocator, item));
            }
            return .{ .array = json_arr };
        },
        else => return value.toStdJsonValue(allocator),
    }
}

/// Convert an indent size to the corresponding `std.json.Stringify` whitespace option.
pub fn indentToWhitespace(indent: u8) @TypeOf(@as(std.json.Stringify.Options, .{}).whitespace) {
    return switch (indent) {
        0 => .minified,
        1 => .indent_1,
        2 => .indent_2,
        3 => .indent_3,
        4 => .indent_4,
        else => .indent_8,
    };
}

test {
    _ = value_mod;
    _ = opts;
    _ = @import("schema.zig");
    _ = @import("diagnostic.zig");
    _ = @import("Parser.zig");
    _ = @import("Renderer.zig");
    _ = @import("yaml_suite_runner.zig");
}

// ── Public API tests ────────────────────────────────────────────────────

const testing = std.testing;

test "parse: scalar string" {
    var p = try parse(testing.allocator, "hello world");
    defer p.deinit();
    try testing.expectEqualStrings("hello world", p.value.string);
}

test "parse: scalar integer" {
    var p = try parse(testing.allocator, "42");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 42), p.value.integer);
}

test "parse: scalar boolean" {
    var p = try parse(testing.allocator, "true");
    defer p.deinit();
    try testing.expect(p.value.boolean);
}

test "parse: scalar null" {
    var p = try parse(testing.allocator, "null");
    defer p.deinit();
    try testing.expectEqual(Value{ .null_val = {} }, p.value);
}

test "parse: mapping" {
    var p = try parse(testing.allocator, "a: 1\nb: 2\n");
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqual(@as(usize, 2), obj.len);
    try testing.expectEqualStrings("a", obj[0].key.string);
    try testing.expectEqual(@as(i64, 1), obj[0].value.integer);
    try testing.expectEqualStrings("b", obj[1].key.string);
    try testing.expectEqual(@as(i64, 2), obj[1].value.integer);
}

test "parse: sequence" {
    var p = try parse(testing.allocator, "- x\n- y\n");
    defer p.deinit();
    const arr = p.value.array;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("x", arr[0].string);
    try testing.expectEqualStrings("y", arr[1].string);
}

test "parse: error returns error" {
    const result = parse(testing.allocator, "[unclosed");
    try testing.expectError(error.UnclosedFlowSequence, result);
}

test "parseAll: multiple documents" {
    var p = try parseAll(testing.allocator, "hello\n---\nworld\n", .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.value.len);
    try testing.expectEqualStrings("hello", p.value[0].string);
    try testing.expectEqualStrings("world", p.value[1].string);
}

test "parseAll: single document" {
    var p = try parseAll(testing.allocator, "solo", .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.len);
    try testing.expectEqualStrings("solo", p.value[0].string);
}

test "parseAll: empty input" {
    var p = try parseAll(testing.allocator, "", .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.len);
    try testing.expectEqual(Value{ .null_val = {} }, p.value[0]);
}

test "parseFromSlice: comb.Value with default options" {
    var p = try parseFromSlice(Value, testing.allocator, "key: val", .{});
    defer p.deinit();
    try testing.expectEqualStrings("key", p.value.object[0].key.string);
    try testing.expectEqualStrings("val", p.value.object[0].value.string);
}

test "parseFromSlice: duplicate keys with .err" {
    const result = parseFromSlice(Value, testing.allocator, "a: 1\na: 2", .{ .duplicate_keys = .err });
    try testing.expectError(error.DuplicateKey, result);
}

test "parseFromSlice: duplicate keys with .last_wins" {
    var p = try parseFromSlice(Value, testing.allocator, "a: 1\na: 2", .{ .duplicate_keys = .last_wins });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.value.object.len);
    try testing.expectEqual(@as(i64, 1), p.value.object[0].value.integer);
    try testing.expectEqual(@as(i64, 2), p.value.object[1].value.integer);
}

test "parseFromSlice: max_depth exceeded" {
    const result = parseFromSlice(Value, testing.allocator, "a:\n  b:\n    c:\n      d: 1", .{ .max_depth = 2 });
    try testing.expectError(error.MaxDepthExceeded, result);
}

test "parseFromSlice: std.json.Value interop" {
    var p = try parseFromSlice(std.json.Value, testing.allocator, "name: Alice\nage: 30", .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("Alice", obj.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), obj.get("age").?.integer);
}

test "toJson: compact" {
    const json = try toJson(testing.allocator, "x: 1", .{ .indent = 0 });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"x\":1}", json);
}

test "toJson: pretty" {
    const json = try toJson(testing.allocator, "x: 1", .{ .indent = 2 });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\n  \"x\": 1\n}", json);
}

test "toYaml: roundtrip" {
    const input = "name: Alice\nage: 30\n";
    const yaml = try toYaml(testing.allocator, input, .{});
    defer testing.allocator.free(yaml);
    const json1 = try toJson(testing.allocator, input, .{ .sort_keys = true });
    defer testing.allocator.free(json1);
    const json2 = try toJson(testing.allocator, yaml, .{ .sort_keys = true });
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(json1, json2);
}

test "toYaml: idempotence" {
    const first = try toYaml(testing.allocator, "b: 2\na: 1\n", .{});
    defer testing.allocator.free(first);
    const second = try toYaml(testing.allocator, first, .{});
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

test "render: with sort_keys" {
    var p = try parse(testing.allocator, "c: 3\na: 1\nb: 2");
    defer p.deinit();
    const yaml = try render(testing.allocator, p.value, .{ .sort_keys = true });
    defer testing.allocator.free(yaml);
    const a_pos = std.mem.indexOf(u8, yaml, "a:").?;
    const b_pos = std.mem.indexOf(u8, yaml, "b:").?;
    const c_pos = std.mem.indexOf(u8, yaml, "c:").?;
    try testing.expect(a_pos < b_pos);
    try testing.expect(b_pos < c_pos);
}

test "render: without sort_keys preserves order" {
    var p = try parse(testing.allocator, "c: 3\na: 1\nb: 2");
    defer p.deinit();
    const yaml = try render(testing.allocator, p.value, .{});
    defer testing.allocator.free(yaml);
    const c_pos = std.mem.indexOf(u8, yaml, "c:").?;
    const a_pos = std.mem.indexOf(u8, yaml, "a:").?;
    const b_pos = std.mem.indexOf(u8, yaml, "b:").?;
    try testing.expect(c_pos < a_pos);
    try testing.expect(a_pos < b_pos);
}

test "toYaml: nested roundtrip fidelity" {
    const input = "users:\n- name: Alice\n  age: 30\n- name: Bob\n  age: 25\n";
    const yaml = try toYaml(testing.allocator, input, .{});
    defer testing.allocator.free(yaml);
    const json1 = try toJson(testing.allocator, input, .{ .sort_keys = true });
    defer testing.allocator.free(json1);
    const json2 = try toJson(testing.allocator, yaml, .{ .sort_keys = true });
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(json1, json2);
}

test "toYaml: special values roundtrip" {
    const input = "inf_val: .inf\nnan_val: .nan\nbool_val: true\nnull_val: null\n";
    const yaml = try toYaml(testing.allocator, input, .{});
    defer testing.allocator.free(yaml);
    const json1 = try toJson(testing.allocator, input, .{ .sort_keys = true });
    defer testing.allocator.free(json1);
    const json2 = try toJson(testing.allocator, yaml, .{ .sort_keys = true });
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(json1, json2);
}

test "toYaml: nested arrays roundtrip" {
    const input = "matrix:\n- - 1\n  - 2\n- - 3\n  - 4\n";
    const yaml = try toYaml(testing.allocator, input, .{});
    defer testing.allocator.free(yaml);
    const json1 = try toJson(testing.allocator, input, .{});
    defer testing.allocator.free(json1);
    const json2 = try toJson(testing.allocator, yaml, .{});
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(json1, json2);
}

test "valueToJson: compact" {
    var p = try parse(testing.allocator, "key: val");
    defer p.deinit();
    const json = try valueToJson(testing.allocator, p.value, .{ .indent = 0 });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"key\":\"val\"}", json);
}

test "valueToJson: with sort_keys" {
    var p = try parse(testing.allocator, "b: 2\na: 1");
    defer p.deinit();
    const json = try valueToJson(testing.allocator, p.value, .{ .sort_keys = true, .indent = 0 });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"a\":1,\"b\":2}", json);
}

test "valueToJson: custom indent" {
    var p = try parse(testing.allocator, "x: 1");
    defer p.deinit();
    const json = try valueToJson(testing.allocator, p.value, .{ .indent = 4 });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\n    \"x\": 1\n}", json);
}

test "indentToWhitespace: known values" {
    try testing.expectEqual(indentToWhitespace(0), .minified);
    try testing.expectEqual(indentToWhitespace(1), .indent_1);
    try testing.expectEqual(indentToWhitespace(2), .indent_2);
    try testing.expectEqual(indentToWhitespace(3), .indent_3);
    try testing.expectEqual(indentToWhitespace(4), .indent_4);
}

test "indentToWhitespace: large value falls back to indent_8" {
    try testing.expectEqual(indentToWhitespace(5), .indent_8);
    try testing.expectEqual(indentToWhitespace(8), .indent_8);
    try testing.expectEqual(indentToWhitespace(255), .indent_8);
}

test "diagnostics: populated on parse error" {
    var diag: Diagnostics = .{};
    const result = parseFromSlice(Value, testing.allocator, "key: [unclosed", .{ .diagnostics = &diag });
    try testing.expectError(error.UnclosedFlowSequence, result);
    try testing.expect(diag.line > 0);
    try testing.expect(diag.column > 0);
    try testing.expectEqualStrings("UnclosedFlowSequence", diag.message);
    try testing.expect(diag.source_line.len > 0);
}

test "diagnostics: not populated on success" {
    var diag: Diagnostics = .{};
    var p = try parseFromSlice(Value, testing.allocator, "ok: true", .{ .diagnostics = &diag });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), diag.line);
    try testing.expectEqualStrings("", diag.message);
}

// ── Regression tests ────────────────────────────────────────────────────

test "regression: parseAll accepts ParseOptions" {
    const result = parseAll(testing.allocator, "a: 1\na: 2\n", .{ .duplicate_keys = .err });
    try testing.expectError(error.DuplicateKey, result);
}

test "regression: parseAll with last_wins" {
    var p = try parseAll(testing.allocator, "a: 1\na: 2\n", .{ .duplicate_keys = .last_wins });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.len);
}

test "regression: complex key duplicate check" {
    const input = "? key1\n: val1\n? key1\n: val2\n";
    const result = parse(testing.allocator, input);
    try testing.expectError(error.DuplicateKey, result);
}

test "regression: whitespace-only string quoted in render" {
    const Renderer = @import("Renderer.zig");
    const rendered = try Renderer.render(testing.allocator, .{ .string = " " }, .{});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("' '", rendered);
}

test "regression: leading whitespace string quoted in render" {
    const Renderer = @import("Renderer.zig");
    const rendered = try Renderer.render(testing.allocator, .{ .string = " hello" }, .{});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("' hello'", rendered);
}

test "regression: trailing whitespace string quoted in render" {
    const Renderer = @import("Renderer.zig");
    const rendered = try Renderer.render(testing.allocator, .{ .string = "hello " }, .{});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("'hello '", rendered);
}

test "regression: block collection no trailing space" {
    const yaml = try toYaml(testing.allocator, "a:\n  b: 1\n", .{});
    defer testing.allocator.free(yaml);
    try testing.expect(std.mem.indexOf(u8, yaml, ": \n") == null);
    try testing.expect(std.mem.indexOf(u8, yaml, "a:\n") != null);
}

test "regression: whitespace roundtrip" {
    const Renderer = @import("Renderer.zig");
    const rendered = try Renderer.render(testing.allocator, .{ .string = "  spaces  " }, .{});
    defer testing.allocator.free(rendered);
    var p = try parse(testing.allocator, rendered);
    defer p.deinit();
    try testing.expectEqualStrings("  spaces  ", p.value.string);
}
