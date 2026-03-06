//! Fetches the official YAML Test Suite and generates grouped `.test` files for the conformance runner.
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Child = std.process.Child;

const repo_url = "https://github.com/yaml/yaml-test-suite.git";
const default_branch = "data-2022-01-17";
const clone_dir = "/tmp/comb-yaml-test-suite";

const FileGroup = struct {
    filename: []const u8,
    tags: []const []const u8,
};

/// Priority order: first matching group wins for each test case.
const file_groups = [_]FileGroup{
    .{ .filename = "literal.test", .tags = &.{ "literal", "folded" } },
    .{ .filename = "double.test", .tags = &.{ "double", "single" } },
    .{ .filename = "scalar.test", .tags = &.{"scalar"} },
    .{ .filename = "complex-key.test", .tags = &.{ "complex-key", "explicit-key", "empty-key", "duplicate-key" } },
    .{ .filename = "anchor.test", .tags = &.{ "anchor", "alias" } },
    .{ .filename = "tag.test", .tags = &.{ "tag", "local-tag", "unknown-tag" } },
    .{ .filename = "flow.test", .tags = &.{"flow"} },
    .{ .filename = "mapping.test", .tags = &.{"mapping"} },
    .{ .filename = "sequence.test", .tags = &.{"sequence"} },
    .{ .filename = "directive.test", .tags = &.{"directive"} },
    .{ .filename = "document.test", .tags = &.{ "document", "header", "footer" } },
    .{ .filename = "comment.test", .tags = &.{"comment"} },
    .{ .filename = "whitespace.test", .tags = &.{ "whitespace", "indent", "edge", "empty" } },
    .{ .filename = "error.test", .tags = &.{ "error", "1.3-err", "1.3-mod", "libyaml-err", "upto-1.2" } },
};

const TagPair = struct {
    test_id: []const u8,
    tag: []const u8,
};

const TestCase = struct {
    id: []const u8,
    name: []const u8,
    in_yaml: []const u8,
    in_json: ?[]const u8,
    is_error: bool,
    filename: []const u8,
};

const ChangeKind = enum { new, changed, removed };

const Change = struct {
    filename: []const u8,
    kind: ChangeKind,
};

pub fn main() !void {
    const page = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(page);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    var branch: []const u8 = default_branch;
    var suite_dir: []const u8 = "test/yaml-test-suite";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--branch")) {
            i += 1;
            if (i < args.len) branch = args[i];
        } else if (mem.eql(u8, args[i], "--suite-dir")) {
            i += 1;
            if (i < args.len) suite_dir = args[i];
        } else if (mem.eql(u8, args[i], "--help")) {
            printUsage();
            return;
        }
    }

    std.debug.print("\nFetching YAML Test Suite ({s})...\n", .{branch});

    removeTree(clone_dir);
    try runGitClone(alloc, branch);
    defer removeTree(clone_dir);

    var clone = fs.openDirAbsolute(clone_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open clone dir: {}\n", .{err});
        std.process.exit(1);
    };
    defer clone.close();

    fs.cwd().makePath(suite_dir) catch |err| {
        std.debug.print("error: cannot create {s}: {}\n", .{ suite_dir, err });
        std.process.exit(1);
    };

    const tag_pairs = try buildTagPairs(alloc, clone);
    var cases: std.ArrayList(TestCase) = .empty;
    try collectTestCases(alloc, clone, &cases);

    for (cases.items) |*tc| {
        tc.filename = assignGroup(tag_pairs, tc.id);
    }

    std.mem.sortUnstable(TestCase, cases.items, {}, struct {
        fn lessThan(_: void, a: TestCase, b: TestCase) bool {
            const fc = mem.order(u8, a.filename, b.filename);
            if (fc == .lt) return true;
            if (fc == .gt) return false;
            return mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    var changes: std.ArrayList(Change) = .empty;
    var generated_files = std.StringHashMap(void).init(alloc);

    var group_start: usize = 0;
    while (group_start < cases.items.len) {
        const filename = cases.items[group_start].filename;
        var group_end = group_start + 1;
        while (group_end < cases.items.len and mem.eql(u8, cases.items[group_end].filename, filename)) {
            group_end += 1;
        }

        const content = try generateTestFile(alloc, cases.items[group_start..group_end]);
        try generated_files.put(filename, {});

        const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ suite_dir, filename });
        const existing = fs.cwd().readFileAlloc(alloc, file_path, 4 * 1024 * 1024) catch null;

        if (existing) |old| {
            if (!mem.eql(u8, old, content)) {
                fs.cwd().writeFile(.{ .sub_path = file_path, .data = content }) catch {};
                try changes.append(alloc, .{ .filename = filename, .kind = .changed });
            }
        } else {
            fs.cwd().writeFile(.{ .sub_path = file_path, .data = content }) catch {};
            try changes.append(alloc, .{ .filename = filename, .kind = .new });
        }

        group_start = group_end;
    }

    // Detect removed .test files
    var local = fs.cwd().openDir(suite_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open {s}: {}\n", .{ suite_dir, err });
        std.process.exit(1);
    };
    defer local.close();

    var local_it = local.iterate();
    while (local_it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.name, ".test")) continue;
        if (generated_files.get(entry.name) == null) {
            try changes.append(alloc, .{ .filename = try alloc.dupe(u8, entry.name), .kind = .removed });
        }
    }

    printReport(changes.items, cases.items.len);
}

