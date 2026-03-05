//! Recursive descent YAML 1.2 parser. Consumes a byte slice and produces
//! `Value` nodes. Handles block and flow collections, all scalar styles,
//! anchors/aliases, merge keys, tags, directives, and multi-document streams.

const std = @import("std");
const Allocator = std.mem.Allocator;
const opts = @import("options.zig");
const schema = @import("schema.zig");
const diagnostic = @import("diagnostic.zig");
const value_mod = @import("Value.zig");
const Value = value_mod.Value;
const Entry = value_mod.Entry;

// Test-only import: root.zig is used exclusively in the test blocks below.
const root = @import("root.zig");

const Parser = @This();

input: []const u8,
pos: usize,
allocator: Allocator,
options: opts.ParseOptions,
depth: u16,
anchors: std.StringHashMap(Value),
tag_handles: std.StringHashMap([]const u8),
last_scalar_multiline: bool,
seen_yaml_directive: bool,

/// Create a new parser for the given input with the specified options.
pub fn init(allocator: Allocator, input: []const u8, options: opts.ParseOptions) Parser {
    return .{
        .input = input,
        .pos = 0,
        .allocator = allocator,
        .options = options,
        .depth = 0,
        .anchors = std.StringHashMap(Value).init(allocator),
        .tag_handles = std.StringHashMap([]const u8).init(allocator),
        .last_scalar_multiline = false,
        .seen_yaml_directive = false,
    };
}

/// Parse a single YAML document from the input.
pub fn parseDocument(self: *Parser) opts.Error!Value {
    self.skipBom();
    self.skipWhitespaceAndComments();

    while (!self.atEnd() and self.startsWith("%")) {
        try self.parseDirective();
        self.skipWhitespaceAndComments();
    }

    if (self.seen_yaml_directive and (self.atEnd() or !self.isDocumentStartMarker()))
        return self.fail("UnexpectedCharacter");

    if (!self.atEnd() and self.isDocumentStartMarker()) {
        self.pos += 3;
        self.skipInlineSpace();
        if (!self.atEnd() and self.peek() == '#') self.skipToEndOfLine();
        self.skipNewline();
    }

    self.skipWhitespaceAndComments();
    if (self.atEnd()) return .{ .null_val = {} };
    if (self.startsWith("...")) return .{ .null_val = {} };

    const val = try self.parseNode(0);
    try self.rejectOrphanContent();
    return val;
}

