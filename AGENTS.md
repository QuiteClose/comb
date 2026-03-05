# Comb

YAML 1.2 parser, renderer, and JSON interop library for Zig. Parses YAML into a typed value tree, serializes to JSON or normalized YAML, and provides a CLI for format conversion. Zero external dependencies.

**Status:** Feature-complete. All 402 YAML Test Suite cases pass.

## Architecture

Single-phase recursive descent parser. YAML input is parsed byte-by-byte into `comb.Value` (a tagged union), then optionally converted to `std.json.Value` for JSON interoperability or serialized back to normalized YAML.

```
YAML input → Parser.parseDocument() → comb.Value
                                         ├─→ .toStdJsonValue() → std.json.Value
                                         └─→ Renderer.render() → YAML string
```

### Import Graph

Acyclic. All arrows point downward.

```
root.zig (public API facade)
├── Parser.zig (lazy)
├── Renderer.zig (lazy)
├── Value.zig
└── options.zig

Parser.zig
├── options.zig
├── schema.zig
├── diagnostic.zig
└── Value.zig

Renderer.zig
├── options.zig
├── schema.zig
└── Value.zig

schema.zig → Value.zig
diagnostic.zig → options.zig
options.zig → (leaf)
Value.zig → (leaf)
```

### Module Map

| File | Role |
|------|------|
| `src/root.zig` | Public API facade. Re-exports types from `options.zig` and `Value.zig`. Functions: `parseFromSlice`, `parse`, `parseAll`, `toJson`, `toYaml`, `render`, `valueToJson`, `indentToWhitespace`. |
| `src/Parser.zig` | Recursive descent parser. Handles all YAML 1.2 node types: block/flow collections, all scalar styles, anchors/aliases, merge keys, tags, directives, complex keys, multi-document streams. State: byte position, allocator, anchor map, depth counter, options. |
| `src/Renderer.zig` | Serializes `comb.Value` back to normalized YAML. Handles quoting decisions (reserved words, numbers, whitespace, control characters), indentation, block collections, special floats, binary encoding, key sorting. |
| `src/Value.zig` | `Value` tagged union (string, integer, float, boolean, null_val, array, object, binary, tagged), `Entry` with `keyLessThan` comparator, `Tagged`, key lookup methods (`get`, `getStr`, `getArray`, `getObject`), conversion to `std.json.Value`, deep equality. |
| `src/options.zig` | Shared configuration types: `ParseOptions`, `DuplicateKeyBehavior`, `Diagnostics`, `OutputOptions`, `Parsed(T)`, `Error`. Leaf module with no project imports. |
| `src/schema.zig` | YAML 1.2 Core Schema type detection: `detectScalarType`, `parseBoolStr`, `isReservedScalar`, `looksLikeNumber`. Single source of truth for null/boolean/infinity/NaN string spellings. |
| `src/diagnostic.zig` | Error-location utility: `setError` populates `Diagnostics` with line, column, source line excerpt from a byte position. |
| `src/main.zig` | CLI entry point. Argument parsing, file/stdin I/O, JSON/YAML output modes. |
| `src/yaml_suite_runner.zig` | YAML Test Suite runner. Parses grouped `.test` files and validates parser output against expected JSON. Strict pass/fail model with no expected-failure list. |
| `tools/fetch_suite.zig` | Build tool. Clones the upstream YAML Test Suite, reads tags for grouping, and regenerates `.test` files. |

### Parser Structure

The parser is organized around node types:

- `parseDocument` / `parseAllDocuments` -- document boundary handling, BOM, directives
- `parseNode` -- central dispatch: detects node type from first character, handles tags/anchors
- `parseBlockMapping` / `parseBlockMappingFromFirstKey` / `parseBlockMappingWithComplexKey` -- block mappings with key detection
- `parseRemainingMappingEntries` -- shared loop for mapping entries (keys with anchors/tags/aliases, colon, values)
- `parseBlockSequence` -- block sequences (`- item`)
- `parseBlockScalar` -- literal `|` and folded `>` scalars with chomping and indent indicators
- `parseFlowSequence` / `parseFlowMapping` -- flow collections (`[...]`, `{...}`)
- `parseFlowValue` / `parseFlowKey` -- plain scalars in flow context
- `parseDoubleQuoted` / `parseSingleQuoted` -- quoted strings with escape handling
- `parsePlainScalar` -- unquoted scalars with multi-line continuation
- `parseBlockMappingValue` / `parseBlockMappingKey` -- value/key parsing with anchor/tag support
- `parseAnchorDef` / `parseAlias` -- anchor (`&name`) and alias (`*name`) handling
- `parseTag` / `applyTag` -- tag parsing and application

Type detection and reserved-word checks are delegated to `schema.zig`. Error diagnostics are delegated to `diagnostic.zig`.

### Value Type

```zig
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null_val: void,
    array: []const Value,
    object: []const Entry,   // preserves insertion order
    binary: []const u8,      // decoded from !!binary base64
    tagged: Tagged,           // custom tags
};
```

