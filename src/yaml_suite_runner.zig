//! YAML Test Suite runner. Parses grouped `.test` files (Toupee-style HTML
//! comment delimiters) and validates comb's output against the official
//! YAML Test Suite expected results.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const comb = @import("root.zig");

const ExpectedFailure = struct {
    id: []const u8,
    reason: FailureReason,
};

const FailureReason = enum {
    too_permissive,
    parse_error,
    json_mismatch,
    multi_doc_json,
};

const expected_failures: []const ExpectedFailure = &.{
    // Parser accepts invalid YAML that should be rejected
    .{ .id = "2CMS", .reason = .too_permissive },
    .{ .id = "3HFZ", .reason = .too_permissive },
    .{ .id = "4HVU", .reason = .too_permissive },
    .{ .id = "4JVG", .reason = .too_permissive },
    .{ .id = "5LLU", .reason = .too_permissive },
    .{ .id = "5TRB", .reason = .too_permissive },
    .{ .id = "5U3A", .reason = .too_permissive },
    .{ .id = "6S55", .reason = .too_permissive },
    .{ .id = "7LBH", .reason = .too_permissive },
    .{ .id = "8XDJ", .reason = .too_permissive },
    .{ .id = "9HCY", .reason = .too_permissive },
    .{ .id = "9KBC", .reason = .too_permissive },
    .{ .id = "9MMA", .reason = .too_permissive },
    .{ .id = "9MQT/01", .reason = .too_permissive },
    .{ .id = "B63P", .reason = .too_permissive },
    .{ .id = "BD7L", .reason = .too_permissive },
    .{ .id = "BF9H", .reason = .too_permissive },
    .{ .id = "BS4K", .reason = .too_permissive },
    .{ .id = "C2SP", .reason = .too_permissive },
    .{ .id = "CXX2", .reason = .too_permissive },
    .{ .id = "D49Q", .reason = .too_permissive },
    .{ .id = "DMG6", .reason = .too_permissive },
    .{ .id = "EB22", .reason = .too_permissive },
    .{ .id = "EW3V", .reason = .too_permissive },
    .{ .id = "GT5M", .reason = .too_permissive },
    .{ .id = "H7TQ", .reason = .too_permissive },
    .{ .id = "HU3P", .reason = .too_permissive },
    .{ .id = "JKF3", .reason = .too_permissive },
    .{ .id = "JY7Z", .reason = .too_permissive },
    .{ .id = "KS4U", .reason = .too_permissive },
    .{ .id = "LHL4", .reason = .too_permissive },
    .{ .id = "MUS6/00", .reason = .too_permissive },
    .{ .id = "MUS6/01", .reason = .too_permissive },
    .{ .id = "N4JP", .reason = .too_permissive },
    .{ .id = "Q4CL", .reason = .too_permissive },
    .{ .id = "QB6E", .reason = .too_permissive },
    .{ .id = "QLJ7", .reason = .too_permissive },
    .{ .id = "RXY3", .reason = .too_permissive },
    .{ .id = "S4GJ", .reason = .too_permissive },
    .{ .id = "S98Z", .reason = .too_permissive },
    .{ .id = "SF5V", .reason = .too_permissive },
    .{ .id = "SR86", .reason = .too_permissive },
    .{ .id = "SU5Z", .reason = .too_permissive },
    .{ .id = "SU74", .reason = .too_permissive },
    .{ .id = "SY6V", .reason = .too_permissive },
    .{ .id = "TD5N", .reason = .too_permissive },
    .{ .id = "U44R", .reason = .too_permissive },
    .{ .id = "U99R", .reason = .too_permissive },
    .{ .id = "W9L4", .reason = .too_permissive },
    .{ .id = "X4QW", .reason = .too_permissive },
    .{ .id = "ZCZ6", .reason = .too_permissive },
    .{ .id = "ZL4Z", .reason = .too_permissive },
    .{ .id = "ZVH3", .reason = .too_permissive },

};

fn isExpectedFailure(id: []const u8) ?FailureReason {
    for (expected_failures) |ef| {
        if (mem.eql(u8, ef.id, id)) return ef.reason;
    }
    return null;
}

const TestResults = struct {
    passed: usize = 0,
    expected_failures: usize = 0,
    unexpected_failures: usize = 0,
    unexpected_passes: usize = 0,

    fn total(self: TestResults) usize {
        return self.passed + self.expected_failures +
            self.unexpected_failures + self.unexpected_passes;
    }
};

const ParsedTestCase = struct {
    id: []const u8,
    in_yaml: []const u8,
    in_json: ?[]const u8,
    is_error: bool,
};

