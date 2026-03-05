//! Configuration types, error sets, and result wrappers shared across all comb modules.
//! Extracted from root.zig so that Parser and Renderer can import these types
//! without a circular dependency on the public API facade.

const std = @import("std");

/// Options controlling how YAML is parsed.
pub const ParseOptions = struct {
    /// How duplicate mapping keys are handled.
    duplicate_keys: DuplicateKeyBehavior = .err,
    /// Maximum nesting depth (`null` for unlimited).
    max_depth: ?u16 = 256,
    /// If non-null, receives error location details on parse failure.
    diagnostics: ?*Diagnostics = null,
};

/// Strategy for handling duplicate keys within a single mapping.
pub const DuplicateKeyBehavior = enum {
    /// Return an error on duplicate keys.
    err,
    /// Silently keep the last value for duplicate keys.
    last_wins,
};

/// Error location details populated when parsing fails.
pub const Diagnostics = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
    source_line: []const u8 = "",
};

/// Options controlling output formatting for JSON and YAML rendering.
pub const OutputOptions = struct {
    /// Sort mapping keys alphabetically in output.
    sort_keys: bool = false,
    /// Number of spaces per indentation level.
    indent: u8 = 2,
};

/// Wrapper for a parsed result that owns an arena allocator.
/// Call `deinit()` to free all memory when done.
pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        /// Releases all memory allocated during parsing.
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// All errors that can occur during YAML parsing.
pub const Error = error{
    UnexpectedCharacter,
    UnexpectedEndOfInput,
    DuplicateKey,
    MaxDepthExceeded,
    InvalidEscapeSequence,
    InvalidNumber,
    InvalidTag,
    UndefinedAlias,
    UnclosedQuote,
    UnclosedFlowSequence,
    UnclosedFlowMapping,
    InvalidBlockScalar,
    InvalidAnchor,
    TabInIndentation,
    OutOfMemory,
};
