# YAML Test Suite

Test cases from the [YAML Test Suite](https://github.com/yaml/yaml-test-suite),
branch `data-2022-01-17` (commit `6e6c296`).

## Format

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

Sections per test case:

- `<!-- test: Description [ID] -->` -- starts a new test, ID in brackets
- `<!-- in -->` -- YAML input follows (required)
- `<!-- json -->` -- expected JSON output follows (omitted for error-only tests)
- `<!-- error -->` -- marks test as expecting a parse error (placed before `<!-- in -->`)

## Grouping

Tests are grouped by upstream tags into ~13 files. Each test is assigned to
exactly one file using a priority list (most specific tag wins):

| File | Tags |
|------|------|
| `literal.test` | literal, folded |
| `double.test` | double, single |
| `scalar.test` | scalar (remaining) |
| `complex-key.test` | complex-key, explicit-key, empty-key, duplicate-key |
| `anchor.test` | anchor, alias |
| `tag.test` | tag, local-tag, unknown-tag |
| `flow.test` | flow |
| `mapping.test` | mapping (remaining) |
| `sequence.test` | sequence (remaining) |
| `directive.test` | directive |
| `document.test` | document, header, footer |
| `comment.test` | comment |
| `whitespace.test` | whitespace, indent, edge, empty |

Tests matching only low-priority tags (error, spec, simple) fall through
to whichever higher-priority group also matches.

## Updating

To regenerate from the upstream repository:

```
zig build fetch-suite
```

This clones the upstream branch, reads the `tags/` directory for grouping,
and generates `.test` files. Existing files are compared and only rewritten
if the content has changed.

To fetch from a different branch:

```
zig build fetch-suite -- --branch data-2024-08-01
```

## License

The YAML Test Suite is released under the MIT License.
See <https://github.com/yaml/yaml-test-suite> for details.
