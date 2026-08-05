const std = @import("std");

const TestCase = struct {
    name: []const u8,
    dialect: []const u8,
    program: []const u8,
    expected: []const u8,
};

const test_cases = [_]TestCase{
    .{
        .name = "lua_arithmetic",
        .dialect = "lua-like",
        .program =
        \\func add(a, b)
        \\    return a + b
        \\end
        \\print(add(3, 4))
        \\print(add(10, -4))
        \\
        \\x = 10
        \\y = 5
        \\print(x - y)
        \\print(x * y)
        \\print(x / y)
        ,
        .expected =
        \\7
        \\6
        \\5
        \\50
        \\2.0
        ,
    },
    .{
        .name = "lua_conditionals",
        .dialect = "lua-like",
        .program =
        \\x = 5
        \\if x > 0 then
        \\    print("positive")
        \\elseif x == 0 then
        \\print("zero")
        \\else
        \\    print("negative")
        \\end
        \\
        \\x = 0
        \\if x > 0 then
        \\    print("positive")
        \\elseif x == 0 then
        \\    print("zero")
        \\else
        \\    print("negative")
        \\end
        ,
        .expected =
        \\positive
        \\zero
        ,
    },
    .{
        .name = "lua_while",
        .dialect = "lua-like",
        .program =
        \\x = 3
        \\while x > 0 do
        \\    print(x)
        \\    x = x - 1
        \\end
        ,
        .expected =
        \\3
        \\2
        \\1
        ,
    },
    .{
        .name = "lua_for",
        .dialect = "lua-like",
        .program =
        \\s = 0
        \\for i in range(4) do
        \\    s = s + i
        \\end
        \\print(s)
        ,
        .expected =
        \\6
        ,
    },
    .{
        .name = "lua_nested_if",
        .dialect = "lua-like",
        .program =
        \\x = 5
        \\if x > 0 then
        \\    if x > 2 then
        \\        print("big")
        \\    else
        \\        print("small")
        \\    end
        \\else
        \\    print("neg")
        \\end
        ,
        .expected =
        \\big
        ,
    },
    .{
        .name = "c_arithmetic",
        .dialect = "c-like",
        .program =
         \\func add(a, b) {
        \\    return a + b;
        \\}
        \\print(add(3, 4));
        \\print(add(10, -4));
        \\
        \\x = 10;
        \\y = 5;
        \\print(x - y);
        \\print(x * y);
        \\print(x / y);
        ,
        .expected =
        \\7
        \\6
        \\5
        \\50
        \\2.0
        ,
    },
    .{
        .name = "c_conditionals",
        .dialect = "c-like",
        .program =
        \\x = 5;
        \\if (x > 0) {
        \\    print("positive");
        \\} else if (x == 0) {
        \\    print("zero");
        \\} else {
        \\    print("negative");
        \\}
        \\
        \\x = 0;
        \\if (x > 0) {
        \\    print("positive");
        \\} else if (x == 0) {
        \\    print("zero");
        \\} else {
        \\    print("negative");
        \\}
        ,
        .expected =
        \\positive
        \\zero
        ,
    },
    .{
        .name = "c_while",
        .dialect = "c-like",
        .program =
        \\x = 3;
        \\while (x > 0) {
        \\    print(x);
        \\    x = x - 1;
        \\}
        ,
        .expected =
        \\3
        \\2
        \\1
        ,
    },
    .{
        .name = "c_for",
        .dialect = "c-like",
        .program =
        \\s = 0;
        \\for (i in range(4)) {
        \\    s = s + i;
        \\}
        \\print(s);
        ,
        .expected =
        \\6
        ,
    },
    .{
        .name = "c_nested_if",
        .dialect = "c-like",
        .program =
        \\x = 5;
        \\if (x > 0) {
        \\    if (x > 2) {
        \\        print("big");
        \\    } else {
        \\        print("small");
        \\    }
        \\} else {
        \\    print("neg");
        \\}
        ,
        .expected =
        \\big
        ,
    },
    .{
        .name = "c_raw",
        .dialect = "c-like",
        .program =
        \\b: raw_bool = raw bool[100];
        \\b[5] = 1;
        \\print(b[5]);
        \\print(b[5] == 1);
        \\i: raw_int = raw int[50];
        \\i[10] = 42;
        \\print(i[10]);
        \\
        , 
        .expected =
        \\1
        \\true
        \\42
        ,
    },
    .{
        .name = "c_typed_lists",
        .dialect = "c-like",
        .program =
        \\s: list[int] = [1, 2, 3];
        \\print(s[1]);
        \\s[2] = 99;
        \\print(s[2]);
        \\print(len(s));
        \\x: int = 7;
        \\print(x);
        \\f: float = 2.5;
        \\print(f * 2.0);
        \\
        ,
        .expected =
        \\2
        \\99
        \\3
        \\7
        \\5.0
        ,
    },
    .{
        .name = "c_coalesce",
        .dialect = "c-like",
        .program =
        \\a? = nil;
        \\print(a ?? 42);
        \\b = 10;
        \\print(b ?? 42);
        \\s = "hi";
        \\print(s ?? "none");
        \\
        ,
        .expected =
        \\42
        \\10
        \\hi
        ,
    },
    .{
        .name = "c_except_var",
        .dialect = "c-like",
        .program =
        \\try {
        \\    int("notanumber");
        \\} except e {
        \\    print("caught:", e);
        \\}
        \\print("after");
        \\try {
        \\    print("no_error");
        \\} except {
        \\    print("should_not_run");
        \\}
        \\print("done");
        \\
        ,
        .expected =
        \\caught: Runtime Error: int() requires a valid integer string, but the input could not be fully parsed as a number.
        \\after
        \\no_error
        \\done
        ,
    },
    .{
        .name = "lua_raw",
        .dialect = "lua-like",
        .program =
        \\b: raw_bool = raw bool[100]
        \\b[5] = 1
        \\print(b[5])
        \\print(b[5] == 1)
        \\i: raw_int = raw int[50]
        \\i[10] = 42
        \\print(i[10])
        \\
        ,
        .expected =
        \\1
        \\true
        \\42
        ,
    },
    .{
        .name = "lua_typed_lists",
        .dialect = "lua-like",
        .program =
        \\s: list[int] = [1, 2, 3]
        \\print(s[1])
        \\s[2] = 99
        \\print(s[2])
        \\print(len(s))
        \\x: int = 7
        \\print(x)
        \\f: float = 2.5
        \\print(f * 2.0)
        \\
        ,
        .expected =
        \\2
        \\99
        \\3
        \\7
        \\5.0
        ,
    },
    .{
        .name = "lua_coalesce",
        .dialect = "lua-like",
        .program =
        \\a? = nil
        \\print(a ?? 42)
        \\b = 10
        \\print(b ?? 42)
        \\s = "hi"
        \\print(s ?? "none")
        \\
        ,
        .expected =
        \\42
        \\10
        \\hi
        ,
    },
    .{
        .name = "lua_except_var",
        .dialect = "lua-like",
        .program =
        \\try
        \\    int("notanumber")
        \\end
        \\except e
        \\    print("caught:", e)
        \\end
        \\print("after")
        \\try
        \\    print("no_error")
        \\end
        \\except
        \\    print("should_not_run")
        \\end
        \\print("done")
        \\
        ,
        .expected =
        \\caught: Runtime Error: int() requires a valid integer string, but the input could not be fully parsed as a number.
        \\after
        \\no_error
        \\done
        ,
    },
};

