const std = @import("std");

const PerfTest = struct {
    name: []const u8,
    bob_file: []const u8,
    py_file: []const u8,
    go_file: []const u8,
    c_file: []const u8,
    rs_file: []const u8,
    expected_output: []const u8,
};

const perf_tests = [_]PerfTest{
    .{
        .name = "factorial",
        .bob_file = "src/tests/stuff/moretest/factorial.bob",
        .py_file = "src/tests/stuff/moretest/factorial.py",
        .go_file = "src/tests/stuff/moretest/factorial.go",
        .c_file = "src/tests/stuff/moretest/factorial.c",
        .rs_file = "src/tests/stuff/moretest/factorial.rs",
        .expected_output =
        \\factorial
        \\2432902008176640000
        ,
    },
    .{
        .name = "collatz",
        .bob_file = "src/tests/stuff/moretest/collatz.bob",
        .py_file = "src/tests/stuff/moretest/collatz.py",
        .go_file = "src/tests/stuff/moretest/collatz.go",
        .c_file = "src/tests/stuff/moretest/collatz.c",
        .rs_file = "src/tests/stuff/moretest/collatz.rs",
        .expected_output =
        \\collatz
        \\5025114
        ,
    },
    .{
        .name = "gcd",
        .bob_file = "src/tests/stuff/moretest/gcd.bob",
        .py_file = "src/tests/stuff/moretest/gcd.py",
        .go_file = "src/tests/stuff/moretest/gcd.go",
        .c_file = "src/tests/stuff/moretest/gcd.c",
        .rs_file = "src/tests/stuff/moretest/gcd.rs",
        .expected_output =
        \\gcd
        \\2
        ,
    },
    .{
        .name = "sorting",
        .bob_file = "src/tests/stuff/moretest/sorting.bob",
        .py_file = "src/tests/stuff/moretest/sorting.py",
        .go_file = "src/tests/stuff/moretest/sorting.go",
        .c_file = "src/tests/stuff/moretest/sorting.c",
        .rs_file = "src/tests/stuff/moretest/sorting.rs",
        .expected_output =
        \\sorting
        \\[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150]
        ,
    },
    .{
        .name = "palindrome",
        .bob_file = "src/tests/stuff/moretest/palindrome.bob",
        .py_file = "src/tests/stuff/moretest/palindrome.py",
        .go_file = "src/tests/stuff/moretest/palindrome.go",
        .c_file = "src/tests/stuff/moretest/palindrome.c",
        .rs_file = "src/tests/stuff/moretest/palindrome.rs",
        .expected_output =
        \\palindrome
        \\true
        ,
    },
    .{
        .name = "sum_of_squares",
        .bob_file = "src/tests/stuff/moretest/sum_of_squares.bob",
        .py_file = "src/tests/stuff/moretest/sum_of_squares.py",
        .go_file = "src/tests/stuff/moretest/sum_of_squares.go",
        .c_file = "src/tests/stuff/moretest/sum_of_squares.c",
        .rs_file = "src/tests/stuff/moretest/sum_of_squares.rs",
        .expected_output =
        \\sum_of_squares
        \\41666791666750000
        ,
    },
    .{
        .name = "dict_perf",
        .bob_file = "src/tests/stuff/moretest/dict_perf.bob",
        .py_file = "src/tests/stuff/moretest/dict_perf.py",
        .go_file = "src/tests/stuff/moretest/dict_perf.go",
        .c_file = "src/tests/stuff/moretest/dict_perf.c",
        .rs_file = "src/tests/stuff/moretest/dict_perf.rs",
        .expected_output =
        \\dict_perf
        \\99990000
        ,
    },
    .{
        .name = "primes",
        .bob_file = "src/tests/stuff/moretest/primes.bob",
        .py_file = "src/tests/stuff/moretest/primes.py",
        .go_file = "src/tests/stuff/moretest/primes.go",
        .c_file = "src/tests/stuff/moretest/primes.c",
        .rs_file = "src/tests/stuff/moretest/primes.rs",
        .expected_output =
        \\primes
        \\3203324994356
        ,
    },
};

const RunResult = struct {
    ok: bool,
    out: []u8,
    ns: u64,
};

fn runCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !RunResult {
    var timer = try std.time.Timer.start();

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var err = std.ArrayList(u8).init(allocator);
    defer err.deinit();

    if (child.stdout) |s|
        try s.reader().readAllArrayList(&out, 1024 * 1024);

    if (child.stderr) |s|
        try s.reader().readAllArrayList(&err, 1024 * 1024);

    const term = try child.wait();
    const elapsed_ns = timer.read();

    if (term != .Exited or term.Exited != 0) {
        if (err.items.len > 0) {
            std.debug.print("stderr:\n{s}\n", .{err.items});
        }
        return .{
            .ok = false,
            .out = try allocator.dupe(u8, ""),
            .ns = elapsed_ns,
        };
    }

    return .{
        .ok = true,
        .out = try allocator.dupe(u8, out.items),
        .ns = elapsed_ns,
    };
}

