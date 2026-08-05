const std = @import("std");
const parser = @import("stuff/lib/parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var total_passed: usize = 0;
    var total_failed: usize = 0;


    {
        const source =
            \\x = 42
            \\print("hello")
        ;
        const tree = try parser.ptoast(allocator, source);
        defer parser.frtree(allocator, tree);

        if (tree.items.len == 2 and tree.items[0].node_type == .assign and tree.items[1].node_type == .call) {
            total_passed += 1;
            std.debug.print("[PASS] [basic_parse]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [basic_parse] expcted 2 nodes (assign, call)\n", .{});
        }
    }

    {
        const source =
            \\func my_func(int a, float b):
            \\    return a + b
        ;
        const tree = try parser.ptoast(allocator, source);
        defer parser.frtree(allocator, tree);

        if (tree.items.len == 1 and tree.items[0].node_type == .func_def) {
            const func = tree.items[0];
            if (func.args) |args| {
                if (args.items.len == 2 and
                    std.mem.eql(u8, args.items[0].name, "a") and
                    std.mem.eql(u8, args.items[1].name, "b") and
                    std.mem.eql(u8, args.items[0].extra.?, "int") and
                    std.mem.eql(u8, args.items[1].extra.?, "float"))
                {
                    total_passed += 1;
                    std.debug.print("[PASS] [typed_params]\n", .{});
                } else {
                    total_failed += 1;
                    std.debug.print("[FAIL] [typed_params] wrong param names/types\n", .{});
                }
            } else {
                total_failed += 1;
                std.debug.print("[FAIL] [typed_params] no args\n", .{});
            }
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [typed_params] wrong tree\n", .{});
        }
    }

    {
        const source =
            \\import math.c as math
        ;
        const tree = try parser.ptoast(allocator, source);
        defer parser.frtree(allocator, tree);

        if (tree.items.len == 1 and tree.items[0].node_type == .import_stmt and
            std.mem.eql(u8, tree.items[0].name, "math") and
            std.mem.eql(u8, tree.items[0].extra.?, "math.c"))
        {
            total_passed += 1;
            std.debug.print("[PASS] [import_stmt]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [import_stmt]\n", .{});
        }
    }

    {
        const source =
            \\try:
            \\    print("a")
            \\except:
            \\    print("b")
        ;
        const tree = try parser.ptoast(allocator, source);
        defer parser.frtree(allocator, tree);

        if (tree.items.len == 1 and tree.items[0].node_type == .try_stmt) {
            const ts = tree.items[0];
            if (ts.subtree != null and ts.subtree.?.items.len == 1 and ts.except_tree != null and ts.except_tree.?.items.len == 1) {
                total_passed += 1;
                std.debug.print("[PASS] [try_except]\n", .{});
            } else {
                total_failed += 1;
                std.debug.print("[FAIL] [try_except] wrong subtree/except_tree\n", .{});
            }
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [try_except] expected try_stmt\n", .{});
        }
    }

    {
        const source =
            \\x = [1, 2, 3]
        ;
        const tree = try parser.ptoast(allocator, source);
        defer parser.frtree(allocator, tree);

        if (tree.items.len == 1 and tree.items[0].node_type == .assign) {
            const rhs = tree.items[0].args.?.items[0];
            if (rhs.node_type == .val_list and rhs.args.?.items.len == 3) {
                total_passed += 1;
                std.debug.print("[PASS] [list_literal]\n", .{});
            } else {
                total_failed += 1;
                std.debug.print("[FAIL] [list_literal]\n", .{});
            }
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [list_literal] expected assign\n", .{});
        }
    }

    {
        const source = "";
        const tree = try parser.ptoast(allocator, source);
        defer parser.frtree(allocator, tree);

        if (tree.items.len == 0) {
            total_passed += 1;
            std.debug.print("[PASS] [empty_source]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [empty_source]\n", .{});
        }
    }

    std.debug.print("\nParsr Results: {d} passed, {d} failed\n", .{ total_passed, total_failed });
    if (total_failed > 0) std.process.exit(1);
}