pub fn main() !void {
    var total_passed: usize = 0;
    var total_failed: usize = 0;

    const compiler_bin = if (std.os.argv.len > 1)
        std.mem.sliceTo(std.os.argv[1], 0)
    else
        "zig-out/bin/boblang";

    for (test_cases) |tc| {
        const test_file = "test_dialect_temp.bob";
        std.fs.cwd().deleteFile(test_file) catch {};
        std.fs.cwd().deleteFile("output_dialect") catch {};
        std.fs.cwd().deleteFile("output_dialect.exe") catch {};
        std.fs.cwd().deleteFile("output_dialect.pdb") catch {};
        std.fs.cwd().deleteFile("output_dialect.ll") catch {};

        try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = tc.program });

        var args = std.ArrayList([]const u8).init(std.heap.page_allocator);
        defer args.deinit();
        try args.append(compiler_bin);
        try args.append("run");
        try args.append(test_file);
        try args.append("--dialect");
        try args.append(tc.dialect);

        var child = std.process.Child.init(args.items, std.heap.page_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout = std.ArrayList(u8).init(std.heap.page_allocator);
        defer stdout.deinit();
        var stderr = std.ArrayList(u8).init(std.heap.page_allocator);
        defer stderr.deinit();

        if (child.stdout) |out| try out.reader().readAllArrayList(&stdout, 1024 * 1024);
        if (child.stderr) |err| try err.reader().readAllArrayList(&stderr, 1024 * 1024);

        const term = try child.wait();

        std.fs.cwd().deleteFile(test_file) catch {};
        std.fs.cwd().deleteFile("output_dialect") catch {};
        std.fs.cwd().deleteFile("output_dialect.exe") catch {};
        std.fs.cwd().deleteFile("output_dialect.pdb") catch {};
        std.fs.cwd().deleteFile("output_dialect.ll") catch {};

        if (term == .Exited and term.Exited == 0) {
            const output = std.mem.trim(u8, stdout.items, " \n\r\t");
            const expected = std.mem.trim(u8, tc.expected, " \n\r\t");
            if (std.mem.eql(u8, output, expected)) {
                total_passed += 1;
                std.debug.print("[PASS] [{s}] [{s}]\n", .{ tc.dialect, tc.name });
            } else {
                total_failed += 1;
                std.debug.print("[FAIL] [{s}] [{s}] output mismatch\n", .{ tc.dialect, tc.name });
                std.debug.print("  expected:\n{s}\n", .{expected});
                std.debug.print("  got:\n{s}\n", .{output});
            }
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [{s}] [{s}] exit code {}\n", .{ tc.dialect, tc.name, term });
            if (stderr.items.len > 0) std.debug.print("  stderr: {s}\n", .{stderr.items});
        }
    }

    std.debug.print("\ndialect tests results: {d} passed, {d} failed, 0 skipped\n", .{ total_passed, total_failed });
    if (total_failed > 0) std.process.exit(1);
}
