const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("Value.zig");
pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;
pub const Tagged = value_mod.Tagged;

pub const ParseOptions = struct {
    duplicate_keys: DuplicateKeyBehavior = .err,
    max_depth: ?u16 = 256,
    diagnostics: ?*Diagnostics = null,
};

pub const DuplicateKeyBehavior = enum {
    err,
    last_wins,
};

pub const Diagnostics = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
    source_line: []const u8 = "",
};

pub const OutputOptions = struct {
    sort_keys: bool = false,
    indent: u8 = 2,
};

pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

pub const Error = error{
    UnexpectedCharacter,
    UnexpectedEndOfInput,
    InvalidIndentation,
    DuplicateKey,
    MaxDepthExceeded,
    InvalidEscapeSequence,
    InvalidUtf8,
    InvalidNumber,
    InvalidTag,
    UndefinedAlias,
    CircularReference,
    UnclosedQuote,
    UnclosedFlowSequence,
    UnclosedFlowMapping,
    InvalidBlockScalar,
    InvalidDirective,
    InvalidAnchor,
    OutOfMemory,
};

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
pub fn parseAll(allocator: Allocator, input: []const u8) Error!Parsed([]const Value) {
    const Parser = @import("Parser.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var parser = Parser.init(aa, input, .{});
    const docs = try parser.parseAllDocuments();
    return .{ .arena = arena, .value = docs };
}

/// Parse YAML and return JSON string.
pub fn toJson(allocator: Allocator, input: []const u8, options: OutputOptions) Error![]const u8 {
    var parsed = try parse(allocator, input);
    defer parsed.deinit();
    return valueToJsonAlloc(allocator, parsed.value, options);
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

fn valueToJsonAlloc(allocator: Allocator, value: Value, options: OutputOptions) error{OutOfMemory}![]const u8 {
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
            std.mem.sortUnstable(Entry, sorted, {}, struct {
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

fn indentToWhitespace(indent: u8) std.json.Stringify.Options.Whitespace {
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
    _ = @import("Parser.zig");
    _ = @import("Renderer.zig");
}
