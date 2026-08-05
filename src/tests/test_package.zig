const std = @import("std");

const TestCase = struct {
    name: []const u8,
    setup: *const fn (allocator: std.mem.Allocator, dir: []const u8, compiler: []const u8) anyerror!void,
    run: *const fn (allocator: std.mem.Allocator, dir: []const u8, compiler: []const u8) anyerror!?[]const u8,
    expected: ?[]const u8,
};

const CmdResult = struct { stdout: []u8, stderr: []u8, term: std.process.Child.Term };

fn execCmd(allocator: std.mem.Allocator, argv: []const []const u8) !CmdResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout = std.ArrayList(u8).init(allocator);
    if (child.stdout) |out| try out.reader().readAllArrayList(&stdout, 1024 * 1024);
    var stderr = std.ArrayList(u8).init(allocator);
    if (child.stderr) |err| try err.reader().readAllArrayList(&stderr, 1024 * 1024);
    const term = try child.wait();
    return CmdResult{ .stdout = try stdout.toOwnedSlice(), .stderr = try stderr.toOwnedSlice(), .term = term };
}

fn execInDir(allocator: std.mem.Allocator, work_dir: []const u8, argv: []const []const u8) !CmdResult {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try w.print("cd '{s}' &&", .{work_dir});
    for (argv) |a| try w.print(" '{s}'", .{a});
    const result = try execCmd(allocator, &[_][]const u8{ "sh", "-c", try buf.toOwnedSlice() });
    return result;
}

fn writeFile(_: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

fn makeDir(_: std.mem.Allocator, path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn pkgPath(allocator: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/pkg", .{dir});
}

fn projPath(allocator: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/proj", .{dir});
}

fn boblangConf(allocator: std.mem.Allocator, proj_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/boblang.conf", .{proj_dir});
}

fn mainBob(allocator: std.mem.Allocator, proj_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/main.bob", .{proj_dir});
}


fn testBasicPackageSetup(allocator: std.mem.Allocator, dir: []const u8, _: []const u8) !void {
    _ = allocator;
    const pkg = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/pkg", .{dir});
    try makeDir(std.heap.page_allocator, pkg);
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/boblang.conf", .{pkg}),
        \\dialect: "python-like"
        \\output: "mathlib"
        \\optimize: "ReleaseFast"
        \\packages: {}
        \\files: {
        \\    mathlib.bob
        \\}
        \\
    );
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/mathlib.bob", .{pkg}),
        \\func add(a, b):
        \\    return a + b
        \\
        \\func multiply(a, b):
        \\    return a * b
        \\
    );
}

fn testBasicPackageRun(allocator: std.mem.Allocator, dir: []const u8, compiler: []const u8) !?[]const u8 {
    const pkg_dir = try pkgPath(allocator, dir);
    const proj_dir = try projPath(allocator, dir);
    try makeDir(allocator, proj_dir);

    try writeFile(allocator, try boblangConf(allocator, proj_dir),
        \\dialect: "python-like"
        \\output: "testapp"
        \\optimize: "ReleaseFast"
        \\packages: {}
        \\files: {
        \\    main.bob
        \\}
        \\
    );
    try writeFile(allocator, try mainBob(allocator, proj_dir),
        \\import mathlib
        \\x = mathlib.add(40, 2)
        \\print(x)
        \\y = mathlib.multiply(6, 7)
        \\print(y)
        \\
    );

    const out_name = "testapp";
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{proj_dir, out_name});
    _ = try execCmd(allocator, &[_][]const u8{ compiler, "pack", pkg_dir });
    {
        const install = try execInDir(allocator, proj_dir, &[_][]const u8{ compiler, "pkg", "install", pkg_dir, "mathlib" });
        if (install.term != .Exited or install.term.Exited != 0) return "install failed";
    }
    {
        const build = try execInDir(allocator, proj_dir, &[_][]const u8{ compiler, "build", ".", "-o", output_path });
        if (build.term != .Exited or build.term.Exited != 0) return "build failed";
    }
    {
        const run = try execCmd(allocator, &[_][]const u8{output_path});
        if (run.term != .Exited or run.term.Exited != 0) return "run failed";
        return run.stdout;
    }
}