/// Parse all YAML documents from the input as a multi-document stream.
pub fn parseAllDocuments(self: *Parser) opts.Error![]const Value {
    self.skipBom();
    var docs: std.ArrayList(Value) = .empty;
    var had_directives = false;
    var document_closed = true;

    while (true) {
        self.skipWhitespaceAndComments();
        if (self.atEnd()) {
            if (had_directives) return self.fail("UnexpectedCharacter");
            break;
        }

        if (self.isDocumentStartMarker()) {
            self.anchors.clearRetainingCapacity();
            if (!had_directives) self.tag_handles.clearRetainingCapacity();
            had_directives = false;
            self.seen_yaml_directive = false;
            document_closed = false;
            self.pos += 3;
            self.skipInlineSpace();
            if (!self.atEnd() and self.peek() == '#') self.skipToEndOfLine();
            if (!self.atEnd() and (self.peek() == '\n' or self.peek() == '\r')) {
                self.skipNewline();
                self.skipWhitespaceAndComments();
                if (self.atEnd() or self.isDocumentMarker()) {
                    docs.append(self.allocator, .{ .null_val = {} }) catch return error.OutOfMemory;
                } else {
                    const val = try self.parseNode(0);
                    try self.rejectOrphanContent();
                    docs.append(self.allocator, val) catch return error.OutOfMemory;
                }
            } else if (!self.atEnd() and !self.atEndOfLine()) {
                const val = try self.parseNode(0);
                try self.rejectOrphanContent();
                docs.append(self.allocator, val) catch return error.OutOfMemory;
            } else {
                docs.append(self.allocator, .{ .null_val = {} }) catch return error.OutOfMemory;
            }
        } else if (self.startsWith("...")) {
            if (had_directives) return self.fail("UnexpectedCharacter");
            self.pos += 3;
            self.skipToEndOfLine();
            self.skipNewline();
            document_closed = true;
        } else if (self.startsWith("%")) {
            if (!document_closed)
                return self.fail("UnexpectedCharacter");
            self.seen_yaml_directive = false;
            try self.parseDirective();
            had_directives = true;
        } else {
            const val = try self.parseNode(0);
            try self.rejectOrphanContent();
            docs.append(self.allocator, val) catch return error.OutOfMemory;
        }
    }

    if (docs.items.len == 0) {
        docs.append(self.allocator, .{ .null_val = {} }) catch return error.OutOfMemory;
    }

    return docs.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

// ── Core parsing ────────────────────────────────────────────────────────

fn parseNode(self: *Parser, min_col: usize) opts.Error!Value {
    self.skipWhitespaceAndComments();
    if (self.atEnd()) return .{ .null_val = {} };
    if (self.isDocumentMarker()) return .{ .null_val = {} };

    const col = self.currentCol();
    if (col < min_col) return .{ .null_val = {} };

    if (self.options.max_depth) |max| {
        if (self.depth >= max) return self.fail("MaxDepthExceeded");
    }

    var anchor_name: ?[]const u8 = null;
    var tag: ?[]const u8 = null;

    while (!self.atEnd()) {
        const c = self.peek();
        if (c == '&') {
            if (anchor_name != null) return self.fail("UnexpectedCharacter");
            anchor_name = try self.parseAnchorDef();
            self.skipInlineSpace();
        } else if (c == '!') {
            if (tag != null) return self.fail("UnexpectedCharacter");
            tag = try self.parseTag();
            self.skipInlineSpace();
        } else break;
    }

    if ((tag != null or anchor_name != null) and !self.atEnd() and !self.atEndOfLine()) {
        if (self.pos > 0 and self.input[self.pos - 1] != ' ' and self.input[self.pos - 1] != '\t')
            return self.fail("UnexpectedCharacter");
    }

    if (!self.atEnd() and self.peek() == '#') {
        self.skipToEndOfLine();
    }
    if (self.atEnd() or self.atEndOfLine()) {
        self.skipNewline();
        self.skipWhitespaceAndComments();
        if (self.atEnd()) return self.applyTagAndAnchor(.{ .null_val = {} }, tag, anchor_name);
        const next_col = self.currentCol();
        if (tag != null or anchor_name != null) {
            const cont_result = try self.parseNode(next_col);
            return self.applyTagAndAnchor(cont_result, tag, anchor_name);
        }
        if (next_col <= col) return .{ .null_val = {} };
        const result = try self.parseNode(next_col);
        return self.applyTagAndAnchor(result, tag, anchor_name);
    }

    const c = self.peek();
    var result: Value = undefined;

    if (c == '*') {
        if (anchor_name != null) return self.fail("UnexpectedCharacter");
        result = try self.parseAlias();
        self.skipInlineSpace();
        if (!self.atEnd() and !self.atEndOfLine() and self.peek() == ':' and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            result = try self.parseBlockMappingFromFirstKey(result, col);
        }
    } else if (c == '[') {
        result = try self.parseFlowSequence(min_col);
        try self.rejectTrailingFlowContent();
        self.skipInlineSpace();
        if (!self.atEnd() and !self.atEndOfLine() and self.peek() == ':' and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            if (tag) |t| { result = try self.applyTag(result, t); tag = null; }
            if (anchor_name) |name| { self.anchors.put(name, result) catch return error.OutOfMemory; anchor_name = null; }
            result = try self.parseBlockMappingFromFirstKey(result, col);
        }
    } else if (c == '{') {
        result = try self.parseFlowMapping(min_col);
        try self.rejectTrailingFlowContent();
        self.skipInlineSpace();
        if (!self.atEnd() and !self.atEndOfLine() and self.peek() == ':' and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            if (tag) |t| { result = try self.applyTag(result, t); tag = null; }
            if (anchor_name) |name| { self.anchors.put(name, result) catch return error.OutOfMemory; anchor_name = null; }
            result = try self.parseBlockMappingFromFirstKey(result, col);
        }
    } else if (c == '"') {
        const str = try self.parseDoubleQuoted(min_col);
        self.skipInlineSpace();
        if (!self.last_scalar_multiline and !self.atEnd() and !self.atEndOfLine() and self.peek() == ':' and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            var key: Value = .{ .string = str };
            if (tag) |t| { key = try self.applyTag(key, t); tag = null; }
            if (anchor_name) |name| { self.anchors.put(name, key) catch return error.OutOfMemory; anchor_name = null; }
            result = try self.parseBlockMappingFromFirstKey(key, col);
        } else {
            result = .{ .string = str };
        }
    } else if (c == '\'') {
        const str = try self.parseSingleQuoted(min_col);
        self.skipInlineSpace();
        if (!self.last_scalar_multiline and !self.atEnd() and !self.atEndOfLine() and self.peek() == ':' and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            var key: Value = .{ .string = str };
            if (tag) |t| { key = try self.applyTag(key, t); tag = null; }
            if (anchor_name) |name| { self.anchors.put(name, key) catch return error.OutOfMemory; anchor_name = null; }
            result = try self.parseBlockMappingFromFirstKey(key, col);
        } else {
            result = .{ .string = str };
        }
    } else if (c == '|' or c == '>') {
        const pi: ?usize = if (min_col > 0) min_col - 1 else null;
        result = try self.parseBlockScalar(pi);
    } else if (c == '?' and (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
        self.input[self.pos + 1] == '\t' or
        self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
    {
        result = try self.parseBlockMappingWithComplexKey(col);
    } else if (c == '-' and (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
        self.input[self.pos + 1] == '\t' or
        self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
    {
        result = try self.parseBlockSequence(col);
    } else if (c == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '<') {
        result = try self.parseBlockMapping(col);
    } else {
        const line_start = self.pos;
        const line = self.readToEndOfUnquotedLine();
        if (findKeyValueSep(line) != null) {
            self.pos = line_start;
            if (tag != null or anchor_name != null) {
                var key = try self.parseBlockMappingKey();
                if (tag) |t| key = try self.applyTag(key, t);
                if (anchor_name) |name| self.anchors.put(name, key) catch return error.OutOfMemory;
                return self.parseBlockMappingFromFirstKey(key, col);
            }
            result = try self.parseBlockMapping(col);
        } else {
            self.pos = line_start;
            result = try self.parsePlainScalar(min_col);
        }
    }

    return self.applyTagAndAnchor(result, tag, anchor_name);
}

fn applyTagAndAnchor(self: *Parser, value: Value, tag: ?[]const u8, anchor_name: ?[]const u8) opts.Error!Value {
    var result = value;

    if (tag) |t| {
        result = try self.applyTag(result, t);
    }

    if (anchor_name) |name| {
        self.anchors.put(name, result) catch return error.OutOfMemory;
    }

    return result;
}

fn applyTag(self: *Parser, value: Value, tag: []const u8) opts.Error!Value {
    if (std.mem.eql(u8, tag, "!") or std.mem.eql(u8, tag, "!!str")) {
        if (value == .null_val) return .{ .string = "" };
        return .{ .string = try self.valueToString(value) };
    } else if (std.mem.eql(u8, tag, "!!int")) {
        return switch (value) {
            .string => |s| .{ .integer = std.fmt.parseInt(i64, s, 0) catch return self.fail("InvalidNumber") },
            .integer => value,
            else => value,
        };
    } else if (std.mem.eql(u8, tag, "!!float")) {
        return switch (value) {
            .string => |s| .{ .float = std.fmt.parseFloat(f64, s) catch return self.fail("InvalidNumber") },
            .float => value,
            else => value,
        };
    } else if (std.mem.eql(u8, tag, "!!bool")) {
        return switch (value) {
            .string => |s| .{ .boolean = schema.parseBoolStr(s) orelse return self.fail("InvalidNumber") },
            .boolean => value,
            else => value,
        };
    } else if (std.mem.eql(u8, tag, "!!null")) {
        return .{ .null_val = {} };
    } else if (std.mem.eql(u8, tag, "!!binary")) {
        return switch (value) {
            .string => |s| .{ .binary = s },
            else => value,
        };
    } else if (std.mem.eql(u8, tag, "!!seq") or std.mem.eql(u8, tag, "!!map") or std.mem.eql(u8, tag, "!!set")) {
        return value;
    } else {
        const val_ptr = self.allocator.create(Value) catch return error.OutOfMemory;
        val_ptr.* = value;
        return .{ .tagged = .{ .tag = tag, .value = val_ptr } };
    }
}

fn valueToString(self: *Parser, value: Value) opts.Error![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch return error.OutOfMemory,
        .float => |f| std.fmt.allocPrint(self.allocator, "{d}", .{f}) catch return error.OutOfMemory,
        .boolean => |b| if (b) "true" else "false",
        .null_val => "null",
        else => "",
    };
}

// ── Block mapping ───────────────────────────────────────────────────────

fn parseBlockMapping(self: *Parser, indent: usize) opts.Error!Value {
    var entries: std.ArrayList(Entry) = .empty;
    try self.parseRemainingMappingEntries(&entries, indent);
    return .{ .object = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
}

fn parseBlockMappingFromFirstKey(self: *Parser, first_key: Value, indent: usize) opts.Error!Value {
    var entries: std.ArrayList(Entry) = .empty;

    self.pos += 1; // skip ':'
    self.skipInlineSpace();
    const first_value = try self.parseBlockMappingValue(indent);
    entries.append(self.allocator, .{ .key = first_key, .value = first_value }) catch return error.OutOfMemory;

    try self.parseRemainingMappingEntries(&entries, indent);

    return .{ .object = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
}

fn parseRemainingMappingEntries(self: *Parser, entries: *std.ArrayList(Entry), indent: usize) opts.Error!void {
    while (!self.atEnd()) {
        self.skipBlankAndCommentLines();
        if (self.atEnd()) break;
        if (self.isDocumentMarker()) break;

        try self.checkNoTabIndent();
        const col = self.currentCol();
        if (col != indent) break;

        if (self.peek() == '?' and (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ')) {
            self.pos += 1;
            if (!self.atEnd() and self.peek() == ' ') self.pos += 1;
            self.depth += 1;
            const key = try self.parseNode(indent + 1);
            self.depth -= 1;
            self.skipBlankAndCommentLines();
            var value: Value = .{ .null_val = {} };
            if (!self.atEnd() and self.currentCol() == indent and self.peek() == ':') {
                self.pos += 1;
                if (!self.atEnd() and self.peek() == ' ') self.pos += 1;
                self.skipInlineSpace();
                value = try self.parseBlockMappingValue(indent);
            }
            try self.checkDuplicateKey(entries.items, key);
            entries.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
            continue;
        }

        if (self.peek() == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '<') {
            self.pos += 2;
            self.skipInlineSpace();
            if (!self.atEnd() and self.peek() == ':') {
                self.pos += 1;
                self.skipInlineSpace();
                try self.parseMergeValue(entries, indent);
                continue;
            }
            self.pos -= 2;
        }

        var key_anchor: ?[]const u8 = null;
        var key_tag: ?[]const u8 = null;
        while (!self.atEnd()) {
            if (self.peek() == '&') {
                if (key_anchor != null) return self.fail("UnexpectedCharacter");
                key_anchor = try self.parseAnchorDef();
                self.skipInlineSpace();
            } else if (self.peek() == '!') {
                if (key_tag != null) return self.fail("UnexpectedCharacter");
                key_tag = try self.parseTag();
                self.skipInlineSpace();
            } else break;
        }
        var key: Value = undefined;
        if (!self.atEnd() and self.peek() == '*') {
            if (key_anchor != null) return self.fail("UnexpectedCharacter");
            key = try self.parseAlias();
            self.skipInlineSpace();
        } else {
            key = try self.parseBlockMappingKey();
        }
        if (key_tag) |t| key = try self.applyTag(key, t);
        if (key_anchor) |name| self.anchors.put(name, key) catch return error.OutOfMemory;
        self.skipInlineSpace();
        try self.consumeColon();
        self.skipInlineSpace();
        const value = try self.parseBlockMappingValue(indent);

        try self.checkDuplicateKey(entries.items, key);
        entries.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
    }
}

fn parseBlockMappingWithComplexKey(self: *Parser, indent: usize) opts.Error!Value {
    var entries: std.ArrayList(Entry) = .empty;

    while (!self.atEnd()) {
        self.skipBlankAndCommentLines();
        if (self.atEnd()) break;
        if (self.isDocumentMarker()) break;

        try self.checkNoTabIndent();
        const col = self.currentCol();
        if (col != indent) break;

        if (self.peek() == '?' and (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\t' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            self.pos += 1;
            if (!self.atEnd() and self.peek() == '\t') return self.fail("TabInIndentation");
            if (!self.atEnd() and self.peek() == ' ') self.pos += 1;

            self.depth += 1;
            const key = try self.parseNode(indent + 1);
            self.depth -= 1;

            self.skipBlankAndCommentLines();
            var value: Value = .{ .null_val = {} };
            if (!self.atEnd() and self.currentCol() == indent and self.peek() == ':') {
                self.pos += 1;
                if (!self.atEnd() and self.peek() == '\t') return self.fail("TabInIndentation");
                if (!self.atEnd() and self.peek() == ' ') self.pos += 1;
                self.skipInlineSpace();
                value = try self.parseBlockMappingValue(indent);
            }

            try self.checkDuplicateKey(entries.items, key);
            entries.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
        } else if (findKeyValueSep(self.readToEndOfUnquotedLineNoAdvance()) != null) {
            const key = try self.parseBlockMappingKey();
            try self.consumeColon();
            self.skipInlineSpace();
            const value = try self.parseBlockMappingValue(indent);
            try self.checkDuplicateKey(entries.items, key);
            entries.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
        } else {
            break;
        }
    }

    return .{ .object = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
}

fn parseMergeValue(self: *Parser, entries: *std.ArrayList(Entry), indent: usize) opts.Error!void {
    if (self.atEnd() or self.atEndOfLine()) {
        self.skipNewline();
        self.skipBlankAndCommentLines();
        if (!self.atEnd() and self.currentCol() > indent) {
            const val = try self.parseNode(indent + 1);
            try self.applyMerge(entries, val);
        }
        return;
    }

    if (self.peek() == '[') {
        const val = try self.parseFlowSequence(indent + 1);
        switch (val) {
            .array => |arr| {
                for (arr) |item| try self.applyMerge(entries, item);
            },
            else => try self.applyMerge(entries, val),
        }
    } else if (self.peek() == '*') {
        const val = try self.parseAlias();
        try self.applyMerge(entries, val);
    } else {
        const val = try self.parseBlockMappingValue(indent);
        try self.applyMerge(entries, val);
    }

    self.skipToEndOfLine();
    self.skipNewline();
}

fn applyMerge(self: *Parser, entries: *std.ArrayList(Entry), source: Value) opts.Error!void {
    switch (source) {
        .object => |src_entries| {
            for (src_entries) |src_entry| {
                var found = false;
                for (entries.items) |existing| {
                    if (existing.key.eql(src_entry.key)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    entries.append(self.allocator, src_entry) catch return error.OutOfMemory;
                }
            }
        },
        else => {},
    }
}

fn parseBlockMappingKey(self: *Parser) opts.Error!Value {
    if (self.atEnd()) return self.fail("UnexpectedEndOfInput");
    const c = self.peek();
    if (c == '"') {
        const str = try self.parseDoubleQuoted(0);
        if (self.last_scalar_multiline) return self.fail("UnexpectedCharacter");
        return .{ .string = str };
    }
    if (c == '\'') {
        const str = try self.parseSingleQuoted(0);
        if (self.last_scalar_multiline) return self.fail("UnexpectedCharacter");
        return .{ .string = str };
    }

    const start = self.pos;
    while (self.pos < self.input.len) {
        if (self.input[self.pos] == ':' and
            (self.pos + 1 >= self.input.len or self.input[self.pos + 1] == ' ' or
            self.input[self.pos + 1] == '\t' or
            self.input[self.pos + 1] == '\n' or self.input[self.pos + 1] == '\r'))
        {
            break;
        }
        if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') break;
        if (self.input[self.pos] == '#' and self.pos > start and
            (self.input[self.pos - 1] == ' ' or self.input[self.pos - 1] == '\t'))
        {
            break;
        }
        self.pos += 1;
    }

    const raw = std.mem.trimRight(u8, self.input[start..self.pos], " \t");
    return .{ .string = raw };
}

fn consumeColon(self: *Parser) opts.Error!void {
    if (self.atEnd() or self.peek() != ':') return self.fail("UnexpectedCharacter");
    self.pos += 1;
}

fn checkDuplicateKey(self: *Parser, items: []const Entry, key: Value) opts.Error!void {
    if (self.options.duplicate_keys == .err) {
        for (items) |existing| {
            if (existing.key.eql(key)) return self.fail("DuplicateKey");
        }
    }
}

fn parseBlockMappingValue(self: *Parser, map_indent: usize) opts.Error!Value {
    if (self.atEnd() or self.atEndOfLine()) {
        self.skipNewline();
        self.skipBlankAndCommentLines();
        if (self.atEnd()) return .{ .null_val = {} };
        const next_col = self.currentCol();
        if (next_col <= map_indent) {
            if (next_col == map_indent and self.isBlockSequenceIndicator()) {
                self.depth += 1;
                defer self.depth -= 1;
                return self.parseBlockSequence(next_col);
            }
            return .{ .null_val = {} };
        }
        self.depth += 1;
        defer self.depth -= 1;
        return self.parseNode(next_col);
    }

    if (self.peek() == '#') {
        self.skipToEndOfLine();
        self.skipNewline();
        self.skipBlankAndCommentLines();
        if (self.atEnd()) return .{ .null_val = {} };
        const next_col = self.currentCol();
        if (next_col <= map_indent) {
            if (next_col == map_indent and self.isBlockSequenceIndicator()) {
                self.depth += 1;
                defer self.depth -= 1;
                return self.parseBlockSequence(next_col);
            }
            return .{ .null_val = {} };
        }
        self.depth += 1;
        defer self.depth -= 1;
        return self.parseNode(next_col);
    }

    self.depth += 1;
    defer self.depth -= 1;

    const c = self.peek();
    if (c == '[') {
        const val = try self.parseFlowSequence(map_indent + 1);
        try self.rejectTrailingFlowContent();
        return val;
    }
    if (c == '{') {
        const val = try self.parseFlowMapping(map_indent + 1);
        try self.rejectTrailingFlowContent();
        return val;
    }
    if (c == '|' or c == '>') return self.parseBlockScalar(map_indent);
    if (c == '*') return self.parseAlias();
    if (c == '&') {
        const name = try self.parseAnchorDef();
        self.skipInlineSpace();
        if (self.atEnd() or self.atEndOfLine()) {
            self.skipNewline();
            self.skipBlankAndCommentLines();
            if (self.atEnd() or self.currentCol() <= map_indent) {
                self.anchors.put(name, .{ .null_val = {} }) catch return error.OutOfMemory;
                return .{ .null_val = {} };
            }
            const val = try self.parseNode(map_indent + 1);
            self.anchors.put(name, val) catch return error.OutOfMemory;
            return val;
        }
        if (!self.atEnd() and self.peek() == '*') return self.fail("UnexpectedCharacter");
        const val = try self.parseBlockMappingValue(map_indent);
        self.anchors.put(name, val) catch return error.OutOfMemory;
        return val;
    }
    if (c == '!') {
        const t = try self.parseTag();
        self.skipInlineSpace();
        const val = try self.parseBlockMappingValue(map_indent);
        return self.applyTag(val, t);
    }
    if (c == '"') {
        const str = try self.parseDoubleQuoted(map_indent + 1);
        try self.rejectTrailingQuotedContent();
        return .{ .string = str };
    }
    if (c == '\'') {
        const str = try self.parseSingleQuoted(map_indent + 1);
        try self.rejectTrailingQuotedContent();
        return .{ .string = str };
    }
    if (self.isBlockSequenceIndicator()) return self.parseBlockSequence(self.currentCol());

    return self.parsePlainScalar(map_indent + 1);
}

// ── Block sequence ──────────────────────────────────────────────────────

fn parseBlockSequence(self: *Parser, indent: usize) opts.Error!Value {
    var items: std.ArrayList(Value) = .empty;

    while (!self.atEnd()) {
        self.skipBlankAndCommentLines();
        if (self.atEnd()) break;
        if (self.isDocumentMarker()) break;

        try self.checkNoTabIndent();
        const col = self.currentCol();
        if (col != indent) break;
        if (self.peek() != '-') break;
        if (self.pos + 1 < self.input.len and self.input[self.pos + 1] != ' ' and
            self.input[self.pos + 1] != '\t' and
            self.input[self.pos + 1] != '\n' and self.input[self.pos + 1] != '\r')
        {
            break;
        }

        self.pos += 1;
        try self.rejectTabBeforeBlockIndicator();
        if (!self.atEnd() and self.peek() == ' ') self.pos += 1;
        try self.rejectTabBeforeBlockIndicator();

        self.depth += 1;
        defer self.depth -= 1;

        if (self.atEnd() or self.atEndOfLine()) {
            self.skipNewline();
            self.skipBlankAndCommentLines();
            if (self.atEnd() or self.currentCol() <= indent) {
                items.append(self.allocator, .{ .null_val = {} }) catch return error.OutOfMemory;
            } else {
                const val = try self.parseNode(indent + 1);
                items.append(self.allocator, val) catch return error.OutOfMemory;
            }
        } else {
            const val = try self.parseNode(indent + 1);
            items.append(self.allocator, val) catch return error.OutOfMemory;
        }
    }

    return .{ .array = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
}

// ── Flow collections ────────────────────────────────────────────────────

fn parseFlowSequence(self: *Parser, min_indent: usize) opts.Error!Value {
    if (self.atEnd() or self.peek() != '[') return self.fail("UnexpectedCharacter");
    self.pos += 1;
    self.depth += 1;
    defer self.depth -= 1;

    var items: std.ArrayList(Value) = .empty;

    try self.skipFlowWhitespace();

    if (!self.atEnd() and self.peek() == ']') {
        self.pos += 1;
        return .{ .array = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }
    if (!self.atEnd() and self.peek() == ',') return self.fail("UnexpectedCharacter");

    while (!self.atEnd()) {
        try self.skipFlowWhitespace();
        if (self.atEnd()) return self.fail("UnclosedFlowSequence");
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .array = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        }
        if (self.isDocumentMarker()) return self.fail("UnexpectedCharacter");
        try self.rejectFlowBelowIndent(min_indent);

        if (self.peek() == '?' and self.isFlowIndicatorNext()) {
            self.pos += 1;
            try self.skipFlowWhitespace();
            const key = try self.parseFlowValue();
            try self.skipFlowWhitespace();
            var value: Value = .{ .null_val = {} };
            if (!self.atEnd() and self.peek() == ':') {
                self.pos += 1;
                try self.skipFlowWhitespace();
                if (!self.atEnd() and self.peek() != ',' and self.peek() != ']')
                    value = try self.parseFlowValue();
            }
            const entry = [_]Entry{.{ .key = key, .value = value }};
            const owned = self.allocator.dupe(Entry, &entry) catch return error.OutOfMemory;
            items.append(self.allocator, .{ .object = owned }) catch return error.OutOfMemory;
        } else {
            const pre_val = self.pos;
            const val = try self.parseFlowValue();

            const pre_ws = self.pos;
            try self.skipFlowWhitespace();
            const adjacent = (self.pos == pre_ws);
            const crossed_line = std.mem.indexOfScalar(u8, self.input[pre_val..self.pos], '\n') != null or
                std.mem.indexOfScalar(u8, self.input[pre_val..self.pos], '\r') != null;
            if (!self.atEnd() and self.peek() == ':' and (adjacent or self.isFlowIndicatorNext())) {
                if (crossed_line) return self.fail("UnexpectedCharacter");
                self.pos += 1;
                try self.skipFlowWhitespace();
                const map_val = if (!self.atEnd() and self.peek() != ',' and self.peek() != ']')
                    try self.parseFlowValue()
                else
                    Value{ .null_val = {} };
                const entry = [_]Entry{.{ .key = val, .value = map_val }};
                const owned = self.allocator.dupe(Entry, &entry) catch return error.OutOfMemory;
                items.append(self.allocator, .{ .object = owned }) catch return error.OutOfMemory;
            } else {
                items.append(self.allocator, val) catch return error.OutOfMemory;
            }
        }

        try self.skipFlowWhitespace();
        if (self.atEnd()) return self.fail("UnclosedFlowSequence");
        if (self.peek() == ',') {
            self.pos += 1;
            try self.skipFlowWhitespace();
            if (!self.atEnd() and self.peek() == ',') return self.fail("UnexpectedCharacter");
        } else if (self.peek() != ']') {
            return self.fail("UnexpectedCharacter");
        }
    }

    return self.fail("UnclosedFlowSequence");
}

fn parseFlowMapping(self: *Parser, min_indent: usize) opts.Error!Value {
    if (self.atEnd() or self.peek() != '{') return self.fail("UnexpectedCharacter");
    self.pos += 1;
    self.depth += 1;
    defer self.depth -= 1;

    var entries: std.ArrayList(Entry) = .empty;

    try self.skipFlowWhitespace();

    if (!self.atEnd() and self.peek() == '}') {
        self.pos += 1;
        return .{ .object = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }
    if (!self.atEnd() and self.peek() == ',') return self.fail("UnexpectedCharacter");

    while (!self.atEnd()) {
        try self.skipFlowWhitespace();
        if (self.atEnd()) return self.fail("UnclosedFlowMapping");
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        }
        if (self.isDocumentMarker()) return self.fail("UnexpectedCharacter");
        try self.rejectFlowBelowIndent(min_indent);

        var key: Value = undefined;
        if (self.peek() == '?' and self.isFlowIndicatorNext()) {
            self.pos += 1;
            try self.skipFlowWhitespace();
            key = try self.parseFlowValue();
        } else {
            key = try self.parseFlowKey();
        }

        try self.skipFlowWhitespace();
        var value: Value = .{ .null_val = {} };
        if (!self.atEnd() and self.peek() == ':') {
            self.pos += 1;
            try self.skipFlowWhitespace();
            if (!self.atEnd() and self.peek() != ',' and self.peek() != '}') {
                value = try self.parseFlowValue();
            }
        }

        try self.checkDuplicateKey(entries.items, key);
        entries.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;

        try self.skipFlowWhitespace();
        if (self.atEnd()) return self.fail("UnclosedFlowMapping");
        if (self.peek() == ',') {
            self.pos += 1;
            try self.skipFlowWhitespace();
            if (!self.atEnd() and self.peek() == ',') return self.fail("UnexpectedCharacter");
        } else if (self.peek() != '}') {
            return self.fail("UnexpectedCharacter");
        }
    }

    return self.fail("UnclosedFlowMapping");
}

fn parseFlowValue(self: *Parser) opts.Error!Value {
    try self.skipFlowWhitespace();
    if (self.atEnd()) return .{ .null_val = {} };

    const c = self.peek();
    if (c == '[') return self.parseFlowSequence(0);
    if (c == '{') return self.parseFlowMapping(0);
    if (c == '"') return .{ .string = try self.parseDoubleQuoted(0) };
    if (c == '\'') return .{ .string = try self.parseSingleQuoted(0) };
    if (c == '*') return self.parseAlias();
    if (c == '-' or c == '?') {
        const next_pos = self.pos + 1;
        if (next_pos >= self.input.len) return self.fail("UnexpectedCharacter");
        const next = self.input[next_pos];
        if (next == ',' or next == ']' or next == '}' or next == ' ' or next == '\t' or
            next == '\n' or next == '\r') return self.fail("UnexpectedCharacter");
    }
    if (c == '#' or c == '|' or c == '>' or c == '%' or c == '@' or c == '`')
        return self.fail("UnexpectedCharacter");
    if (c == '&') {
        const name = try self.parseAnchorDef();
        try self.skipFlowWhitespace();
        const val = try self.parseFlowValue();
        self.anchors.put(name, val) catch return error.OutOfMemory;
        return val;
    }
    if (c == '!') {
        const t = try self.parseTag();
        try self.skipFlowWhitespace();
        const val = try self.parseFlowValue();
        return self.applyTag(val, t);
    }

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(self.allocator);

    while (true) {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ',' or ch == ']' or ch == '}' or ch == '\n' or ch == '\r') break;
            if (ch == ':') {
                if (self.pos + 1 >= self.input.len) break;
                const next = self.input[self.pos + 1];
                if (next == ' ' or next == '\t' or next == ',' or next == '[' or next == ']' or
                    next == '{' or next == '}' or next == '\n' or next == '\r') break;
                self.pos += 1;
                continue;
            }
            if (ch == '#' and self.pos > start and (self.input[self.pos - 1] == ' ' or self.input[self.pos - 1] == '\t')) break;
            self.pos += 1;
        }

        const raw = std.mem.trimRight(u8, self.input[start..self.pos], " \t");
        if (raw.len > 0) {
            parts.append(self.allocator, raw) catch return error.OutOfMemory;
        }

        if (self.pos >= self.input.len) break;
        const ch = self.input[self.pos];
        if (ch != '\n' and ch != '\r') break;

        self.skipNewline();
        self.skipInlineSpace();
        if (self.atEnd()) break;
        const nc = self.peek();
        if (nc == ',' or nc == ']' or nc == '}' or nc == '#') break;
    }

    if (parts.items.len == 0) return .{ .null_val = {} };
    if (parts.items.len == 1) return schema.detectScalarType(parts.items[0]);

    var result: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) result.append(self.allocator, ' ') catch return error.OutOfMemory;
        result.appendSlice(self.allocator, part) catch return error.OutOfMemory;
    }
    return schema.detectScalarType(result.toOwnedSlice(self.allocator) catch return error.OutOfMemory);
}

fn parseFlowKey(self: *Parser) opts.Error!Value {
    if (self.atEnd()) return self.fail("UnexpectedEndOfInput");
    const fc = self.peek();
    if (fc == '"') return .{ .string = try self.parseDoubleQuoted(0) };
    if (fc == '\'') return .{ .string = try self.parseSingleQuoted(0) };
    if (fc == '*') return self.parseAlias();
    if (fc == '!') {
        const t = try self.parseTag();
        try self.skipFlowWhitespace();
        if (self.atEnd() or self.peek() == ':' or self.peek() == ',' or self.peek() == '}')
            return self.applyTag(.{ .null_val = {} }, t);
        const val = try self.parseFlowKey();
        return self.applyTag(val, t);
    }
    if (fc == '&') {
        const name = try self.parseAnchorDef();
        try self.skipFlowWhitespace();
        const val = try self.parseFlowKey();
        self.anchors.put(name, val) catch return error.OutOfMemory;
        return val;
    }

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(self.allocator);

    while (true) {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ',' or ch == '}' or ch == '\n' or ch == '\r') break;
            if (ch == ':') {
                if (self.pos + 1 >= self.input.len) break;
                const next = self.input[self.pos + 1];
                if (next == ' ' or next == '\t' or next == ',' or next == '[' or next == ']' or
                    next == '{' or next == '}' or next == '\n' or next == '\r') break;
                self.pos += 1;
                continue;
            }
            if (ch == '#' and self.pos > start and (self.input[self.pos - 1] == ' ' or self.input[self.pos - 1] == '\t')) break;
            self.pos += 1;
        }

        const raw = std.mem.trimRight(u8, self.input[start..self.pos], " \t");
        if (raw.len > 0) {
            parts.append(self.allocator, raw) catch return error.OutOfMemory;
        }

        if (self.pos >= self.input.len) break;
        const ch = self.input[self.pos];
        if (ch != '\n' and ch != '\r') break;

        self.skipNewline();
        self.skipInlineSpace();
        if (self.atEnd()) break;
        const nc = self.peek();
        if (nc == ',' or nc == ']' or nc == '}' or nc == '#') break;
    }

    if (parts.items.len == 0) return .{ .string = "" };
    if (parts.items.len == 1) return schema.detectScalarType(parts.items[0]);

    var result: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) result.append(self.allocator, ' ') catch return error.OutOfMemory;
        result.appendSlice(self.allocator, part) catch return error.OutOfMemory;
    }
    return schema.detectScalarType(result.toOwnedSlice(self.allocator) catch return error.OutOfMemory);
}

// ── Block scalar ────────────────────────────────────────────────────────

fn parseBlockScalar(self: *Parser, parent_indent: ?usize) opts.Error!Value {
    if (self.atEnd()) return self.fail("InvalidBlockScalar");
    const style = self.peek();
    self.pos += 1;

    var chomp: enum { clip, strip, keep } = .clip;
    var explicit_indent: ?usize = null;

    while (!self.atEnd() and !self.atEndOfLine()) {
        const c = self.peek();
        if (c == '+') {
            chomp = .keep;
            self.pos += 1;
        } else if (c == '-') {
            chomp = .strip;
            self.pos += 1;
        } else if (c >= '1' and c <= '9') {
            explicit_indent = c - '0';
            self.pos += 1;
        } else if (c == ' ' or c == '#') {
            break;
        } else {
            return self.fail("InvalidBlockScalar");
        }
    }

    self.skipToEndOfLine();
    self.skipNewline();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(self.allocator);
    var content_indent: ?usize = null;
    if (explicit_indent) |ei| {
        content_indent = (parent_indent orelse 0) + ei;
    }

    while (self.pos < self.input.len) {
        if (self.startsWith("---") and self.currentCol() == 0) break;
        if (self.startsWith("...") and self.currentCol() == 0) break;

        const line_start = self.pos;
        const line_end = self.findEndOfLine();
        const line = self.input[line_start..line_end];

        if (line.len > 0 and line[0] == '\t')
            return self.fail("TabInIndentation");

        const stripped = std.mem.trimLeft(u8, line, " ");
        if (stripped.len == 0) {
            if (content_indent != null and line.len >= content_indent.?) {
                lines.append(self.allocator, line[content_indent.?..]) catch return error.OutOfMemory;
            } else {
                lines.append(self.allocator, "") catch return error.OutOfMemory;
            }
            self.pos = line_end;
            self.skipNewline();
            continue;
        }

        const line_indent = line.len - stripped.len;

        if (content_indent == null) {
            if (parent_indent) |pi| {
                if (line_indent <= pi) break;
            }
            content_indent = line_indent;
        } else if (lines.items.len == 0 and line_indent < content_indent.?) {
            if (explicit_indent != null) {
                content_indent = line_indent;
            } else {
                break;
            }
        }

        if (line_indent < content_indent.?) break;

        lines.append(self.allocator, line[content_indent.?..]) catch return error.OutOfMemory;
        self.pos = line_end;
        self.skipNewline();
    }

    var trailing_empties: usize = 0;
    while (trailing_empties < lines.items.len and lines.items[lines.items.len - 1 - trailing_empties].len == 0) {
        trailing_empties += 1;
    }
    const content_lines = lines.items[0 .. lines.items.len - trailing_empties];

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(self.allocator);

    if (style == '|') {
        for (content_lines, 0..) |line, i| {
            if (i > 0) result.append(self.allocator, '\n') catch return error.OutOfMemory;
            result.appendSlice(self.allocator, line) catch return error.OutOfMemory;
        }
    } else {
        const LineType = enum { normal, more_indented };

        var prev_type: ?LineType = null;
        var prev_blank = false;

        for (content_lines, 0..) |line, i| {
            if (line.len == 0) {
                if (!prev_blank and prev_type == .more_indented) {
                    result.append(self.allocator, '\n') catch return error.OutOfMemory;
                } else if (!prev_blank and prev_type == .normal) {
                    const next_nb_type = findNextNonblankType(content_lines, i + 1);
                    if (next_nb_type != null and next_nb_type.? != .normal) {
                        result.append(self.allocator, '\n') catch return error.OutOfMemory;
                    }
                }
                result.append(self.allocator, '\n') catch return error.OutOfMemory;
                prev_blank = true;
            } else {
                const cur_type: LineType = if (line[0] == ' ' or line[0] == '\t')
                    .more_indented
                else
                    .normal;

                if (prev_type != null and !prev_blank) {
                    if (prev_type.? == .normal and cur_type == .normal) {
                        result.append(self.allocator, ' ') catch return error.OutOfMemory;
                    } else {
                        result.append(self.allocator, '\n') catch return error.OutOfMemory;
                    }
                }

                result.appendSlice(self.allocator, line) catch return error.OutOfMemory;
                prev_type = cur_type;
                prev_blank = false;
            }
        }
    }

    switch (chomp) {
        .clip => {
            if (content_lines.len > 0) {
                result.append(self.allocator, '\n') catch return error.OutOfMemory;
            }
        },
        .keep => {
            if (content_lines.len > 0) {
                result.append(self.allocator, '\n') catch return error.OutOfMemory;
            }
            for (0..trailing_empties) |_| {
                result.append(self.allocator, '\n') catch return error.OutOfMemory;
            }
        },
        .strip => {},
    }

    return .{ .string = result.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
}

fn findNextNonblankType(content_lines: []const []const u8, start: usize) ?enum { normal, more_indented } {
    var j = start;
    while (j < content_lines.len) : (j += 1) {
        if (content_lines[j].len > 0) {
            return if (content_lines[j][0] == ' ' or content_lines[j][0] == '\t')
                .more_indented
            else
                .normal;
        }
    }
    return null;
}


// ── Scalar parsing ──────────────────────────────────────────────────────

fn parsePlainScalar(self: *Parser, min_col: usize) opts.Error!Value {
    const Part = struct { text: []const u8, blank_before: bool };
    var parts: std.ArrayList(Part) = .empty;
    defer parts.deinit(self.allocator);

    const first_line = self.readValueLine();
    if (first_line.len > 0) parts.append(self.allocator, .{ .text = first_line, .blank_before = false }) catch return error.OutOfMemory;
    self.skipNewline();

    while (!self.atEnd()) {
        const saved_pos = self.pos;
        var saw_blank = false;
        while (!self.atEnd()) {
            self.skipInlineSpace();
            if (self.atEnd()) break;
            if (self.input[self.pos] == '#') {
                self.skipToEndOfLine();
                self.skipNewline();
                continue;
            }
            if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                saw_blank = true;
                self.skipNewline();
                continue;
            }
            break;
        }
        if (self.atEnd()) break;
        if (self.isDocumentMarker()) break;
        const col = self.currentCol();
        if (col < min_col) break;

        const line = self.readToEndOfUnquotedLine();
        const trimmed = std.mem.trimRight(u8, line, " \t");
        if (findKeyValueSep(trimmed) != null) {
            self.pos = saved_pos;
            break;
        }

        if (trimmed.len > 0) {
            parts.append(self.allocator, .{ .text = trimmed, .blank_before = saw_blank }) catch return error.OutOfMemory;
            self.skipNewline();
        } else {
            self.pos = saved_pos;
            break;
        }
    }

    if (parts.items.len == 0) return .{ .null_val = {} };

    if (parts.items.len == 1) {
        return schema.detectScalarType(parts.items[0].text);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(self.allocator);
    for (parts.items, 0..) |part, i| {
        if (i > 0) {
            if (part.blank_before) {
                result.append(self.allocator, '\n') catch return error.OutOfMemory;
            } else {
                result.append(self.allocator, ' ') catch return error.OutOfMemory;
            }
        }
        result.appendSlice(self.allocator, part.text) catch return error.OutOfMemory;
    }
    return .{ .string = result.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
}

fn readValueLine(self: *Parser) []const u8 {
    const start = self.pos;
    while (self.pos < self.input.len) {
        if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') break;
        if (self.input[self.pos] == '#' and self.pos > start and (self.input[self.pos - 1] == ' ' or self.input[self.pos - 1] == '\t')) break;
        self.pos += 1;
    }
    return std.mem.trimRight(u8, self.input[start..self.pos], " \t");
}

// ── Quoted strings ──────────────────────────────────────────────────────

fn parseDoubleQuoted(self: *Parser, min_indent: usize) opts.Error![]const u8 {
    if (self.atEnd() or self.peek() != '"') return self.fail("UnclosedQuote");
    const quote_col = self.currentCol();
    self.pos += 1;
    self.last_scalar_multiline = false;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(self.allocator);
    var trailing_literal_ws: usize = 0;

    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == '"') {
            self.pos += 1;
            return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        }
        if (c == '\\') {
            trailing_literal_ws = 0;
            self.pos += 1;
            if (self.pos >= self.input.len) return self.fail("InvalidEscapeSequence");
            const esc = self.input[self.pos];
            self.pos += 1;
            switch (esc) {
                '0' => result.append(self.allocator, 0) catch return error.OutOfMemory,
                'a' => result.append(self.allocator, 0x07) catch return error.OutOfMemory,
                'b' => result.append(self.allocator, 0x08) catch return error.OutOfMemory,
                't', '\t' => result.append(self.allocator, '\t') catch return error.OutOfMemory,
                'n' => result.append(self.allocator, '\n') catch return error.OutOfMemory,
                'v' => result.append(self.allocator, 0x0B) catch return error.OutOfMemory,
                'f' => result.append(self.allocator, 0x0C) catch return error.OutOfMemory,
                'r' => result.append(self.allocator, '\r') catch return error.OutOfMemory,
                'e' => result.append(self.allocator, 0x1B) catch return error.OutOfMemory,
                ' ' => result.append(self.allocator, ' ') catch return error.OutOfMemory,
                '"' => result.append(self.allocator, '"') catch return error.OutOfMemory,
                '/' => result.append(self.allocator, '/') catch return error.OutOfMemory,
                '\\' => result.append(self.allocator, '\\') catch return error.OutOfMemory,
                'N' => try self.appendUtf8(&result, 0x85),
                '_' => try self.appendUtf8(&result, 0xA0),
                'L' => try self.appendUtf8(&result, 0x2028),
                'P' => try self.appendUtf8(&result, 0x2029),
                'x' => {
                    const cp = self.parseHexEscape(2) orelse return self.fail("InvalidEscapeSequence");
                    try self.appendUtf8(&result, cp);
                },
                'u' => {
                    const cp = self.parseHexEscape(4) orelse return self.fail("InvalidEscapeSequence");
                    try self.appendUtf8(&result, cp);
                },
                'U' => {
                    const cp = self.parseHexEscape(8) orelse return self.fail("InvalidEscapeSequence");
                    try self.appendUtf8(&result, cp);
                },
                '\n' => self.skipInlineSpace(),
                '\r' => {
                    if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                    self.skipInlineSpace();
                },
                else => return self.fail("InvalidEscapeSequence"),
            }
        } else if (c == '\n' or c == '\r') {
            self.last_scalar_multiline = true;
            result.items.len -|= trailing_literal_ws;
            trailing_literal_ws = 0;
            self.pos += 1;
            if (c == '\r' and self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
            if (quote_col > 0 and self.pos < self.input.len and self.input[self.pos] == '\t' and self.isAtLineStart())
                return self.fail("TabInIndentation");
            var blank_count: usize = 0;
            while (self.pos < self.input.len) {
                self.skipInlineSpace();
                if (self.pos >= self.input.len) break;
                if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                    blank_count += 1;
                    if (self.input[self.pos] == '\r') self.pos += 1;
                    if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                    if (quote_col > 0 and self.pos < self.input.len and self.input[self.pos] == '\t' and self.isAtLineStart())
                        return self.fail("TabInIndentation");
                } else break;
            }
            if (self.isAtLineStart() and self.isDocumentMarker())
                return self.fail("UnexpectedCharacter");
            if (min_indent > 0 and self.currentCol() < min_indent)
                return self.fail("UnexpectedCharacter");
            if (blank_count > 0) {
                for (0..blank_count) |_| {
                    result.append(self.allocator, '\n') catch return error.OutOfMemory;
                }
            } else {
                result.append(self.allocator, ' ') catch return error.OutOfMemory;
            }
        } else {
            if (c == ' ' or c == '\t') {
                trailing_literal_ws += 1;
            } else {
                trailing_literal_ws = 0;
            }
            result.append(self.allocator, c) catch return error.OutOfMemory;
            self.pos += 1;
        }
    }

    return self.fail("UnclosedQuote");
}

fn parseSingleQuoted(self: *Parser, min_indent: usize) opts.Error![]const u8 {
    if (self.atEnd() or self.peek() != '\'') return self.fail("UnclosedQuote");
    const quote_col = self.currentCol();
    self.pos += 1;
    self.last_scalar_multiline = false;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(self.allocator);
    var trailing_literal_ws: usize = 0;

    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == '\'') {
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                trailing_literal_ws = 0;
                result.append(self.allocator, '\'') catch return error.OutOfMemory;
                self.pos += 2;
            } else {
                self.pos += 1;
                return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            }
        } else if (c == '\n' or c == '\r') {
            self.last_scalar_multiline = true;
            result.items.len -|= trailing_literal_ws;
            trailing_literal_ws = 0;
            self.pos += 1;
            if (c == '\r' and self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
            if (quote_col > 0 and self.pos < self.input.len and self.input[self.pos] == '\t' and self.isAtLineStart())
                return self.fail("TabInIndentation");
            var blank_count: usize = 0;
            while (self.pos < self.input.len) {
                self.skipInlineSpace();
                if (self.pos >= self.input.len) break;
                if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                    blank_count += 1;
                    if (self.input[self.pos] == '\r') self.pos += 1;
                    if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                    if (quote_col > 0 and self.pos < self.input.len and self.input[self.pos] == '\t' and self.isAtLineStart())
                        return self.fail("TabInIndentation");
                } else break;
            }
            if (self.isAtLineStart() and self.isDocumentMarker())
                return self.fail("UnexpectedCharacter");
            if (min_indent > 0 and self.currentCol() < min_indent)
                return self.fail("UnexpectedCharacter");
            if (blank_count > 0) {
                for (0..blank_count) |_| {
                    result.append(self.allocator, '\n') catch return error.OutOfMemory;
                }
            } else {
                result.append(self.allocator, ' ') catch return error.OutOfMemory;
            }
        } else {
            if (c == ' ' or c == '\t') {
                trailing_literal_ws += 1;
            } else {
                trailing_literal_ws = 0;
            }
            result.append(self.allocator, c) catch return error.OutOfMemory;
            self.pos += 1;
        }
    }

    return self.fail("UnclosedQuote");
}