When converting to `std.json.Value`: inf/nan become null, binary becomes base64 string, complex keys become string representations, custom tags are unwrapped.

## Public API

```zig
const comb = @import("comb");

// Parse to comb.Value (full YAML fidelity)
var parsed = try comb.parse(allocator, yaml_input);
defer parsed.deinit();

// Parse to std.json.Value (seamless JSON interop)
var json_parsed = try comb.parseFromSlice(std.json.Value, allocator, yaml_input, .{});
defer json_parsed.deinit();

// Parse all documents in a stream
var docs = try comb.parseAll(allocator, yaml_input, .{});
defer docs.deinit();

// YAML -> JSON string
const json = try comb.toJson(allocator, yaml_input, .{ .indent = 2 });

// YAML -> normalized YAML string
const yaml = try comb.toYaml(allocator, yaml_input, .{ .sort_keys = true });

// Render a Value to YAML
const rendered = try comb.render(allocator, value, .{});

// Value to JSON string
const json_str = try comb.valueToJson(allocator, value, .{ .sort_keys = true, .indent = 0 });
```

### ParseOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `duplicate_keys` | `DuplicateKeyBehavior` | `.err` | `.err` rejects duplicates, `.last_wins` keeps the last |
| `max_depth` | `?u16` | `256` | Maximum nesting depth (`null` for unlimited) |
| `diagnostics` | `?*Diagnostics` | `null` | Populated with error location details on parse failure |

### OutputOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `sort_keys` | `bool` | `false` | Sort mapping keys alphabetically |
| `indent` | `u8` | `2` | Spaces per indentation level |

## CLI

```
Usage: comb [OPTIONS] [FILE]

Parse YAML and output JSON or normalized YAML.
Reads from FILE or stdin if no file specified.

Options:
  --pretty                Pretty-print JSON output
  --yaml                  Output normalized YAML
  --all                   Process all documents
  --sort-keys             Sort object keys alphabetically
  --indent N              Indentation size (default: 2)
  --strict                Reject duplicate keys (default)
  --allow-duplicate-keys  Accept duplicate keys (last wins)
  -h, --help              Show this help
```

## Testing

Three layers of tests, all run via `zig build test`:

### YAML Test Suite conformance

From the official [YAML Test Suite](https://github.com/yaml/yaml-test-suite) (`data-2022-01-17` tag -- the latest dated release of the test data). Tests are stored in grouped `.test` files using HTML comment delimiters, organized by upstream tags (e.g. `literal.test`, `flow.test`, `mapping.test`).

All cases must pass outright -- there is no expected-failure mechanism. Any failure fails the build immediately.

### Unit tests

Inline `test` blocks across source modules:

| Module | Coverage |
|--------|----------|
| `root.zig` | All public API functions, error handling, options, diagnostics, idempotence, roundtrip fidelity, regression tests for bug fixes |
| `Parser.zig` | Scalar types, quoting, escapes, collections, documents, anchors, tags, complex keys |
| `Renderer.zig` | Scalars, maps, arrays, nesting, key sorting, special floats, quoting decisions (reserved words, numbers, whitespace, control characters), binary, tagged values, complex keys, custom indent |
| `Value.zig` | `std.json.Value` conversion, deep equality, edge cases |
| `schema.zig` | All `detectScalarType` variants (null, bool, int, float, inf, nan, octal, hex, string), `parseBoolStr`, `isReservedScalar`, `looksLikeNumber` edge cases |
| `diagnostic.zig` | Error position computation at start/middle/end of input |

### CLI integration tests

Success and error cases in `build.zig`. Each spawns the built `comb` binary with controlled stdin and arguments, then asserts on stdout content or exit code. Covers all CLI flags and their interactions.

### Updating conformance tests

```
zig build fetch-suite
```

Clones the upstream repo, reads `tags/` for grouping, and regenerates `.test` files.

### Test file format

```
<!-- test: Literal Block Scalar [7T4X] -->
<!-- in -->
|
  literal
  block
<!-- json -->
"literal\nblock\n"

<!-- test: Tab in Mapping [GT5M] -->
<!-- error -->
<!-- in -->
{	a: b}
```

Sections: `<!-- test: Description [ID] -->` starts a case, `<!-- in -->` for YAML input, `<!-- json -->` for expected JSON, `<!-- error -->` marks error expectation.

## Build Commands

```
zig build              # Build the CLI binary
zig build test         # Run all tests (unit + conformance + CLI)
zig build run -- FILE  # Run the CLI
zig build fetch-suite  # Regenerate test files from upstream
```

Requires Zig 0.15.2 or later.

## Conventions

- All memory managed through `std.mem.Allocator`; `ArenaAllocator` for per-parse isolation
- Error diagnostics via optional `*Diagnostics` pointer in `ParseOptions`
- `fail()` in Parser delegates to `diagnostic.setError()` then returns the typed error
- camelCase for functions, PascalCase for types, snake_case for fields/constants/enum values
- `//!` file-level doc comment on every module, `///` on every public item
- No external dependencies; zero allocations escape the arena except the final result