fn testCPackageSetup(allocator: std.mem.Allocator, dir: []const u8, _: []const u8) !void {
    _ = allocator;
    const pkg = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/pkg", .{dir});
    try makeDir(std.heap.page_allocator, pkg);
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/helper.c", .{pkg}),
        \\long long add_ints(long long a, long long b) {
        \\    return a + b;
        \\}
        \\long long double_int(long long x) {
        \\    return x * 2;
        \\}
        \\
    );
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/boblang.conf", .{pkg}),
        \\dialect: "python-like"
        \\output: "cpkg"
        \\optimize: "ReleaseFast"
        \\packages: {}
        \\files: {
        \\    helper.c
        \\}
        \\
    );
}

fn testCPackageRun(allocator: std.mem.Allocator, dir: []const u8, compiler: []const u8) !?[]const u8 {
    const pkg_dir = try pkgPath(allocator, dir);
    const proj_dir = try projPath(allocator, dir);
    try makeDir(allocator, proj_dir);

    try writeFile(allocator, try boblangConf(allocator, proj_dir),
        \\dialect: "python-like"
        \\output: "testapp"
        \\optimize: "ReleaseFast"
        \\packages: {}
        \\files: {
        \\    main.bob
        \\}
        \\
    );
    try writeFile(allocator, try mainBob(allocator, proj_dir),
        \\import cpkg
        \\print(cpkg.add_ints(100, 23))
        \\print(cpkg.double_int(21))
        \\
    );

    const out_name = "testapp";
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{proj_dir, out_name});
    _ = try execCmd(allocator, &[_][]const u8{ compiler, "pack", pkg_dir });
    {
        const install = try execInDir(allocator, proj_dir, &[_][]const u8{ compiler, "pkg", "install", pkg_dir, "cpkg" });
        if (install.term != .Exited or install.term.Exited != 0) return "install failed";
    }
    {
        const build = try execInDir(allocator, proj_dir, &[_][]const u8{ compiler, "build", ".", "-o", output_path });
        if (build.term != .Exited or build.term.Exited != 0) return "build failed";
    }
    {
        const run = try execCmd(allocator, &[_][]const u8{output_path});
        if (run.term != .Exited or run.term.Exited != 0) return "run failed";
        return run.stdout;
    }
}


fn testHybridPackageSetup(allocator: std.mem.Allocator, dir: []const u8, _: []const u8) !void {
    _ = allocator;
    const pkg = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/pkg", .{dir});
    try makeDir(std.heap.page_allocator, pkg);
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/math.c", .{pkg}),
        \\long long mul_ints(long long a, long long b) {
        \\    return a * b;
        \\}
        \\
    );
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/wrapper.bob", .{pkg}),
        \\func add_and_double(a, b):
        \\    return (a + b) * 2
        \\
    );
    try writeFile(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{s}/boblang.conf", .{pkg}),
        \\dialect: "python-like"
        \\output: "hybrid"
        \\optimize: "ReleaseFast"
        \\packages: {}
        \\files: {
        \\    math.c
        \\    wrapper.bob
        \\}
        \\
    );
}