fn buildTagPairs(alloc: Allocator, clone: fs.Dir) ![]TagPair {
    var pairs: std.ArrayList(TagPair) = .empty;

    var tags_dir = clone.openDir("tags", .{ .iterate = true }) catch return pairs.items;
    defer tags_dir.close();

    var tag_it = tags_dir.iterate();
    while (try tag_it.next()) |tag_entry| {
        const tag_name = try alloc.dupe(u8, tag_entry.name);

        var tag_sub = tags_dir.openDir(tag_name, .{ .iterate = true }) catch continue;
        defer tag_sub.close();

        var id_it = tag_sub.iterate();
        while (try id_it.next()) |id_entry| {
            try pairs.append(alloc, .{
                .test_id = try alloc.dupe(u8, id_entry.name),
                .tag = tag_name,
            });
        }
    }

    return pairs.items;
}

fn collectTestCases(alloc: Allocator, clone: fs.Dir, cases: *std.ArrayList(TestCase)) !void {
    var dir_it = clone.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        if (mem.eql(u8, entry.name, "tags") or mem.eql(u8, entry.name, "name")) continue;

        const id = try alloc.dupe(u8, entry.name);
        var case_dir = clone.openDir(id, .{ .iterate = true }) catch continue;
        defer case_dir.close();

        if (fileExists(case_dir, "in.yaml")) {
            if (try readTestCase(alloc, case_dir, id)) |tc| {
                try cases.append(alloc, tc);
            }
        } else {
            var sub_it = case_dir.iterate();
            while (try sub_it.next()) |sub| {
                if (sub.kind != .directory) continue;
                var sub_dir = case_dir.openDir(sub.name, .{}) catch continue;
                defer sub_dir.close();

                const full_id = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ id, sub.name });
                if (try readTestCase(alloc, sub_dir, full_id)) |tc| {
                    try cases.append(alloc, tc);
                }
            }
        }
    }
}

fn readTestCase(alloc: Allocator, dir: fs.Dir, id: []const u8) !?TestCase {
    const in_yaml = readFileFromDir(alloc, dir, "in.yaml") orelse return null;
    const name_raw = readFileFromDir(alloc, dir, "===") orelse id;
    const name = mem.trim(u8, name_raw, &std.ascii.whitespace);

    return .{
        .id = id,
        .name = name,
        .in_yaml = in_yaml,
        .in_json = readFileFromDir(alloc, dir, "in.json"),
        .is_error = fileExists(dir, "error"),
        .filename = "misc.test",
    };
}

fn parentId(id: []const u8) []const u8 {
    return if (mem.indexOf(u8, id, "/")) |pos| id[0..pos] else id;
}

fn assignGroup(tag_pairs: []const TagPair, id: []const u8) []const u8 {
    const pid = parentId(id);
    for (file_groups) |group| {
        for (group.tags) |gtag| {
            for (tag_pairs) |pair| {
                if (mem.eql(u8, pair.test_id, pid) and mem.eql(u8, pair.tag, gtag)) {
                    return group.filename;
                }
            }
        }
    }
    return "misc.test";
}