const RefCompile = struct {
    ok: bool,
    cached: bool,
    ns: u64,
    bin: []const u8,
};

fn sourceHash(allocator: std.mem.Allocator, path: []const u8) !?u64 {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return null;
    defer allocator.free(content);
    var h = std.hash.Wyhash.init(0);
    h.update(content);
    return h.final();
}

// compiles the c/rust/go stuff once, then it caches them until their hash changes
fn refCompile(
    allocator: std.mem.Allocator,
    name: []const u8,
    lang: []const u8,
    source_path: []const u8,
    local_bin: []const u8,
    argv: []const []const u8,
) !RefCompile {
    var timer = try std.time.Timer.start();
    std.fs.cwd().makePath(".boblang/cache") catch {};
    const cache_bin = try std.fmt.allocPrint(allocator, ".boblang/cache/ref_{s}_{s}.bin", .{ name, lang });
    defer allocator.free(cache_bin);
    const cache_marker = try std.fmt.allocPrint(allocator, ".boblang/cache/ref_{s}_{s}.hash", .{ name, lang });
    defer allocator.free(cache_marker);

    if (try sourceHash(allocator, source_path)) |h| {
        const expected = try std.fmt.allocPrint(allocator, "{d}", .{h});
        defer allocator.free(expected);
        if (std.fs.cwd().readFileAlloc(allocator, cache_marker, 64)) |m| {
            defer allocator.free(m);
            if (std.mem.eql(u8, std.mem.trim(u8, m, " \n\r\t"), expected)) {
                if (std.fs.cwd().access(cache_bin, .{})) |_| {
                    const runnable = try std.fmt.allocPrint(allocator, "./{s}", .{cache_bin});
                    return .{ .ok = true, .cached = true, .ns = timer.read(), .bin = runnable };
                } else |_| {}
            }
        } else |_| {}
    }

    const res = try runCapture(allocator, argv);
    defer allocator.free(res.out);
    if (!res.ok) return .{ .ok = false, .cached = false, .ns = res.ns, .bin = "" };

    std.fs.cwd().copyFile(local_bin, std.fs.cwd(), cache_bin, .{}) catch {};
    if (try sourceHash(allocator, source_path)) |h| {
        const marker_f = std.fs.cwd().createFile(cache_marker, .{}) catch return .{ .ok = true, .cached = false, .ns = res.ns, .bin = try std.fmt.allocPrint(allocator, "./{s}", .{local_bin}) };
        defer marker_f.close();
        marker_f.writer().print("{d}", .{h}) catch {};
    }
    return .{ .ok = true, .cached = false, .ns = res.ns, .bin = try std.fmt.allocPrint(allocator, "./{s}", .{local_bin}) };
}

// avg for noise prone runs like 10ms or smaller
fn runCaptureBest(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !RunResult {
    const first = try runCapture(allocator, argv);
    if (!first.ok or first.ns >= 10_000_000) return first;
    var best_ns = first.ns;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const r = try runCapture(allocator, argv);
        if (r.ok and r.ns < best_ns) best_ns = r.ns;
        allocator.free(r.out);
    }
    return .{ .ok = true, .out = first.out, .ns = best_ns };
}

fn printTime(ns: u64) void {
    if (ns < 1_000) {
        std.debug.print("{d}ns", .{ns});
    } else if (ns < 1_000_000) {
        std.debug.print("{d:.3}µs", .{
            @as(f64, @floatFromInt(ns)) / 1_000.0,
        });
    } else if (ns < 1_000_000_000) {
        std.debug.print("{d:.3}ms", .{
            @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        });
    } else {
        std.debug.print("{d:.3}s", .{
            @as(f64, @floatFromInt(ns)) / 1_000_000_000.0,
        });
    }
}

