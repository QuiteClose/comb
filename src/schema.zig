//! YAML 1.2 Core Schema type detection and reserved-word classification.
//! Single source of truth for null/boolean/infinity/NaN string spellings
//! and scalar-to-typed-value resolution.

const std = @import("std");
const Value = @import("Value.zig").Value;

const null_strings = [_][]const u8{ "~", "null", "Null", "NULL" };
const true_strings = [_][]const u8{ "true", "True", "TRUE" };
const false_strings = [_][]const u8{ "false", "False", "FALSE" };
const pos_inf_strings = [_][]const u8{ ".inf", ".Inf", ".INF" };
const neg_inf_strings = [_][]const u8{ "-.inf", "-.Inf", "-.INF" };
const nan_strings = [_][]const u8{ ".nan", ".NaN", ".NAN" };

fn isOneOf(s: []const u8, comptime set: []const []const u8) bool {
    inline for (set) |candidate| {
        if (std.mem.eql(u8, s, candidate)) return true;
    }
    return false;
}

/// Resolve an unquoted scalar string to its YAML 1.2 Core Schema typed value.
/// Returns null, boolean, integer, float, or string based on the content.
pub fn detectScalarType(raw: []const u8) Value {
    if (raw.len == 0 or isOneOf(raw, &null_strings))
        return .{ .null_val = {} };

    if (isOneOf(raw, &true_strings)) return .{ .boolean = true };
    if (isOneOf(raw, &false_strings)) return .{ .boolean = false };

    if (isOneOf(raw, &pos_inf_strings)) return .{ .float = std.math.inf(f64) };
    if (isOneOf(raw, &neg_inf_strings)) return .{ .float = -std.math.inf(f64) };
    if (isOneOf(raw, &nan_strings)) return .{ .float = std.math.nan(f64) };

    if (raw.len >= 2 and raw[0] == '0' and raw[1] == 'o') {
        if (std.fmt.parseInt(i64, raw[2..], 8)) |v| return .{ .integer = v } else |_| {}
    }
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
        if (std.fmt.parseInt(i64, raw[2..], 16)) |v| return .{ .integer = v } else |_| {}
    }

    if (std.fmt.parseInt(i64, raw, 10)) |v| return .{ .integer = v } else |_| {}

    if (raw[0] == '-' or raw[0] == '+' or raw[0] == '.' or (raw[0] >= '0' and raw[0] <= '9')) {
        if (std.fmt.parseFloat(f64, raw)) |v| return .{ .float = v } else |_| {}
    }

    return .{ .string = raw };
}

/// Parse a string as a YAML boolean. Returns `null` if not a recognized boolean spelling.
pub fn parseBoolStr(s: []const u8) ?bool {
    if (isOneOf(s, &true_strings)) return true;
    if (isOneOf(s, &false_strings)) return false;
    return null;
}

/// Returns true if the string matches any YAML 1.2 reserved scalar spelling
/// (null, boolean, infinity, NaN). Used by the Renderer to decide when quoting is needed.
pub fn isReservedScalar(s: []const u8) bool {
    return isOneOf(s, &null_strings) or
        isOneOf(s, &true_strings) or
        isOneOf(s, &false_strings) or
        isOneOf(s, &pos_inf_strings) or
        isOneOf(s, &neg_inf_strings) or
        isOneOf(s, &nan_strings);
}

/// Returns true if the string could be parsed as a number by a YAML parser.
/// Used by the Renderer to decide when quoting is needed.
pub fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var start: usize = 0;
    if (s[0] == '-' or s[0] == '+') start = 1;
    if (start >= s.len) return false;
    if (s[start] == '.') return start + 1 < s.len and s[start + 1] >= '0' and s[start + 1] <= '9';
    return s[start] >= '0' and s[start] <= '9';
}

const testing = std.testing;

// ── detectScalarType tests ──────────────────────────────────────────────

test "detectScalarType: empty string is null" {
    try testing.expectEqual(Value{ .null_val = {} }, detectScalarType(""));
}

test "detectScalarType: null spellings" {
    const cases = [_][]const u8{ "~", "null", "Null", "NULL" };
    for (cases) |s| try testing.expectEqual(Value{ .null_val = {} }, detectScalarType(s));
}

test "detectScalarType: boolean spellings" {
    for ([_][]const u8{ "true", "True", "TRUE" }) |s|
        try testing.expectEqual(Value{ .boolean = true }, detectScalarType(s));
    for ([_][]const u8{ "false", "False", "FALSE" }) |s|
        try testing.expectEqual(Value{ .boolean = false }, detectScalarType(s));
}

test "detectScalarType: positive infinity" {
    for ([_][]const u8{ ".inf", ".Inf", ".INF" }) |s| {
        const v = detectScalarType(s);
        try testing.expect(v == .float and std.math.isInf(v.float) and v.float > 0);
    }
}

test "detectScalarType: negative infinity" {
    for ([_][]const u8{ "-.inf", "-.Inf", "-.INF" }) |s| {
        const v = detectScalarType(s);
        try testing.expect(v == .float and std.math.isInf(v.float) and v.float < 0);
    }
}

