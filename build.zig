const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("comb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "comb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "comb", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // zig build run [-- args]
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // zig build test
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    addCliTests(b, exe, test_step);

    // zig build fetch-suite [-- --branch NAME]
    const fetch_exe = b.addExecutable(.{
        .name = "fetch-suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch_suite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const fetch_cmd = b.addRunArtifact(fetch_exe);
    if (b.args) |args| {
        fetch_cmd.addArgs(args);
    }
    const fetch_step = b.step("fetch-suite", "Fetch YAML Test Suite from GitHub and report changes");
    fetch_step.dependOn(&fetch_cmd.step);
}

fn addCliTests(b: *std.Build, exe: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    const Case = struct { name: []const u8, stdin: []const u8, args: []const []const u8, expected: []const u8 };

    const cases = [_]Case{
        // Default mode: compact JSON
        .{
            .name = "cli: compact JSON from stdin",
            .stdin = "name: Alice\nage: 30\n",
            .args = &.{},
            .expected = "{\"name\":\"Alice\",\"age\":30}\n",
        },
        .{
            .name = "cli: scalar string",
            .stdin = "hello",
            .args = &.{},
            .expected = "\"hello\"\n",
        },
        .{
            .name = "cli: scalar integer",
            .stdin = "42",
            .args = &.{},
            .expected = "42\n",
        },
        .{
            .name = "cli: scalar boolean",
            .stdin = "true",
            .args = &.{},
            .expected = "true\n",
        },
        .{
            .name = "cli: scalar null",
            .stdin = "null",
            .args = &.{},
            .expected = "null\n",
        },
        // --pretty flag
        .{
            .name = "cli: pretty JSON",
            .stdin = "x: 1",
            .args = &.{"--pretty"},
            .expected = "{\n  \"x\": 1\n}\n",
        },
        // --yaml flag
        .{
            .name = "cli: YAML output",
            .stdin = "x: 1",
            .args = &.{"--yaml"},
            .expected = "x: 1\n",
        },
        // --all flag with JSON
        .{
            .name = "cli: multi-doc JSON array",
            .stdin = "one\n---\ntwo\n",
            .args = &.{"--all"},
            .expected = "[\"one\",\"two\"]\n",
        },
        // --all flag with YAML
        .{
            .name = "cli: multi-doc YAML",
            .stdin = "one\n---\ntwo\n",
            .args = &.{ "--all", "--yaml" },
            .expected = "one\n---\ntwo\n",
        },
        // --sort-keys flag
        .{
            .name = "cli: sort keys",
            .stdin = "c: 3\na: 1\nb: 2",
            .args = &.{"--sort-keys"},
            .expected = "{\"a\":1,\"b\":2,\"c\":3}\n",
        },
        // --indent flag
        .{
            .name = "cli: custom indent",
            .stdin = "x: 1",
            .args = &.{ "--pretty", "--indent", "4" },
            .expected = "{\n    \"x\": 1\n}\n",
        },
        // --allow-duplicate-keys flag (JSON deduplicates; last value wins)
        .{
            .name = "cli: allow duplicate keys",
            .stdin = "a: 1\na: 2",
            .args = &.{"--allow-duplicate-keys"},
            .expected = "{\"a\":2}\n",
        },
        // --yaml with sort_keys
        .{
            .name = "cli: YAML with sorted keys",
            .stdin = "c: 3\na: 1\nb: 2",
            .args = &.{ "--yaml", "--sort-keys" },
            .expected = "a: 1\nb: 2\nc: 3\n",
        },
        // --yaml with custom indent
        .{
            .name = "cli: YAML with indent 4",
            .stdin = "a:\n  b: 1\n",
            .args = &.{ "--yaml", "--indent", "4" },
            .expected = "a: \n    b: 1\n",
        },
        // --yaml with nested array
        .{
            .name = "cli: YAML nested array",
            .stdin = "items:\n- 1\n- 2\n",
            .args = &.{"--yaml"},
            .expected = "items: \n  - 1\n  - 2\n",
        },
        // --yaml with special scalar values
        .{
            .name = "cli: YAML special values",
            .stdin = "a: true\nb: null\nc: 42\n",
            .args = &.{"--yaml"},
            .expected = "a: true\nb: null\nc: 42\n",
        },
        // --help flag
        .{
            .name = "cli: help flag",
            .stdin = "",
            .args = &.{"--help"},
            .expected = "Usage: comb [OPTIONS] [FILE]\n\nParse YAML and output JSON or normalized YAML.\nReads from FILE or stdin if no file specified.\n\nOptions:\n  --pretty                Pretty-print JSON output\n  --yaml                  Output normalized YAML\n  --all                   Process all documents\n  --sort-keys             Sort object keys alphabetically\n  --indent N              Indentation size (default: 2)\n  --strict                Reject duplicate keys (default)\n  --allow-duplicate-keys  Accept duplicate keys (last wins)\n  -h, --help              Show this help\n",
        },
        // -h short flag
        .{
            .name = "cli: -h flag",
            .stdin = "",
            .args = &.{"-h"},
            .expected = "Usage: comb [OPTIONS] [FILE]\n\nParse YAML and output JSON or normalized YAML.\nReads from FILE or stdin if no file specified.\n\nOptions:\n  --pretty                Pretty-print JSON output\n  --yaml                  Output normalized YAML\n  --all                   Process all documents\n  --sort-keys             Sort object keys alphabetically\n  --indent N              Indentation size (default: 2)\n  --strict                Reject duplicate keys (default)\n  --allow-duplicate-keys  Accept duplicate keys (last wins)\n  -h, --help              Show this help\n",
        },
    };

    for (&cases) |case| {
        const run = b.addRunArtifact(exe);
        run.setName(case.name);
        run.setStdIn(.{ .bytes = case.stdin });
        for (case.args) |arg| run.addArg(arg);
        run.expectStdOutEqual(case.expected);
        test_step.dependOn(&run.step);
    }

    // Error cases: non-zero exit code
    const error_cases = [_]struct { name: []const u8, stdin: []const u8, args: []const []const u8 }{
        .{ .name = "cli error: invalid YAML", .stdin = "[unclosed", .args = &.{} },
        .{ .name = "cli error: indent missing value", .stdin = "", .args = &.{"--indent"} },
        .{ .name = "cli error: unknown flag", .stdin = "", .args = &.{"--nonexistent"} },
        .{ .name = "cli error: duplicate keys strict", .stdin = "a: 1\na: 2", .args = &.{"--strict"} },
    };

    for (&error_cases) |case| {
        const run = b.addRunArtifact(exe);
        run.setName(case.name);
        run.setStdIn(.{ .bytes = case.stdin });
        for (case.args) |arg| run.addArg(arg);
        run.expectExitCode(1);
        test_step.dependOn(&run.step);
    }
}
