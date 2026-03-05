# Comb

Straightens out YAML. A YAML 1.2 parser and renderer for Zig.

## Features

- **Full YAML 1.2 Core Schema** -- block and flow collections, all scalar styles (plain, single-quoted, double-quoted, literal `|`, folded `>`), anchors and aliases, merge keys, tags, complex keys, multi-document streams, directives
- **Two-tier value system** -- parse into `comb.Value` for full YAML fidelity (tags, binary, inf/nan) or `std.json.Value` for seamless JSON interop
- **YAML renderer** -- serialize `comb.Value` back to normalized YAML with configurable indentation and key sorting
- **JSON output** -- convert YAML to JSON via `std.json` with pretty-print and compact modes
- **Error diagnostics** -- line, column, source excerpt, and error kind on parse failure
- **Zero dependencies** -- pure Zig, no external libraries
- **Conformance tested** -- validated against the official [YAML Test Suite](https://github.com/yaml/yaml-test-suite); all 402 cases pass

## Building

Requires Zig 0.15.2 or later.

```
zig build              # Build the CLI binary
zig build test         # Run all tests (unit + conformance + CLI integration)
zig build run -- FILE  # Run the CLI on a file
zig build fetch-suite  # Fetch and regenerate conformance tests from upstream
```

## Library API

```zig
const comb = @import("comb");

// Parse YAML into comb.Value (full YAML fidelity)
var parsed = try comb.parse(allocator, yaml_input);
defer parsed.deinit();

// Parse YAML into std.json.Value (seamless JSON interop)
var json_parsed = try comb.parseFromSlice(std.json.Value, allocator, yaml_input, .{});
defer json_parsed.deinit();

// Parse all documents in a multi-document stream
var docs = try comb.parseAll(allocator, yaml_input, .{});
defer docs.deinit();

// Access values by key
const name = parsed.value.getStr("name") orelse "unknown";
const items = parsed.value.getArray("items") orelse &.{};
const nested = parsed.value.getObject("metadata");

// YAML -> JSON string
const json = try comb.toJson(allocator, yaml_input, .{ .indent = 2 });

// YAML -> normalized YAML string
const yaml = try comb.toYaml(allocator, yaml_input, .{ .sort_keys = true });

// Render a Value to YAML
const rendered = try comb.render(allocator, value, .{});
```

### Parse Options

| Option | Default | Description |
|--------|---------|-------------|
| `duplicate_keys` | `.err` | `.err` rejects duplicates, `.last_wins` keeps the last |
| `max_depth` | `256` | Maximum nesting depth (`null` for unlimited) |
| `diagnostics` | `null` | Pointer to `Diagnostics` struct for error location details |

### Output Options

| Option | Default | Description |
|--------|---------|-------------|
| `sort_keys` | `false` | Sort mapping keys alphabetically |
| `indent` | `2` | Spaces per indentation level |

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

| Layer | Description |
|-------|-------------|
| Unit tests | Inline `test` blocks across source modules covering parser internals, value types, schema detection, rendering, diagnostics, and all public API functions |
| Conformance | YAML Test Suite cases (see below) |
| CLI integration | Build steps that spawn the `comb` binary with controlled stdin/args and assert on stdout/exit code |

## YAML Test Suite

Conformance tests come from the official **[YAML Test Suite](https://github.com/yaml/yaml-test-suite)**, a community-maintained collection of YAML parsing edge cases. The test suite is not bundled as a submodule -- instead, a build tool fetches the upstream repository on demand and converts it into comb's `.test` file format.

### Source

| | |
|---|---|
| **Repository** | [github.com/yaml/yaml-test-suite](https://github.com/yaml/yaml-test-suite) |
| **Tag** | `data-2022-01-17` (latest dated release of the test data) |
| **License** | MIT |

The YAML Test Suite repository uses its `main` branch for tooling source code. The actual test case data is published as dated tags (`data-2022-01-17`, `data-2021-10-09`, etc.). Comb fetches from the latest available data tag by default.

### Fetching the test suite

The `.test` files in `test/yaml-test-suite/` are checked into this repository, so you do not need to fetch the suite to run tests. However, to regenerate the files from the upstream repository (e.g. to pick up new cases or verify nothing has drifted):

```
zig build fetch-suite
```

This runs `tools/fetch_suite.zig`, which:

1. Shallow-clones the upstream repository to `/tmp/comb-yaml-test-suite`
2. Reads each test case directory (`in.yaml`, `in.json`, `error`, `===` name file)
3. Reads the `tags/` directory to determine which category each case belongs to
4. Groups cases by tag priority into `.test` files (e.g. `literal.test`, `flow.test`, `mapping.test`)
5. Compares the generated content against existing files and reports what changed
6. Cleans up the temporary clone

To fetch from a different tag or branch:

```
zig build fetch-suite -- --branch data-2021-10-09
```

### Test file format

Tests are stored in `.test` files using HTML comment delimiters:

```
<!-- test: Simple Mapping [229Q] -->
<!-- in -->
a: b
<!-- json -->
{"a": "b"}

<!-- test: Tab as indentation [GT5M] -->
<!-- error -->
<!-- in -->
{	a: b}
```

Each test case has:

- `<!-- test: Description [ID] -->` -- starts the case, with the upstream test ID in brackets
- `<!-- in -->` -- YAML input (required)
- `<!-- json -->` -- expected JSON output (omitted for error-only tests)
- `<!-- error -->` -- marks the case as expecting a parse error (placed before `<!-- in -->`)

### Test grouping

| File | Upstream tags |
|------|--------------|
| `literal.test` | literal, folded |
| `double.test` | double, single |
| `scalar.test` | scalar |
| `complex-key.test` | complex-key, explicit-key, empty-key, duplicate-key |
| `anchor.test` | anchor, alias |
| `tag.test` | tag, local-tag, unknown-tag |
| `flow.test` | flow |
| `mapping.test` | mapping |
| `sequence.test` | sequence |
| `directive.test` | directive |
| `document.test` | document, header, footer |
| `comment.test` | comment |
| `whitespace.test` | whitespace, indent, edge, empty |

Each test is assigned to exactly one file using a priority list (most specific tag wins). Tests that only match low-priority tags (error, spec, simple) fall through to whichever higher-priority group also matches.

### Conformance tracking

All test cases must pass outright -- there is no expected-failure mechanism. Any failure fails the build immediately, ensuring regressions are caught.

## Architecture

| Module | Purpose |
|--------|---------|
| `src/Parser.zig` | Recursive descent YAML 1.2 parser |
| `src/Renderer.zig` | YAML serialization with quoting and indentation |
| `src/Value.zig` | `Value` union, `Entry`, `Tagged`, JSON conversion |
| `src/root.zig` | Public API facade and re-exports |
| `src/options.zig` | Shared configuration types (`ParseOptions`, `OutputOptions`, `Diagnostics`, `Error`) |
| `src/schema.zig` | YAML 1.2 Core Schema type detection |
| `src/diagnostic.zig` | Error-location utilities |
| `src/main.zig` | CLI argument parsing and I/O |
| `src/yaml_suite_runner.zig` | Conformance test runner |
| `tools/fetch_suite.zig` | Test suite fetch and generation tool |

## License

MIT
