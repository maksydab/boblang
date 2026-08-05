const std = @import("std");
const parser = @import("stuff/lib/parser.zig");
const Builder = @import("stuff/lib/builder.zig").Builder;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var total_passed: usize = 0;
    var total_failed: usize = 0;

    {
        const source =
            \\z = 42
        ;

        const ast_tree = parser.ptoast(allocator, source) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [basic_emit] parse failed\n", .{});
            return;
        };
        defer parser.frtree(allocator, ast_tree);

        var b = Builder.init(allocator, "test_builder.bob");
        defer b.deinit();

        _ = b.walkAstAndEmit(ast_tree.items[0]) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [basic_emit] walkAstAndEmit failed\n", .{});
            return;
        };
        try b.finalize();

        if (b.llvm.code_buffer.items.len > 0) {
            total_passed += 1;
            std.debug.print("[PASS] [basic_emit]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [basic_emit] no LLVM code generated\n", .{});
        }
    }

    {
        const source =
            \\try:
            \\    print("in_try")
            \\except:
            \\    print("in_except")
        ;

        const ast_tree = parser.ptoast(allocator, source) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [try_emit] parse failed\n", .{});
            return;
        };
        defer parser.frtree(allocator, ast_tree);

        var b = Builder.init(allocator, "test_builder.bob");
        defer b.deinit();

        _ = b.walkAstAndEmit(ast_tree.items[0]) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [try_emit] walkAstAndEmit failed\n", .{});
            return;
        };
        try b.finalize();

        const code = b.llvm.code_buffer.items;
        if (std.mem.containsAtLeast(u8, code, 1, "try_end") and std.mem.containsAtLeast(u8, code, 1, "except")) {
            total_passed += 1;
            std.debug.print("[PASS] [try_emit]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [try_emit] missing try_end/except labels\n", .{});
        }
    }



    {
        const source =
            \\x = 1 + 2 * 3
        ;

        const ast_tree = parser.ptoast(allocator, source) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [expr_emit] parse failed\n", .{});
            return;
        };
        defer parser.frtree(allocator, ast_tree);

        var b = Builder.init(allocator, "test_builder.bob");
        defer b.deinit();

        _ = b.walkAstAndEmit(ast_tree.items[0]) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [expr_emit] walkAstAndEmit failed\n", .{});
            return;
        };
        try b.finalize();

        if (b.llvm.code_buffer.items.len > 0) {
            total_passed += 1;
            std.debug.print("[PASS] [expr_emit]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [expr_emit] no LLVM code generated\n", .{});
        }
    }

    {
        const source =
            \\for i in range(5):
            \\    print(i)
        ;

        const ast_tree = parser.ptoast(allocator, source) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [for_emit] parse failed\n", .{});
            return;
        };
        defer parser.frtree(allocator, ast_tree);

        var b = Builder.init(allocator, "test_builder.bob");
        defer b.deinit();

        _ = b.walkAstAndEmit(ast_tree.items[0]) catch {
            total_failed += 1;
            std.debug.print("[FAIL] [for_emit] walkAstAndEmit failed\n", .{});
            return;
        };
        try b.finalize();

        const code = b.llvm.code_buffer.items;
        if (std.mem.containsAtLeast(u8, code, 1, "icmp slt") and std.mem.containsAtLeast(u8, code, 1, "alloca i64, align 8")) {
            total_passed += 1;
            std.debug.print("[PASS] [for_emit]\n", .{});
        } else {
            total_failed += 1;
            std.debug.print("[FAIL] [for_emit] missing expected IR patterns\n", .{});
        }
    }

    std.debug.print("\nbuilder Results: {d} passed, {d} failed\n", .{ total_passed, total_failed });
    if (total_failed > 0) std.process.exit(1);
}