test "detectScalarType: NaN" {
    for ([_][]const u8{ ".nan", ".NaN", ".NAN" }) |s| {
        const v = detectScalarType(s);
        try testing.expect(v == .float and std.math.isNan(v.float));
    }
}

test "detectScalarType: decimal integers" {
    try testing.expectEqual(Value{ .integer = 0 }, detectScalarType("0"));
    try testing.expectEqual(Value{ .integer = 42 }, detectScalarType("42"));
    try testing.expectEqual(Value{ .integer = -7 }, detectScalarType("-7"));
    try testing.expectEqual(Value{ .integer = 1000000 }, detectScalarType("1000000"));
}

test "detectScalarType: octal integers" {
    try testing.expectEqual(Value{ .integer = 8 }, detectScalarType("0o10"));
    try testing.expectEqual(Value{ .integer = 255 }, detectScalarType("0o377"));
}

test "detectScalarType: hex integers" {
    try testing.expectEqual(Value{ .integer = 255 }, detectScalarType("0xFF"));
    try testing.expectEqual(Value{ .integer = 255 }, detectScalarType("0XFF"));
    try testing.expectEqual(Value{ .integer = 0 }, detectScalarType("0x0"));
}

test "detectScalarType: floats" {
    const v = detectScalarType("3.14");
    try testing.expect(v == .float and @abs(v.float - 3.14) < 1e-10);
    const neg = detectScalarType("-1.5");
    try testing.expect(neg == .float and @abs(neg.float - -1.5) < 1e-10);
}

test "detectScalarType: plain strings" {
    try testing.expectEqual(Value{ .string = "hello" }, detectScalarType("hello"));
    try testing.expectEqual(Value{ .string = "foo bar" }, detectScalarType("foo bar"));
    try testing.expectEqual(Value{ .string = "0o" }, detectScalarType("0o"));
    try testing.expectEqual(Value{ .string = "0x" }, detectScalarType("0x"));
    try testing.expectEqual(Value{ .string = "+" }, detectScalarType("+"));
    try testing.expectEqual(Value{ .string = "-" }, detectScalarType("-"));
}

// ── parseBoolStr tests ──────────────────────────────────────────────────

test "parseBoolStr: recognized booleans" {
    try testing.expectEqual(@as(?bool, true), parseBoolStr("true"));
    try testing.expectEqual(@as(?bool, true), parseBoolStr("True"));
    try testing.expectEqual(@as(?bool, true), parseBoolStr("TRUE"));
    try testing.expectEqual(@as(?bool, false), parseBoolStr("false"));
    try testing.expectEqual(@as(?bool, false), parseBoolStr("False"));
    try testing.expectEqual(@as(?bool, false), parseBoolStr("FALSE"));
}

test "parseBoolStr: non-booleans return null" {
    try testing.expectEqual(@as(?bool, null), parseBoolStr("yes"));
    try testing.expectEqual(@as(?bool, null), parseBoolStr("no"));
    try testing.expectEqual(@as(?bool, null), parseBoolStr("on"));
    try testing.expectEqual(@as(?bool, null), parseBoolStr("off"));
    try testing.expectEqual(@as(?bool, null), parseBoolStr(""));
    try testing.expectEqual(@as(?bool, null), parseBoolStr("TRUE "));
}

// ── isReservedScalar tests ──────────────────────────────────────────────

test "isReservedScalar: all reserved words" {
    const reserved = [_][]const u8{ "~", "null", "Null", "NULL", "true", "True", "TRUE", "false", "False", "FALSE", ".inf", ".Inf", ".INF", "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN" };
    for (reserved) |s| try testing.expect(isReservedScalar(s));
}

test "isReservedScalar: non-reserved words" {
    try testing.expect(!isReservedScalar("hello"));
    try testing.expect(!isReservedScalar("42"));
    try testing.expect(!isReservedScalar(""));
    try testing.expect(!isReservedScalar("yes"));
    try testing.expect(!isReservedScalar("inf"));
    try testing.expect(!isReservedScalar("nan"));
}

// ── looksLikeNumber tests ───────────────────────────────────────────────

test "looksLikeNumber: positive cases" {
    try testing.expect(looksLikeNumber("0"));
    try testing.expect(looksLikeNumber("42"));
    try testing.expect(looksLikeNumber("-1"));
    try testing.expect(looksLikeNumber("+3"));
    try testing.expect(looksLikeNumber(".5"));
    try testing.expect(looksLikeNumber("-.5"));
    try testing.expect(looksLikeNumber("3.14"));
    try testing.expect(looksLikeNumber("0x1F"));
}

test "looksLikeNumber: negative cases" {
    try testing.expect(!looksLikeNumber(""));
    try testing.expect(!looksLikeNumber("hello"));
    try testing.expect(!looksLikeNumber("+"));
    try testing.expect(!looksLikeNumber("-"));
    try testing.expect(!looksLikeNumber("."));
    try testing.expect(!looksLikeNumber("-."));
    try testing.expect(!looksLikeNumber(".a"));
}