fn testHybridPackageRun(allocator: std.mem.Allocator, dir: []const u8, compiler: []const u8) !?[]const u8 {
    const pkg_dir = try pkgPath(allocator, dir);
    const proj_dir = try projPath(allocator, dir);
    try makeDir(allocator, proj_dir);

    try writeFile(allocator, try boblangConf(allocator, proj_dir),
        \\dialect: "python-like"
        \\output: "testapp"
        \\optimize: "ReleaseFast"
        \\packages: {}
        \\files: {
        \\    main.bob
        \\}
        \\
    );
    try writeFile(allocator, try mainBob(allocator, proj_dir),
        \\import hybrid
        \\print(hybrid.add_and_double(10, 5))
        \\print(hybrid.mul_ints(6, 7))
        \\
    );

    const out_name = "testapp";
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{proj_dir, out_name});
    _ = try execCmd(allocator, &[_][]const u8{ compiler, "pack", pkg_dir });
    {
        const install = try execInDir(allocator, proj_dir, &[_][]const u8{ compiler, "pkg", "install", pkg_dir, "hybrid" });
        if (install.term != .Exited or install.term.Exited != 0) return "install failed";
    }
    {
        const build = try execInDir(allocator, proj_dir, &[_][]const u8{ compiler, "build", ".", "-o", output_path });
        if (build.term != .Exited or build.term.Exited != 0) return "build failed";
    }
    {
        const run = try execCmd(allocator, &[_][]const u8{output_path});
        if (run.term != .Exited or run.term.Exited != 0) return "run failed";
        return run.stdout;
    }
}


const test_cases = [_]TestCase{
    .{
        .name = "basic_package",
        .setup = testBasicPackageSetup,
        .run = testBasicPackageRun,
        .expected = "42\n42",
    },
    .{
        .name = "c_package",
        .setup = testCPackageSetup,
        .run = testCPackageRun,
        .expected = "123\n42",
    },
    .{
        .name = "hybrid_package",
        .setup = testHybridPackageSetup,
        .run = testHybridPackageRun,
        .expected = "30\n42",
    },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const compiler_bin = if (std.os.argv.len > 1) blk: {
        const raw = std.mem.sliceTo(std.os.argv[1], 0);

        break :blk try std.fs.realpathAlloc(allocator, raw);
    } else
        "boblang";

    var total_passed: u32 = 0;
    var total_failed: u32 = 0;
    var total_skipped: u32 = 0;

    const base_dir = "/tmp/boblang_pkg_zigtest";

    for (test_cases) |tc| {
        const test_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, tc.name });
        std.fs.cwd().deleteTree(test_dir) catch {};
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        tc.setup(allocator, test_dir, compiler_bin) catch |err| {
            std.debug.print("[SKIP] [{s}] setup error: {s}\n", .{ tc.name, @errorName(err) });
            total_skipped += 1;
            continue;
        };

        const result = tc.run(allocator, test_dir, compiler_bin) catch |err| {
            std.debug.print("[FAIL] [{s}] error: {s}\n", .{ tc.name, @errorName(err) });
            total_failed += 1;
            continue;
        };

        if (result) |output| {
            if (std.mem.startsWith(u8, output, "SKIP:")) {
                std.debug.print("[SKIP] [{s}] {s}\n", .{ tc.name, output[6..] });
                total_skipped += 1;
                continue;
            }
            if (tc.expected) |expected| {
                const trimmed = std.mem.trim(u8, output, "\n\r\t ");
                if (std.mem.eql(u8, trimmed, expected)) {
                    std.debug.print("[PASS] [{s}]\n", .{tc.name});
                    total_passed += 1;
                } else {
                    std.debug.print("[FAIL] [{s}] output mismatch\n", .{tc.name});
                    std.debug.print("  expected:\n{s}\n  actual:\n{s}\n", .{ expected, trimmed });
                    total_failed += 1;
                }
            } else {
                std.debug.print("[PASS] [{s}]\n", .{tc.name});
                total_passed += 1;
            }
        } else {
            std.debug.print("[FAIL] [{s}] no output\n", .{tc.name});
            total_failed += 1;
        }
    }

    std.debug.print("\npackage tests results:: {d} passed, {d} failed, {d} skipped\n", .{ total_passed, total_failed, total_skipped });
    if (total_failed > 0) std.process.exit(1);
}