fn parseHexEscape(self: *Parser, digits: u8) ?u21 {
    if (self.pos + digits > self.input.len) return null;
    const hex = self.input[self.pos..][0..digits];
    self.pos += digits;
    return std.fmt.parseInt(u21, hex, 16) catch return null;
}

fn appendUtf8(self: *Parser, list: *std.ArrayList(u8), codepoint: u21) opts.Error!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return self.fail("InvalidEscapeSequence");
    list.appendSlice(self.allocator, buf[0..len]) catch return error.OutOfMemory;
}

// ── Anchors and aliases ─────────────────────────────────────────────────

fn parseAnchorDef(self: *Parser) opts.Error![]const u8 {
    if (self.atEnd() or self.peek() != '&') return self.fail("InvalidAnchor");
    self.pos += 1;
    const start = self.pos;
    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
            c == ',' or c == ']' or c == '}' or c == '{' or c == '[')
        {
            break;
        }
        self.pos += 1;
    }
    if (self.pos == start) return self.fail("InvalidAnchor");
    return self.input[start..self.pos];
}

fn parseAlias(self: *Parser) opts.Error!Value {
    if (self.atEnd() or self.peek() != '*') return self.fail("UndefinedAlias");
    self.pos += 1;
    const start = self.pos;
    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
            c == ',' or c == ']' or c == '}' or c == '{' or c == '[')
        {
            break;
        }
        self.pos += 1;
    }
    const name = self.input[start..self.pos];
    if (name.len == 0) return self.fail("UndefinedAlias");
    return self.anchors.get(name) orelse return self.fail("UndefinedAlias");
}