fn parseTestFile(alloc: Allocator, content: []const u8) ![]ParsedTestCase {
    var cases: std.ArrayList(ParsedTestCase) = .empty;

    const State = enum { idle, in_yaml, in_json };
    var state: State = .idle;
    var current_id: []const u8 = "";
    var is_error = false;
    var yaml_buf: std.ArrayList(u8) = .empty;
    var json_buf: std.ArrayList(u8) = .empty;

    var line_it = mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (mem.startsWith(u8, line, "<!-- test: ")) {
            if (state != .idle) {
                try finishCase(alloc, &cases, current_id, &yaml_buf, &json_buf, is_error);
            }
            current_id = extractId(line);
            is_error = false;
            state = .idle;
            yaml_buf = .empty;
            json_buf = .empty;
            continue;
        }

        if (mem.eql(u8, line, "<!-- error -->")) {
            is_error = true;
            continue;
        }

        if (mem.eql(u8, line, "<!-- in -->")) {
            state = .in_yaml;
            continue;
        }

        if (mem.eql(u8, line, "<!-- json -->")) {
            state = .in_json;
            continue;
        }

        switch (state) {
            .in_yaml => {
                if (yaml_buf.items.len > 0) try yaml_buf.append(alloc, '\n');
                try yaml_buf.appendSlice(alloc, line);
            },
            .in_json => {
                if (json_buf.items.len > 0) try json_buf.append(alloc, '\n');
                try json_buf.appendSlice(alloc, line);
            },
            .idle => {},
        }
    }

    if (current_id.len > 0 and state != .idle) {
        try finishCase(alloc, &cases, current_id, &yaml_buf, &json_buf, is_error);
    }

    return cases.items;
}

fn finishCase(
    alloc: Allocator,
    cases: *std.ArrayList(ParsedTestCase),
    id: []const u8,
    yaml_buf: *std.ArrayList(u8),
    json_buf: *std.ArrayList(u8),
    is_error: bool,
) !void {
    // Restore the trailing newline stripped by line-by-line parsing
    try yaml_buf.append(alloc, '\n');
    const yaml = try alloc.dupe(u8, yaml_buf.items);
    const json = if (json_buf.items.len > 0) try alloc.dupe(u8, json_buf.items) else null;
    try cases.append(alloc, .{
        .id = id,
        .in_yaml = yaml,
        .in_json = json,
        .is_error = is_error,
    });
}

fn extractId(line: []const u8) []const u8 {
    const open = mem.lastIndexOfScalar(u8, line, '[') orelse return "";
    const close = mem.lastIndexOfScalar(u8, line, ']') orelse return "";
    if (close <= open) return "";
    return line[open + 1 .. close];
}

fn recordResult(results: *TestResults, test_id: []const u8, failed: bool, detail: []const u8) void {
    if (!failed) {
        if (isExpectedFailure(test_id)) |reason| {
            results.unexpected_passes += 1;
            std.debug.print("  UNEXPECTED PASS: {s} (remove from expected_failures, was {s})\n", .{
                test_id, @tagName(reason),
            });
        } else {
            results.passed += 1;
        }
    } else {
        if (isExpectedFailure(test_id) != null) {
            results.expected_failures += 1;
        } else {
            results.unexpected_failures += 1;
            std.debug.print("  UNEXPECTED FAIL: {s}: {s}\n", .{ test_id, detail });
        }
    }
}

fn runSingleCase(
    allocator: Allocator,
    tc: ParsedTestCase,
    results: *TestResults,
) void {
    if (tc.is_error) {
        if (comb.parseFromSlice(std.json.Value, allocator, tc.in_yaml, .{ .duplicate_keys = .last_wins })) |*p| {
            p.deinit();
            recordResult(results, tc.id, true, "expected error, parsed OK");
        } else |_| {
            recordResult(results, tc.id, false, "");
        }
        return;
    }

    const json_expected = tc.in_json orelse {
        if (comb.parseFromSlice(std.json.Value, allocator, tc.in_yaml, .{ .duplicate_keys = .last_wins })) |*p| {
            p.deinit();
            recordResult(results, tc.id, false, "");
        } else |_| {
            recordResult(results, tc.id, true, "parse error (no json to compare)");
        }
        return;
    };

    // Try single-document comparison first
    if (std.json.parseFromSlice(std.json.Value, allocator, json_expected, .{})) |json_parsed| {
        defer json_parsed.deinit();

        var yaml_parsed = comb.parseFromSlice(std.json.Value, allocator, tc.in_yaml, .{ .duplicate_keys = .last_wins }) catch {
            recordResult(results, tc.id, true, "YAML parse error");
            return;
        };
        defer yaml_parsed.deinit();

        if (jsonEqual(yaml_parsed.value, json_parsed.value)) {
            recordResult(results, tc.id, false, "");
        } else {
            recordResult(results, tc.id, true, "JSON mismatch");
        }
        return;
    } else |_| {}

    // Single JSON parse failed -- try multi-document comparison
    runMultiDocCase(allocator, tc, json_expected, results);
}

