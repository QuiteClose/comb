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