// ── Tags ────────────────────────────────────────────────────────────────

fn parseTag(self: *Parser) opts.Error![]const u8 {
    if (self.atEnd() or self.peek() != '!') return self.fail("InvalidTag");
    self.pos += 1;
    if (self.pos < self.input.len and self.input[self.pos] == '<') {
        self.pos += 1;
        const uri_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
        const uri = self.input[uri_start..self.pos];
        if (self.pos < self.input.len) self.pos += 1;
        const yaml_ns = "tag:yaml.org,2002:";
        if (std.mem.startsWith(u8, uri, yaml_ns)) {
            const suffix = uri[yaml_ns.len..];
            if (std.mem.eql(u8, suffix, "str")) return "!!str";
            if (std.mem.eql(u8, suffix, "int")) return "!!int";
            if (std.mem.eql(u8, suffix, "float")) return "!!float";
            if (std.mem.eql(u8, suffix, "bool")) return "!!bool";
            if (std.mem.eql(u8, suffix, "null")) return "!!null";
            if (std.mem.eql(u8, suffix, "map")) return "!!map";
            if (std.mem.eql(u8, suffix, "seq")) return "!!seq";
            if (std.mem.eql(u8, suffix, "set")) return "!!set";
            if (std.mem.eql(u8, suffix, "binary")) return "!!binary";
        }
        return uri;
    }
    const start = self.pos - 1;
    if (self.pos < self.input.len and self.input[self.pos] == '!') self.pos += 1;
    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
            c == ',' or c == '[' or c == ']' or c == '{' or c == '}') break;
        self.pos += 1;
    }
    const tag_text = self.input[start..self.pos];

    if (std.mem.startsWith(u8, tag_text, "!!")) {
        if (self.tag_handles.get("!!")) |prefix| {
            const default_ns = "tag:yaml.org,2002:";
            if (!std.mem.eql(u8, prefix, default_ns)) {
                const suffix = tag_text[2..];
                const resolved = self.allocator.alloc(u8, prefix.len + suffix.len) catch return error.OutOfMemory;
                @memcpy(resolved[0..prefix.len], prefix);
                @memcpy(resolved[prefix.len..], suffix);
                return resolved;
            }
        }
    } else if (tag_text.len > 1 and tag_text[0] == '!') {
        if (std.mem.indexOfScalar(u8, tag_text[1..], '!')) |end| {
            const handle = tag_text[0 .. end + 2];
            if (!std.mem.eql(u8, handle, "!!")) {
                const prefix = self.tag_handles.get(handle) orelse return self.fail("InvalidTag");
                const suffix = tag_text[end + 2 ..];
                const resolved = self.allocator.alloc(u8, prefix.len + suffix.len) catch return error.OutOfMemory;
                @memcpy(resolved[0..prefix.len], prefix);
                @memcpy(resolved[prefix.len..], suffix);
                return resolved;
            }
        }
    }

    return tag_text;
}

