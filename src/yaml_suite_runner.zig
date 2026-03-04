const std = @import("std");
const Allocator = std.mem.Allocator;
const comb = @import("root.zig");

const TestResults = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn total(self: TestResults) usize {
        return self.passed + self.failed + self.skipped;
    }

    fn add(self: *TestResults, other: TestResults) void {
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
    }
};

fn readFile(allocator: Allocator, dir: std.fs.Dir, name: []const u8) ?[]const u8 {
    const file = dir.openFile(name, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch null;
}

fn fileExists(dir: std.fs.Dir, name: []const u8) bool {
    const file = dir.openFile(name, .{}) catch return false;
    file.close();
    return true;
}

fn runSingleCase(
    allocator: Allocator,
    case_dir: std.fs.Dir,
    test_id: []const u8,
    results: *TestResults,
) void {
    const yaml_input = readFile(allocator, case_dir, "in.yaml") orelse {
        results.skipped += 1;
        return;
    };

    const is_error_test = fileExists(case_dir, "error");

    if (is_error_test) {
        if (comb.parseFromSlice(std.json.Value, allocator, yaml_input, .{ .duplicate_keys = .last_wins })) |*p| {
            p.deinit();
            results.failed += 1;
            std.debug.print("  FAIL {s}: expected error, parsed OK\n", .{test_id});
        } else |_| {
            results.passed += 1;
        }
        return;
    }

    const json_expected = readFile(allocator, case_dir, "in.json") orelse {
        if (comb.parseFromSlice(std.json.Value, allocator, yaml_input, .{ .duplicate_keys = .last_wins })) |*p| {
            p.deinit();
            results.passed += 1;
        } else |_| {
            results.failed += 1;
            std.debug.print("  FAIL {s}: parse error (no json to compare)\n", .{test_id});
        }
        return;
    };

    var yaml_parsed = comb.parseFromSlice(std.json.Value, allocator, yaml_input, .{ .duplicate_keys = .last_wins }) catch {
        results.failed += 1;
        std.debug.print("  FAIL {s}: YAML parse error\n", .{test_id});
        return;
    };
    defer yaml_parsed.deinit();

    const json_parsed = std.json.parseFromSlice(std.json.Value, allocator, json_expected, .{}) catch {
        results.skipped += 1;
        return;
    };
    defer json_parsed.deinit();

    if (jsonEqual(yaml_parsed.value, json_parsed.value)) {
        results.passed += 1;
    } else {
        results.failed += 1;
        if (results.failed <= 30) {
            const got_tag: std.meta.Tag(std.json.Value) = yaml_parsed.value;
            const exp_tag: std.meta.Tag(std.json.Value) = json_parsed.value;
            if (got_tag == .string and exp_tag == .string) {
                std.debug.print("  FAIL {s}: JSON mismatch (string)\n    got: \"{s}\"\n    exp: \"{s}\"\n", .{
                    test_id,
                    yaml_parsed.value.string,
                    json_parsed.value.string,
                });
            } else {
                std.debug.print("  FAIL {s}: JSON mismatch (got={s} expect={s})\n", .{
                    test_id,
                    @tagName(got_tag),
                    @tagName(exp_tag),
                });
            }
        }
    }
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    const TagType = std.meta.Tag(std.json.Value);
    const at: TagType = a;
    const bt: TagType = b;
    if (at != bt) {
        if (at == .integer and bt == .float)
            return @as(f64, @floatFromInt(a.integer)) == b.float;
        if (at == .float and bt == .integer)
            return a.float == @as(f64, @floatFromInt(b.integer));
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => {
            if (a.array.items.len != b.array.items.len) return false;
            for (a.array.items, b.array.items) |ai, bi| {
                if (!jsonEqual(ai, bi)) return false;
            }
            return true;
        },
        .object => {
            if (a.object.count() != b.object.count()) return false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const bv = b.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonEqual(entry.value_ptr.*, bv)) return false;
            }
            return true;
        },
    };
}

test "YAML Test Suite conformance" {
    const alloc = std.testing.allocator;

    var suite_dir = std.fs.cwd().openDir("test/yaml-test-suite", .{ .iterate = true }) catch |err| {
        std.debug.print("\n  Could not open test/yaml-test-suite: {}\n", .{err});
        return;
    };
    defer suite_dir.close();

    var total = TestResults{};

    var dir_it = suite_dir.iterate();
    while (dir_it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const test_id = entry.name;

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var test_dir = suite_dir.openDir(test_id, .{ .iterate = true }) catch continue;
        defer test_dir.close();

        if (fileExists(test_dir, "in.yaml")) {
            runSingleCase(aa, test_dir, test_id, &total);
        } else {
            var sub_it = test_dir.iterate();
            while (sub_it.next() catch null) |sub_entry| {
                if (sub_entry.kind != .directory) continue;
                var sub_dir = test_dir.openDir(sub_entry.name, .{}) catch continue;
                defer sub_dir.close();

                var id_buf: [16]u8 = undefined;
                const full_id = std.fmt.bufPrint(&id_buf, "{s}/{s}", .{ test_id, sub_entry.name }) catch test_id;
                runSingleCase(aa, sub_dir, full_id, &total);
            }
        }
    }

    std.debug.print("\n  YAML Test Suite: {d} passed, {d} failed, {d} skipped (of {d} total)\n\n", .{
        total.passed, total.failed, total.skipped, total.total(),
    });
}