fn printRatio(a: u64, b: u64) void {
    const ratio = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
    std.debug.print("{d:.3}", .{ratio});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const compiler_bin = if (std.os.argv.len > 1)
        std.mem.sliceTo(std.os.argv[1], 0)
    else
        "zig-out/bin/boblang";

    var total_passed: usize = 0;
    var total_failed: usize = 0;

    var total_speedup_vs_py: f64 = 0.0;
    var speedup_vs_py_count: usize = 0;
    var total_speedup_vs_go: f64 = 0.0;
    var speedup_vs_go_count: usize = 0;
    var total_speedup_vs_c: f64 = 0.0;
    var speedup_vs_c_count: usize = 0;
    var total_speedup_vs_rs: f64 = 0.0;
    var speedup_vs_rs_count: usize = 0;

    for (perf_tests) |pt| {
        std.fs.cwd().deleteFile("output.ll") catch {};
        std.fs.cwd().deleteFile("output") catch {};

        const go_bin_name = try std.fmt.allocPrint(allocator, "go_bin_{s}", .{pt.name});
        defer allocator.free(go_bin_name);

        const compile_argv = &[_][]const u8{
            compiler_bin,
            "build",
            pt.bob_file,
            "-o",
            "output",
        };
        const compile = try runCapture(allocator, compile_argv);
        defer allocator.free(compile.out);

        if (!compile.ok) {
            std.debug.print("[FAIL] [{s}] compilation failed (", .{pt.name});
            printTime(compile.ns);
            std.debug.print(")\n", .{});
            total_failed += 1;
            continue;
        }

        const run_argv = &[_][]const u8{"./output"};
        const run = try runCaptureBest(allocator, run_argv);
        defer allocator.free(run.out);

        if (!run.ok) {
            std.debug.print("[FAIL] [{s}] runtime failed (", .{pt.name});
            printTime(run.ns);
            std.debug.print(")\n", .{});
            total_failed += 1;
            continue;
        }

        const actual = std.mem.trim(u8, run.out, "\n\r\t ");
        const expected = std.mem.trim(u8, pt.expected_output, "\n\r\t ");

        if (!std.mem.eql(u8, actual, expected)) {
            std.debug.print("[FAIL] [{s}] wrong output\n", .{pt.name});
            total_failed += 1;
            continue;
        }

        std.debug.print("[PASS] [{s}]\n", .{pt.name});
        std.debug.print("  boblang: compile=", .{});
        printTime(compile.ns);
        std.debug.print("  run=", .{});
        printTime(run.ns);
        std.debug.print("\n", .{});

        const py_argv = &[_][]const u8{ "python3", pt.py_file };
        const py = try runCaptureBest(allocator, py_argv);
        defer allocator.free(py.out);

        if (py.ok) {
            const speedup = @as(f64, @floatFromInt(py.ns)) / @as(f64, @floatFromInt(run.ns));
            std.debug.print("  python:   ", .{});
            printTime(py.ns);
            std.debug.print("  (boblang is ", .{});
            printRatio(py.ns, run.ns);
            std.debug.print("x faster)\n", .{});
            total_speedup_vs_py += speedup;
            speedup_vs_py_count += 1;
        } else {
            std.debug.print("  python:   N/A\n", .{});
        }

        std.fs.cwd().deleteFile(go_bin_name) catch {};
        const go_compile_argv = &[_][]const u8{ "go", "build", "-o", go_bin_name, "-ldflags=-s -w", pt.go_file };
        const go_compile = try refCompile(allocator, pt.name, "go", pt.go_file, go_bin_name, go_compile_argv);
        defer allocator.free(go_compile.bin);

        if (!go_compile.ok) {
            std.debug.print("  go:       compile failed (skipping)\n", .{});
            continue;
        }

        const go_run_argv = &[_][]const u8{go_compile.bin};
        const go_run = try runCaptureBest(allocator, go_run_argv);
        defer allocator.free(go_run.out);

        std.debug.print("  go:       compile=", .{});
        if (go_compile.cached) std.debug.print("(cached) ", .{}) else printTime(go_compile.ns);
        std.debug.print("  run=", .{});
        printTime(go_run.ns);
        std.debug.print("\n", .{});

        if (go_run.ok) {
            const speedup = @as(f64, @floatFromInt(go_run.ns)) / @as(f64, @floatFromInt(run.ns));
            std.debug.print("            (boblang is ", .{});
            printRatio(go_run.ns, run.ns);
            std.debug.print("x vs go)\n", .{});
            total_speedup_vs_go += speedup;
            speedup_vs_go_count += 1;
        }

        std.fs.cwd().deleteFile(go_bin_name) catch {};

        const c_bin_name = try std.fmt.allocPrint(allocator, "c_bin_{s}", .{pt.name});
        defer allocator.free(c_bin_name);

        const c_compile_argv = &[_][]const u8{ "clang", "-O2", "-o", c_bin_name, pt.c_file };
        const c_compile = try refCompile(allocator, pt.name, "c", pt.c_file, c_bin_name, c_compile_argv);
        defer allocator.free(c_compile.bin);

        if (!c_compile.ok) {
            std.debug.print("  c:        compile failed (skipping)\n", .{});
        } else {
            const c_run_argv = &[_][]const u8{c_compile.bin};
            const c_run = try runCaptureBest(allocator, c_run_argv);
            defer allocator.free(c_run.out);

            std.debug.print("  c:        compile=", .{});
            if (c_compile.cached) std.debug.print("(cached) ", .{}) else printTime(c_compile.ns);
            std.debug.print("  run=", .{});
            printTime(c_run.ns);
            std.debug.print("\n", .{});

            if (c_run.ok) {
                const speedup = @as(f64, @floatFromInt(c_run.ns)) / @as(f64, @floatFromInt(run.ns));
                std.debug.print("            (boblang is ", .{});
                printRatio(c_run.ns, run.ns);
                std.debug.print("x vs c)\n", .{});
                total_speedup_vs_c += speedup;
                speedup_vs_c_count += 1;
            }
        }

        std.fs.cwd().deleteFile(c_bin_name) catch {};

        const rs_bin_name = try std.fmt.allocPrint(allocator, "rs_bin_{s}", .{pt.name});
        defer allocator.free(rs_bin_name);

        const rs_compile_argv = &[_][]const u8{ "rustc", "-O", "-o", rs_bin_name, pt.rs_file };
        const rs_compile = try refCompile(allocator, pt.name, "rust", pt.rs_file, rs_bin_name, rs_compile_argv);
        defer allocator.free(rs_compile.bin);

        if (!rs_compile.ok) {
            std.debug.print("  rust:     compile failed (skipping)\n", .{});
        } else {
            const rs_run_argv = &[_][]const u8{rs_compile.bin};
            const rs_run = try runCaptureBest(allocator, rs_run_argv);
            defer allocator.free(rs_run.out);

            std.debug.print("  rust:     compile=", .{});
            if (rs_compile.cached) std.debug.print("(cached) ", .{}) else printTime(rs_compile.ns);
            std.debug.print("  run=", .{});
            printTime(rs_run.ns);
            std.debug.print("\n", .{});

            if (rs_run.ok) {
                const speedup = @as(f64, @floatFromInt(rs_run.ns)) / @as(f64, @floatFromInt(run.ns));
                std.debug.print("            (boblang is ", .{});
                printRatio(rs_run.ns, run.ns);
                std.debug.print("x vs rust)\n", .{});
                total_speedup_vs_rs += speedup;
                speedup_vs_rs_count += 1;
            }
        }

        std.fs.cwd().deleteFile(rs_bin_name) catch {};

        total_passed += 1;
    }

    std.fs.cwd().deleteFile("output.ll") catch {};
    std.fs.cwd().deleteFile("output") catch {};

    std.debug.print(
        "\nresults: {d} passed, {d} failed\n",
        .{ total_passed, total_failed },
    );

    if (speedup_vs_py_count > 0) {
        const avg_py = total_speedup_vs_py / @as(f64, @floatFromInt(speedup_vs_py_count));
        std.debug.print(
            "Avg vs python: {d:.2}x (boblang is faster)\n",
            .{avg_py},
        );
    }

    if (speedup_vs_go_count > 0) {
        const avg_go = total_speedup_vs_go / @as(f64, @floatFromInt(speedup_vs_go_count));
        if (avg_go >= 1.0) {
            std.debug.print(
                "Avg vs go:     {d:.2}x (boblang is faster)\n",
                .{avg_go},
            );
        } else {
            std.debug.print(
                "Avg vs go:     {d:.2}x (boblang is slower)\n",
                .{avg_go},
            );
        }
    }

    if (speedup_vs_c_count > 0) {
        const avg_c = total_speedup_vs_c / @as(f64, @floatFromInt(speedup_vs_c_count));
        if (avg_c >= 1.0) {
            std.debug.print("Avg vs c:      {d:.2}x (boblang is faster)\n", .{avg_c});
        } else {
            std.debug.print("Avg vs c:      {d:.2}x (boblang is slower)\n", .{avg_c});
        }
    }

    if (speedup_vs_rs_count > 0) {
        const avg_rs = total_speedup_vs_rs / @as(f64, @floatFromInt(speedup_vs_rs_count));
        if (avg_rs >= 1.0) {
            std.debug.print("Avg vs rust:   {d:.2}x (boblang is faster)\n", .{avg_rs});
        } else {
            std.debug.print("Avg vs rust:   {d:.2}x (boblang is slower)\n", .{avg_rs});
        }
    }

    if (total_failed > 0)
        std.process.exit(1);
}