fn runMultiDocCase(
    allocator: Allocator,
    tc: ParsedTestCase,
    json_expected: []const u8,
    results: *TestResults,
) void {
    const expected_values = parseMultiJsonValues(allocator, json_expected) catch {
        recordResult(results, tc.id, true, "cannot parse expected JSON");
        return;
    };

    var docs_parsed = comb.parseAll(allocator, tc.in_yaml, .{ .duplicate_keys = .last_wins }) catch {
        recordResult(results, tc.id, true, "YAML parse error (multi-doc)");
        return;
    };
    defer docs_parsed.deinit();

    if (docs_parsed.value.len != expected_values.len) {
        recordResult(results, tc.id, true, "document count mismatch");
        return;
    }

    for (docs_parsed.value, expected_values) |doc, exp| {
        const doc_json = doc.toStdJsonValue(allocator) catch {
            recordResult(results, tc.id, true, "failed to convert comb.Value to JSON");
            return;
        };
        if (!jsonEqual(doc_json, exp.value)) {
            recordResult(results, tc.id, true, "JSON mismatch (multi-doc)");
            return;
        }
    }

    recordResult(results, tc.id, false, "");
}

const JsonParsed = struct {
    value: std.json.Value,
    parsed: std.json.Parsed(std.json.Value),
};

fn parseMultiJsonValues(allocator: Allocator, json_str: []const u8) ![]JsonParsed {
    var values: std.ArrayList(JsonParsed) = .empty;
    var remaining = json_str;

    while (true) {
        remaining = mem.trimLeft(u8, remaining, " \t\n\r");
        if (remaining.len == 0) break;

        const end_pos = findJsonValueEnd(remaining) orelse return error.OutOfMemory;
        const slice = remaining[0..end_pos];
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch
            return error.OutOfMemory;
        try values.append(allocator, .{ .value = parsed.value, .parsed = parsed });
        remaining = remaining[end_pos..];
    }

    if (values.items.len < 2) return error.OutOfMemory;
    return values.items;
}

/// Find the byte position past the end of the first complete JSON value.
fn findJsonValueEnd(json: []const u8) ?usize {
    var i: usize = 0;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len) return null;

    switch (json[i]) {
        '{', '[' => {
            const open = json[i];
            const close: u8 = if (open == '{') '}' else ']';
            var depth: usize = 1;
            i += 1;
            while (i < json.len and depth > 0) {
                if (json[i] == '"') {
                    i += 1;
                    while (i < json.len and json[i] != '"') {
                        if (json[i] == '\\') i += 1;
                        i += 1;
                    }
                    if (i < json.len) i += 1;
                } else {
                    if (json[i] == open) depth += 1;
                    if (json[i] == close) depth -= 1;
                    i += 1;
                }
            }
            return i;
        },
        '"' => {
            i += 1;
            while (i < json.len and json[i] != '"') {
                if (json[i] == '\\') i += 1;
                i += 1;
            }
            if (i < json.len) i += 1;
            return i;
        },
        else => {
            // Number, true, false, null
            while (i < json.len and json[i] != '\n' and json[i] != '\r' and
                json[i] != ',' and json[i] != '}' and json[i] != ']') : (i += 1)
            {}
            return i;
        },
    }
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    const TagType = std.meta.Tag(std.json.Value);
    const at: TagType = a;
    const bt: TagType = b;
    if (at != bt) {
        if (at == .integer and bt == .float)
            return @as(f64, @floatFromInt(a.integer)) == b.float;
        if (at == .float and bt == .integer)
            return a.float == @as(f64, @floatFromInt(b.integer));
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => mem.eql(u8, a.string, b.string),
        .number_string => mem.eql(u8, a.number_string, b.number_string),
        .array => {
            if (a.array.items.len != b.array.items.len) return false;
            for (a.array.items, b.array.items) |ai, bi| {
                if (!jsonEqual(ai, bi)) return false;
            }
            return true;
        },
        .object => {
            if (a.object.count() != b.object.count()) return false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const bv = b.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonEqual(entry.value_ptr.*, bv)) return false;
            }
            return true;
        },
    };
}

test "YAML Test Suite conformance" {
    const alloc = std.testing.allocator;

    var suite_dir = std.fs.cwd().openDir("test/yaml-test-suite", .{ .iterate = true }) catch |err| {
        std.debug.print("\n  Could not open test/yaml-test-suite: {}\n", .{err});
        return;
    };
    defer suite_dir.close();

    var total = TestResults{};

    var dir_it = suite_dir.iterate();
    while (dir_it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.name, ".test")) continue;

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        const content = suite_dir.readFileAlloc(aa, entry.name, 4 * 1024 * 1024) catch continue;
        const cases = parseTestFile(aa, content) catch continue;

        for (cases) |tc| {
            runSingleCase(aa, tc, &total);
        }
    }

    std.debug.print("\n  YAML Test Suite: {d} passed, {d} expected failures, {d} unexpected ({d} total)\n", .{
        total.passed,
        total.expected_failures,
        total.unexpected_failures + total.unexpected_passes,
        total.total(),
    });

    if (total.unexpected_failures > 0 or total.unexpected_passes > 0) {
        std.debug.print("  ({d} unexpected failures, {d} unexpected passes)\n", .{
            total.unexpected_failures, total.unexpected_passes,
        });
    }

    std.debug.print("\n", .{});

    try std.testing.expectEqual(@as(usize, 0), total.unexpected_failures);
    try std.testing.expectEqual(@as(usize, 0), total.unexpected_passes);
}