fn generateTestFile(alloc: Allocator, cases: []const TestCase) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (cases, 0..) |tc, idx| {
        if (idx > 0) try buf.append(alloc, '\n');

        try buf.appendSlice(alloc, "<!-- test: ");
        try buf.appendSlice(alloc, tc.name);
        try buf.appendSlice(alloc, " [");
        try buf.appendSlice(alloc, tc.id);
        try buf.appendSlice(alloc, "] -->\n");

        if (tc.is_error) {
            try buf.appendSlice(alloc, "<!-- error -->\n");
        }

        try buf.appendSlice(alloc, "<!-- in -->\n");
        try buf.appendSlice(alloc, tc.in_yaml);
        if (tc.in_yaml.len == 0 or tc.in_yaml[tc.in_yaml.len - 1] != '\n') {
            try buf.append(alloc, '\n');
        }

        if (tc.in_json) |json| {
            try buf.appendSlice(alloc, "<!-- json -->\n");
            try buf.appendSlice(alloc, json);
            if (json.len == 0 or json[json.len - 1] != '\n') {
                try buf.append(alloc, '\n');
            }
        }
    }

    return buf.items;
}

fn readFileFromDir(alloc: Allocator, dir: fs.Dir, name: []const u8) ?[]const u8 {
    return dir.readFileAlloc(alloc, name, 1024 * 1024) catch null;
}

fn fileExists(dir: fs.Dir, name: []const u8) bool {
    const f = dir.openFile(name, .{}) catch return false;
    f.close();
    return true;
}

fn runGitClone(alloc: Allocator, branch: []const u8) !void {
    var child = Child.init(
        &.{ "git", "-c", "advice.detachedHead=false", "clone", "--depth", "1", "--branch", branch, "--quiet", repo_url, clone_dir },
        alloc,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Ignore;

    try child.spawn();

    if (child.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        var stderr_r = stderr_file.reader(&buf);
        _ = stderr_r.interface.discardRemaining() catch 0;
    }

    const term = child.wait() catch |err| {
        std.debug.print("error: failed to wait for git: {}\n", .{err});
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("error: git clone failed (exit code {d})\n", .{code});
                std.process.exit(1);
            }
        },
        else => {
            std.debug.print("error: git clone terminated abnormally\n", .{});
            std.process.exit(1);
        },
    }
}

fn removeTree(path: []const u8) void {
    var child = Child.init(
        &.{ "rm", "-rf", path },
        std.heap.page_allocator,
    );
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    _ = child.spawnAndWait() catch {};
}

fn printReport(changes: []const Change, total_cases: usize) void {
    var n_new: usize = 0;
    var n_changed: usize = 0;
    var n_removed: usize = 0;

    for (changes) |c| {
        switch (c.kind) {
            .new => n_new += 1,
            .changed => n_changed += 1,
            .removed => n_removed += 1,
        }
    }

    std.debug.print("\nGenerated {d} test cases into .test files.\n", .{total_cases});

    if (changes.len == 0) {
        std.debug.print("All .test files are up to date.\n\n", .{});
        return;
    }

    if (n_new > 0) {
        std.debug.print("\nNew files ({d}):\n", .{n_new});
        for (changes) |c| {
            if (c.kind == .new) std.debug.print("  {s}\n", .{c.filename});
        }
    }

    if (n_changed > 0) {
        std.debug.print("\nChanged files ({d}):\n", .{n_changed});
        for (changes) |c| {
            if (c.kind == .changed) std.debug.print("  {s}\n", .{c.filename});
        }
    }

    if (n_removed > 0) {
        std.debug.print("\nOrphaned files ({d}):\n", .{n_removed});
        for (changes) |c| {
            if (c.kind == .removed) std.debug.print("  {s}\n", .{c.filename});
        }
    }

    std.debug.print("\nSummary: {d} new, {d} changed, {d} orphaned\n\n", .{ n_new, n_changed, n_removed });
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zig build fetch-suite [-- OPTIONS]
        \\
        \\Fetch YAML Test Suite from GitHub and generate .test files.
        \\
        \\Options:
        \\  --branch NAME   Branch to fetch (default: data-2022-01-17)
        \\  --suite-dir DIR Local suite directory (default: test/yaml-test-suite)
        \\  --help          Show this help
        \\
    , .{});
}
