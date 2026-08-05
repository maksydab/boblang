const std = @import("std");

const Suite = enum {
    parser,
    builder,
    compile,
    perf,
    package,
    dialect,
};

fn clib(allocator: std.mem.Allocator) !void {
    const src_dir = "src/lib";
    const dst_dir = "src/tests/stuff/lib";

    try std.fs.cwd().makePath(dst_dir);

    var dir = try std.fs.cwd().openDir(src_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;

        const src_path = try std.fs.path.join(allocator, &[_][]const u8{ src_dir, entry.name });
        defer allocator.free(src_path);

        const dst_path = try std.fs.path.join(allocator, &[_][]const u8{ dst_dir, entry.name });
        defer allocator.free(dst_path);

        if (entry.kind == .directory) {
            try std.fs.cwd().makePath(dst_path);
            var subdir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
            defer subdir.close();
            var subit = subdir.iterate();
            while (try subit.next()) |subentry| {
                if (subentry.kind != .file) continue;
                const sub_src = try std.fs.path.join(allocator, &[_][]const u8{ src_path, subentry.name });
                defer allocator.free(sub_src);
                const sub_dst = try std.fs.path.join(allocator, &[_][]const u8{ dst_path, subentry.name });
                defer allocator.free(sub_dst);
                try std.fs.cwd().copyFile(sub_src, std.fs.cwd(), sub_dst, .{});
            }
        } else {
            try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
        }
    }

    {
        try std.fs.cwd().copyFile("src/bundle_config.zig", std.fs.cwd(), "src/tests/stuff/bundle_config.zig", .{});
        try std.fs.cwd().copyFile("src/embedded_runtime.zig", std.fs.cwd(), "src/tests/stuff/embedded_runtime.zig", .{});
        try std.fs.cwd().copyFile("src/boblang_conf.zig", std.fs.cwd(), "src/tests/stuff/boblang_conf.zig", .{});
    }
}

fn cullib() void {
    std.fs.cwd().deleteTree("src/tests/stuff/lib") catch {};
}

fn rsuite(allocator: std.mem.Allocator, suite: Suite, log_writer: anytype, compiler_bin: []const u8) !bool {
    const path = switch (suite) {
        .parser => "src/tests/test_parser.zig",
        .builder => "src/tests/test_builder.zig",
        .compile => "src/tests/test_compile.zig",
        .perf => "src/tests/test_perf.zig",
        .package => "src/tests/test_package.zig",
        .dialect => "src/tests/test_dialect.zig",
    };

    const header = switch (suite) {
        .parser => "\n       PARSER TEST\n",
        .builder => "\n       BUILDER TEST\n",
        .compile => "\n       COMPILER TEST\n",
        .perf => "\n       PERFORMANCE TEST\n               this part typically needs 1-4 minutes to complete\n",
        .package => "\n       PACKAGE FLOW TEST\n",
        .dialect => "\n       DIALECT TEST\n",
    };

    std.debug.print("{s}", .{header});
    try log_writer.writeAll(header);

    const cmd = switch (suite) {
        .compile, .perf, .package, .dialect => &[_][]const u8{ "zig", "run", path, "--", compiler_bin },
        else => &[_][]const u8{ "zig", "run", path },
    };

    var child = std.process.Child.init(cmd, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var buf: [4096]u8 = undefined;

    const stdout = child.stdout.?;
    const stderr = child.stderr.?;

    while (true) {
        const out_n = stdout.read(&buf) catch 0;
        if (out_n > 0) {
            try std.io.getStdOut().writeAll(buf[0..out_n]);
            try log_writer.writeAll(buf[0..out_n]);
        }

        const err_n = stderr.read(&buf) catch 0;
        if (err_n > 0) {
            try std.io.getStdErr().writeAll(buf[0..err_n]);
            try log_writer.writeAll(buf[0..err_n]);
        }

        if (out_n == 0 and err_n == 0) break;
    }

    const term = try child.wait();
    return term == .Exited and term.Exited == 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        const build_argv = &[_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast" };
        var build_child = std.process.Child.init(build_argv, allocator);
        build_child.stdout_behavior = .Ignore;
        build_child.stderr_behavior = .Ignore;
        try build_child.spawn();
        const term = try build_child.wait();
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("Failed to build compiler binary\n", .{});
            std.process.exit(1);
        }
    }

    try clib(allocator);

    {
        try std.fs.cwd().makePath("src/tests/stuff/_runtime");
        try std.fs.cwd().copyFile("runtime/runtime.c", std.fs.cwd(), "src/tests/stuff/_runtime/runtime.c", .{});
        try std.fs.cwd().copyFile("runtime/gc.c", std.fs.cwd(), "src/tests/stuff/_runtime/gc.c", .{});
        try std.fs.cwd().copyFile("runtime/gc.h", std.fs.cwd(), "src/tests/stuff/_runtime/gc.h", .{});
    }

    const compiler_bin = "zig-out/bin/boblang";

    const log_file = try std.fs.cwd().createFile("tests.log", .{});
    defer log_file.close();

    const log_writer = log_file.writer();

    std.debug.print("\n██████████████████████████████████████████▀█████████████████████████████████", .{});
    std.debug.print("\n█▄─▄─▀█─▄▄─█▄─▄─▀█▄─▄████▀▄─██▄─▀█▄─▄█─▄▄▄▄███─▄─▄─█▄─▄▄─█─▄▄▄▄█─▄─▄─█─▄▄▄▄█", .{});
    std.debug.print("\n██─▄─▀█─██─██─▄─▀██─██▀██─▀─███─█▄▀─██─██▄─█████─████─▄█▀█▄▄▄▄─███─███▄▄▄▄─█", .{});
    std.debug.print("\n▀▄▄▄▄▀▀▄▄▄▄▀▄▄▄▄▀▀▄▄▄▄▄▀▄▄▀▄▄▀▄▄▄▀▀▄▄▀▄▄▄▄▄▀▀▀▀▄▄▄▀▀▄▄▄▄▄▀▄▄▄▄▄▀▀▄▄▄▀▀▄▄▄▄▄▀", .{});
    std.debug.print("\n\n", .{});

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.skip();

    var requested = std.ArrayList([]const u8).init(allocator);
    defer requested.deinit();
    while (args_it.next()) |arg| {
        try requested.append(arg);
    }

    const all_suites = comptime [_]Suite{ .parser, .builder, .compile, .perf, .package, .dialect };
    const run_all = requested.items.len == 0;

    var any_failed = false;

    for (all_suites) |suite| {
        if (!run_all) {
            var found = false;
            for (requested.items) |req| {
                if (std.mem.eql(u8, req, @tagName(suite))) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }
        if (!try rsuite(allocator, suite, log_writer, compiler_bin)) {
            any_failed = true;
        }
    }

    cullib();

    if (any_failed) {
        std.process.exit(1);
    }
}
