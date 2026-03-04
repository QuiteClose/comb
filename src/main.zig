const std = @import("std");
const comb = @import("comb");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);

    var file_path: ?[]const u8 = null;
    var mode: enum { json_compact, json_pretty, yaml } = .json_compact;
    var all_docs = false;
    var sort_keys = false;
    var indent: u8 = 2;
    var duplicate_keys: comb.DuplicateKeyBehavior = .err;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            mode = .json_pretty;
        } else if (std.mem.eql(u8, arg, "--yaml")) {
            mode = .yaml;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all_docs = true;
        } else if (std.mem.eql(u8, arg, "--sort-keys")) {
            sort_keys = true;
        } else if (std.mem.eql(u8, arg, "--indent")) {
            i += 1;
            if (i >= args.len) {
                try std.io.getStdErr().writer().writeAll("error: --indent requires a number\n");
                std.process.exit(1);
            }
            indent = std.fmt.parseInt(u8, args[i], 10) catch {
                try std.io.getStdErr().writer().writeAll("error: invalid indent value\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--strict")) {
            duplicate_keys = .err;
        } else if (std.mem.eql(u8, arg, "--allow-duplicate-keys")) {
            duplicate_keys = .last_wins;
        } else if (arg[0] != '-') {
            file_path = arg;
        } else {
            try std.io.getStdErr().writer().print("error: unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const input = if (file_path) |path|
        std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
            try std.io.getStdErr().writer().print("error: cannot read '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        }
    else
        std.io.getStdIn().readAllAlloc(alloc, 10 * 1024 * 1024) catch |err| {
            try std.io.getStdErr().writer().print("error: cannot read stdin: {}\n", .{err});
            std.process.exit(1);
        };

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const out_opts: comb.OutputOptions = .{ .sort_keys = sort_keys, .indent = indent };
    const parse_opts: comb.ParseOptions = .{ .duplicate_keys = duplicate_keys };
    _ = parse_opts;

    if (all_docs) {
        var parsed = comb.parseAll(alloc, input) catch |err| {
            try stderr.print("error: {}\n", .{err});
            std.process.exit(1);
        };
        defer parsed.deinit();

        switch (mode) {
            .yaml => {
                for (parsed.value, 0..) |doc, idx| {
                    if (idx > 0) try stdout.writeAll("---\n");
                    const rendered = comb.render(alloc, doc, out_opts) catch |err| {
                        try stderr.print("error: {}\n", .{err});
                        std.process.exit(1);
                    };
                    try stdout.writeAll(rendered);
                    try stdout.writeByte('\n');
                }
            },
            else => {
                try stdout.writeByte('[');
                for (parsed.value, 0..) |doc, idx| {
                    if (idx > 0) try stdout.writeByte(',');
                    const json_val = doc.toStdJsonValue(alloc) catch |err| {
                        try stderr.print("error: {}\n", .{err});
                        std.process.exit(1);
                    };
                    const ws = indentToWhitespace(if (mode == .json_pretty) indent else 0);
                    std.json.Stringify.value(json_val, .{ .whitespace = ws }, &stdout) catch |err| {
                        try stderr.print("error: {}\n", .{err});
                        std.process.exit(1);
                    };
                }
                try stdout.writeAll("]\n");
            },
        }
    } else {
        switch (mode) {
            .yaml => {
                const rendered = comb.toYaml(alloc, input, out_opts) catch |err| {
                    try stderr.print("error: {}\n", .{err});
                    std.process.exit(1);
                };
                try stdout.writeAll(rendered);
                try stdout.writeByte('\n');
            },
            .json_compact => {
                const json = comb.toJson(alloc, input, .{
                    .sort_keys = sort_keys,
                    .indent = 0,
                }) catch |err| {
                    try stderr.print("error: {}\n", .{err});
                    std.process.exit(1);
                };
                try stdout.writeAll(json);
                try stdout.writeByte('\n');
            },
            .json_pretty => {
                const json = comb.toJson(alloc, input, out_opts) catch |err| {
                    try stderr.print("error: {}\n", .{err});
                    std.process.exit(1);
                };
                try stdout.writeAll(json);
                try stdout.writeByte('\n');
            },
        }
    }
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: comb [OPTIONS] [FILE]
        \\
        \\Parse YAML and output JSON or normalized YAML.
        \\Reads from FILE or stdin if no file specified.
        \\
        \\Options:
        \\  --pretty                Pretty-print JSON output
        \\  --yaml                  Output normalized YAML
        \\  --all                   Process all documents
        \\  --sort-keys             Sort object keys alphabetically
        \\  --indent N              Indentation size (default: 2)
        \\  --strict                Reject duplicate keys (default)
        \\  --allow-duplicate-keys  Accept duplicate keys (last wins)
        \\  -h, --help              Show this help
        \\
    );
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