// ── Directives ──────────────────────────────────────────────────────────

fn parseDirective(self: *Parser) opts.Error!void {
    if (self.startsWith("%YAML") and (self.pos + 5 >= self.input.len or
        self.input[self.pos + 5] == ' ' or self.input[self.pos + 5] == '\t'))
    {
        if (self.seen_yaml_directive) return self.fail("UnexpectedCharacter");
        self.seen_yaml_directive = true;
        self.pos += 5;
        self.skipInlineSpace();
        const ver_start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        const version = self.input[ver_start..self.pos];
        if (version.len == 0) return self.fail("UnexpectedCharacter");
        if (!isValidYamlVersion(version)) return self.fail("UnexpectedCharacter");
        self.skipInlineSpace();
        if (!self.atEnd() and !self.atEndOfLine()) {
            if (self.peek() != '#') return self.fail("UnexpectedCharacter");
        }
    } else if (self.startsWith("%TAG")) {
        self.pos += 4;
        self.skipInlineSpace();
        const handle_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != ' ' and self.input[self.pos] != '\t')
            self.pos += 1;
        const handle = self.input[handle_start..self.pos];
        self.skipInlineSpace();
        const prefix_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != ' ' and
            self.input[self.pos] != '\t' and self.input[self.pos] != '\n' and
            self.input[self.pos] != '\r' and self.input[self.pos] != '#')
            self.pos += 1;
        const prefix = self.input[prefix_start..self.pos];
        if (handle.len > 0 and prefix.len > 0)
            self.tag_handles.put(handle, prefix) catch {};
    }
    self.skipToEndOfLine();
    self.skipNewline();
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn peek(self: *const Parser) u8 {
    return self.input[self.pos];
}

