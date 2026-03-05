const std = @import("std");

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