fn atEnd(self: *const Parser) bool {
    return self.pos >= self.input.len;
}

fn atEndOfLine(self: *const Parser) bool {
    if (self.pos >= self.input.len) return true;
    return self.input[self.pos] == '\n' or self.input[self.pos] == '\r';
}

fn isFlowIndicatorNext(self: *const Parser) bool {
    if (self.pos + 1 >= self.input.len) return true;
    const next = self.input[self.pos + 1];
    return next == ' ' or next == '\t' or next == ',' or next == '[' or next == ']' or
        next == '{' or next == '}' or next == '\n' or next == '\r';
}

fn isValidYamlVersion(version: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return false;
    if (dot == 0 or dot == version.len - 1) return false;
    for (version[0..dot]) |c| if (c < '0' or c > '9') return false;
    for (version[dot + 1 ..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn isDocumentMarker(self: *const Parser) bool {
    if (self.pos + 3 > self.input.len) return false;
    const triple = self.input[self.pos..][0..3];
    if (!std.mem.eql(u8, triple, "---") and !std.mem.eql(u8, triple, "...")) return false;
    if (self.pos + 3 == self.input.len) return true;
    const after = self.input[self.pos + 3];
    return after == ' ' or after == '\t' or after == '\n' or after == '\r';
}

fn isDocumentStartMarker(self: *const Parser) bool {
    if (self.pos + 3 > self.input.len) return false;
    if (!std.mem.eql(u8, self.input[self.pos..][0..3], "---")) return false;
    if (self.pos + 3 == self.input.len) return true;
    const after = self.input[self.pos + 3];
    return after == ' ' or after == '\t' or after == '\n' or after == '\r';
}

fn isBlockSequenceIndicator(self: *const Parser) bool {
    if (self.pos >= self.input.len or self.input[self.pos] != '-') return false;
    if (self.pos + 1 >= self.input.len) return true;
    const next = self.input[self.pos + 1];
    return next == ' ' or next == '\t' or next == '\n' or next == '\r';
}

fn currentCol(self: *const Parser) usize {
    var p = self.pos;
    while (p > 0 and self.input[p - 1] != '\n' and self.input[p - 1] != '\r') {
        p -= 1;
    }
    return self.pos - p;
}

fn checkNoTabIndent(self: *Parser) opts.Error!void {
    var p = self.pos;
    while (p > 0 and self.input[p - 1] != '\n' and self.input[p - 1] != '\r') p -= 1;
    while (p < self.pos) : (p += 1) {
        if (self.input[p] == '\t') return self.fail("TabInIndentation");
        if (self.input[p] != ' ') return;
    }
}

/// Reject remaining content that sits at an indentation level where nothing
/// expects it (e.g. content between the block indent and a nested indent).
fn rejectOrphanContent(self: *Parser) opts.Error!void {
    self.skipWhitespaceAndComments();
    if (self.atEnd()) return;
    if (self.isDocumentMarker()) return;
    if (self.currentCol() > 0) return self.fail("UnexpectedCharacter");
    const c = self.peek();
    if (c == '&' or c == '!') return self.fail("UnexpectedCharacter");
}

/// Reject flow continuation lines indented below the required level.
fn rejectFlowBelowIndent(self: *Parser, min_indent: usize) opts.Error!void {
    if (min_indent == 0) return;
    if (self.currentCol() < min_indent) return self.fail("UnexpectedCharacter");
}

/// Check for invalid trailing content after a flow collection on the same line.
/// Reject non-whitespace content after a quoted scalar in block context
/// (e.g. `"value"#comment` is invalid -- `#` needs a preceding space).
fn rejectTrailingQuotedContent(self: *Parser) opts.Error!void {
    if (self.atEnd() or self.atEndOfLine()) return;
    const c = self.peek();
    if (c == ' ' or c == '\t') return;
    if (c == ':') return;
    return self.fail("UnexpectedCharacter");
}

fn rejectTrailingFlowContent(self: *Parser) opts.Error!void {
    self.skipInlineSpace();
    if (self.atEnd() or self.atEndOfLine()) return;
    const c = self.peek();
    if (c == ':') return;
    if (c == '#' and self.pos > 0 and
        (self.input[self.pos - 1] == ' ' or self.input[self.pos - 1] == '\t'))
        return;
    return self.fail("UnexpectedCharacter");
}

/// Reject tab only when it precedes another block indicator (-, ?, :).
/// Allows tab before content like `-\tbaz` or `-\t-1`.
fn rejectTabBeforeBlockIndicator(self: *Parser) opts.Error!void {
    if (self.atEnd() or self.peek() != '\t') return;
    var look = self.pos;
    while (look < self.input.len and (self.input[look] == ' ' or self.input[look] == '\t')) look += 1;
    if (look >= self.input.len) return;
    const next = self.input[look];
    if (next == '-' or next == '?' or next == ':') {
        const after = look + 1;
        if (after >= self.input.len or self.input[after] == ' ' or self.input[after] == '\t' or
            self.input[after] == '\n' or self.input[after] == '\r')
        {
            return self.fail("TabInIndentation");
        }
    }
}

fn startsWith(self: *const Parser, prefix: []const u8) bool {
    if (self.pos + prefix.len > self.input.len) return false;
    return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
}

fn skipBom(self: *Parser) void {
    if (self.input.len >= 3 and
        self.input[0] == 0xEF and self.input[1] == 0xBB and self.input[2] == 0xBF)
    {
        self.pos = 3;
    }
}

fn skipInlineSpace(self: *Parser) void {
    while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
        self.pos += 1;
    }
}

fn skipNewline(self: *Parser) void {
    if (self.pos < self.input.len and self.input[self.pos] == '\r') self.pos += 1;
    if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
}

fn skipToEndOfLine(self: *Parser) void {
    while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
        self.pos += 1;
    }
}

fn skipWhitespaceAndComments(self: *Parser) void {
    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            self.pos += 1;
        } else if (c == '#') {
            self.skipToEndOfLine();
        } else break;
    }
}

fn skipBlankAndCommentLines(self: *Parser) void {
    while (self.pos < self.input.len) {
        self.skipInlineSpace();
        if (self.pos >= self.input.len) break;
        if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
            self.skipNewline();
            continue;
        }
        if (self.input[self.pos] == '#') {
            self.skipToEndOfLine();
            self.skipNewline();
            continue;
        }
        break;
    }
}

fn skipFlowWhitespace(self: *Parser) opts.Error!void {
    while (self.pos < self.input.len) {
        const c = self.input[self.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (c == '\t' and self.isAtLineStart()) {
                var look = self.pos + 1;
                while (look < self.input.len and (self.input[look] == ' ' or self.input[look] == '\t')) look += 1;
                if (look < self.input.len) {
                    const next = self.input[look];
                    if (next != '\n' and next != '\r' and next != ']' and next != '}')
                        return self.fail("TabInIndentation");
                }
            }
            self.pos += 1;
        } else if (c == '#' and self.pos > 0 and
            (self.input[self.pos - 1] == ' ' or self.input[self.pos - 1] == '\t' or
            self.input[self.pos - 1] == '\n' or self.input[self.pos - 1] == '\r'))
        {
            self.skipToEndOfLine();
        } else break;
    }
}

fn isAtLineStart(self: *const Parser) bool {
    return self.pos == 0 or self.input[self.pos - 1] == '\n' or self.input[self.pos - 1] == '\r';
}

fn readToEndOfUnquotedLine(self: *Parser) []const u8 {
    const start = self.pos;
    while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
        self.pos += 1;
    }
    return self.input[start..self.pos];
}

fn readToEndOfUnquotedLineNoAdvance(self: *const Parser) []const u8 {
    var p = self.pos;
    while (p < self.input.len and self.input[p] != '\n' and self.input[p] != '\r') {
        p += 1;
    }
    return self.input[self.pos..p];
}

fn findEndOfLine(self: *const Parser) usize {
    var p = self.pos;
    while (p < self.input.len and self.input[p] != '\n' and self.input[p] != '\r') {
        p += 1;
    }
    return p;
}

fn findKeyValueSep(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '"' and i == 0) {
            i += 1;
            while (i < line.len and line[i] != '"') {
                if (line[i] == '\\') i += 1;
                i += 1;
            }
            if (i < line.len) i += 1;
        } else if (c == '\'' and i == 0) {
            i += 1;
            while (i < line.len) {
                if (line[i] == '\'') {
                    if (i + 1 < line.len and line[i + 1] == '\'') {
                        i += 2;
                    } else break;
                } else i += 1;
            }
            if (i < line.len) i += 1;
        } else if (c == '#' and i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\t')) {
            break;
        } else if (c == ':') {
            if (i + 1 >= line.len or line[i + 1] == ' ' or line[i + 1] == '\t' or
                line[i + 1] == '\n' or line[i + 1] == '\r')
            {
                return i;
            }
            i += 1;
        } else {
            i += 1;
        }
    }
    return null;
}

fn fail(self: *Parser, comptime which: []const u8) opts.Error {
    if (self.options.diagnostics) |diag| {
        diagnostic.setError(diag, self.input, self.pos, which);
    }
    return @field(opts.Error, which);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse: simple string" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "hello");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello", parsed.value.string);
}

test "parse: integer" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "42");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.integer);
}

test "parse: boolean" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "true");
    defer parsed.deinit();
    try std.testing.expect(parsed.value.boolean);
}

test "parse: null variants" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "null", "Null", "NULL", "~", "" }) |input| {
        var parsed = try root.parse(alloc, input);
        defer parsed.deinit();
        try std.testing.expectEqual(Value{ .null_val = {} }, parsed.value);
    }
}

test "parse: simple map" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "name: Alice\nage: 30\n");
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 2), obj.len);
    try std.testing.expectEqualStrings("name", obj[0].key.string);
    try std.testing.expectEqualStrings("Alice", obj[0].value.string);
    try std.testing.expectEqual(@as(i64, 30), obj[1].value.integer);
}

test "parse: simple list" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "- one\n- two\n- three\n");
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("one", arr[0].string);
    try std.testing.expectEqualStrings("two", arr[1].string);
    try std.testing.expectEqualStrings("three", arr[2].string);
}

test "parse: nested map" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc,
        \\person:
        \\  name: Alice
        \\  age: 30
    );
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1), obj.len);
    const person = obj[0].value.object;
    try std.testing.expectEqual(@as(usize, 2), person.len);
    try std.testing.expectEqualStrings("Alice", person[0].value.string);
}

test "parse: flow sequence" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "[1, 2, 3]");
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
}

test "parse: flow mapping" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "{name: Alice, age: 30}");
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 2), obj.len);
    try std.testing.expectEqualStrings("Alice", obj[0].value.string);
}

test "parse: double quoted string with escapes" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "\"hello\\nworld\"");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello\nworld", parsed.value.string);
}

test "parse: single quoted string" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "'hello world'");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello world", parsed.value.string);
}

test "parse: comments" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "# comment\nkey: value # inline comment\n");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object[0].value.string);
}

test "parse: block literal scalar" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc,
        \\text: |
        \\  line1
        \\  line2
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("line1\nline2\n", parsed.value.object[0].value.string);
}

test "parse: hex and octal numbers" {
    const alloc = std.testing.allocator;
    var p1 = try root.parse(alloc, "0xFF");
    defer p1.deinit();
    try std.testing.expectEqual(@as(i64, 255), p1.value.integer);

    var p2 = try root.parse(alloc, "0o77");
    defer p2.deinit();
    try std.testing.expectEqual(@as(i64, 63), p2.value.integer);
}

test "parse: special floats" {
    const alloc = std.testing.allocator;
    var p1 = try root.parse(alloc, ".inf");
    defer p1.deinit();
    try std.testing.expect(std.math.isInf(p1.value.float));

    var p2 = try root.parse(alloc, ".nan");
    defer p2.deinit();
    try std.testing.expect(std.math.isNan(p2.value.float));
}

test "parse: anchor and alias" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc,
        \\defaults: &defaults
        \\  adapter: postgres
        \\production:
        \\  <<: *defaults
    );
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 2), obj.len);
}

test "parse: empty document" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc, "");
    defer parsed.deinit();
    try std.testing.expectEqual(Value{ .null_val = {} }, parsed.value);
}

test "parse: multiple documents" {
    const alloc = std.testing.allocator;
    var parsed = try root.parseAll(alloc,
        \\---
        \\first: doc
        \\---
        \\second: doc
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
}

test "parse: diagnostics on error" {
    const alloc = std.testing.allocator;
    var diag: root.Diagnostics = .{};
    const result = root.parseFromSlice(Value, alloc, "[unclosed", .{ .diagnostics = &diag });
    try std.testing.expectError(error.UnclosedFlowSequence, result);
    try std.testing.expect(diag.line > 0);
}

test "parse: list in map" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc,
        \\items:
        \\  - one
        \\  - two
    );
    defer parsed.deinit();
    const items = parsed.value.object[0].value.array;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("one", items[0].string);
}

test "parse: map in list" {
    const alloc = std.testing.allocator;
    var parsed = try root.parse(alloc,
        \\- name: Alice
        \\  age: 30
        \\- name: Bob
        \\  age: 25
    );
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("Alice", arr[0].object[0].value.string);
}

test "parse: empty flow collections" {
    const alloc = std.testing.allocator;
    var p1 = try root.parse(alloc, "[]");
    defer p1.deinit();
    try std.testing.expectEqual(@as(usize, 0), p1.value.array.len);

    var p2 = try root.parse(alloc, "{}");
    defer p2.deinit();
    try std.testing.expectEqual(@as(usize, 0), p2.value.object.len);
}

test "parse: std.json.Value interop" {
    const alloc = std.testing.allocator;
    var parsed = root.parseFromSlice(std.json.Value, alloc, "name: Alice\nage: 30\n", .{}) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Alice", parsed.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 30), parsed.value.object.get("age").?.integer);
}
