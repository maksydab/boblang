const std = @import("std");
const AstNode = @import("parser.zig").AstNode;

const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    source: []const u8,
};

pub fn optimize(ast: *std.ArrayList(*AstNode), allocator: std.mem.Allocator) void {
    var tracking = std.StringHashMap(Value).init(allocator);
    defer tracking.deinit();
    for (ast.items) |node| {
        optimizeStmt(node, &tracking, allocator);
    }
}

fn resolveName(name: []const u8, tracking: std.StringHashMap(Value)) []const u8 {
    var current = name;
    var max_depth: u32 = 100;
    while (max_depth > 0) {
        max_depth -= 1;
        if (tracking.get(current)) |val| {
            switch (val) {
                .source => |src| {
                    if (std.mem.eql(u8, src, current)) break;
                    current = src;
                },
                else => break,
            }
        } else break;
    }
    return current;
}

fn optimizeStmt(node: *AstNode, tracking: *std.StringHashMap(Value), allocator: std.mem.Allocator) void {
    switch (node.node_type) {
        .assign => {
            const rhs = node.args.?.items[0];
            optimizeExpr(rhs, tracking);

            if (node.target != null or std.mem.containsAtLeast(u8, node.name, 1, ".") or std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                _ = tracking.remove(node.name);
                return;
            }

            if (node.extra != null) {
                const annot = node.extra.?;
                if (std.mem.eql(u8, annot, "bigf") or std.mem.eql(u8, annot, "bigi")) {
                    return;
                }
            }

            const val = switch (rhs.node_type) {
                .val_int => Value{ .int = rhs.val_int },
                .val_float => Value{ .float = rhs.val_float },
                .val_bool => Value{ .boolean = rhs.val_int != 0 },
                .val_nil => {
                    _ = tracking.remove(node.name);
                    return;
                },
                .val_string => Value{ .string = rhs.val_string },
                .var_ref => {
                    if (std.mem.containsAtLeast(u8, rhs.name, 1, ".") or std.mem.containsAtLeast(u8, rhs.name, 1, "[")) {
                        _ = tracking.remove(node.name);
                        return;
                    }
                    const resolved = resolveName(rhs.name, tracking.*);
                    if (tracking.get(resolved)) |v| {
                        if (std.mem.eql(u8, resolved, node.name)) {
                            _ = tracking.remove(node.name);
                            return;
                        }
                        switch (v) {
                            .int => |n| {
                                rhs.node_type = .val_int;
                                rhs.val_int = n;
                                _ = tracking.remove(node.name);
                                const val = Value{ .int = n };
                                tracking.put(node.name, val) catch {};
                            },
                            .float => |f| {
                                rhs.node_type = .val_float;
                                rhs.val_float = f;
                                _ = tracking.remove(node.name);
                                const val = Value{ .float = f };
                                tracking.put(node.name, val) catch {};
                            },
                            .boolean => |b| {
                                rhs.node_type = .val_bool;
                                rhs.val_int = if (b) 1 else 0;
                                _ = tracking.remove(node.name);
                                const val = Value{ .boolean = b };
                                tracking.put(node.name, val) catch {};
                            },
                            .string => |s| {
                                rhs.node_type = .val_string;
                                rhs.val_string = s;
                                _ = tracking.remove(node.name);
                                const val = Value{ .string = s };
                                tracking.put(node.name, val) catch {};
                            },
                            .source => unreachable,
                        }
                    } else {
                        _ = tracking.remove(node.name);
                    }
                    return;
                },
                else => {
                    _ = tracking.remove(node.name);
                    return;
                },
            };

            tracking.put(node.name, val) catch {};
        },
        .aug_assign_add, .aug_assign_mul => {
            if (node.args) |args| optimizeExpr(args.items[0], tracking);
            _ = tracking.remove(node.name);
        },
        .func_def, .class_def => {
            if (node.args) |args| {
                if (args.items.len > 0) {
                    for (args.items) |arg| optimizeExpr(arg, tracking);
                }
            }
            if (node.subtree) |body| {
                var func_tracking = std.StringHashMap(Value).init(allocator);
                defer func_tracking.deinit();
                for (body.items) |stmt| {
                    optimizeStmt(stmt, &func_tracking, allocator);
                }
            }
        },
        .if_stmt => {
            if (node.args) |args| optimizeExpr(args.items[0], tracking);
            tracking.clearRetainingCapacity();
            if (node.subtree) |body| {
                var if_tracking = std.StringHashMap(Value).init(allocator);
                defer if_tracking.deinit();
                for (body.items) |stmt| {
                    optimizeStmt(stmt, &if_tracking, allocator);
                }
            }
            if (node.elifs) |elifs| {
                for (elifs.items) |elif_node| {
                    if (elif_node.args) |args| optimizeExpr(args.items[0], tracking);
                    if (elif_node.subtree) |body| {
                        var elif_tracking = std.StringHashMap(Value).init(allocator);
                        defer elif_tracking.deinit();
                        for (body.items) |stmt| {
                            optimizeStmt(stmt, &elif_tracking, allocator);
                        }
                    }
                }
            }
            if (node.else_tree) |body| {
                var else_tracking = std.StringHashMap(Value).init(allocator);
                defer else_tracking.deinit();
                for (body.items) |stmt| {
                    optimizeStmt(stmt, &else_tracking, allocator);
                }
            }
        },
        .while_loop, .for_loop => {
            if (node.args) |args| {
                var loop_cond_tracking = std.StringHashMap(Value).init(allocator);
                defer loop_cond_tracking.deinit();
                for (args.items) |arg| optimizeExpr(arg, &loop_cond_tracking);
            }
            tracking.clearRetainingCapacity();
            if (node.subtree) |body| {
                var loop_tracking = std.StringHashMap(Value).init(allocator);
                defer loop_tracking.deinit();
                for (body.items) |stmt| {
                    optimizeStmt(stmt, &loop_tracking, allocator);
                }
            }
        },
        .try_stmt => {
            tracking.clearRetainingCapacity();
            if (node.subtree) |body| {
                for (body.items) |stmt| optimizeStmt(stmt, tracking, allocator);
            }
            if (node.except_tree) |body| {
                for (body.items) |stmt| optimizeStmt(stmt, tracking, allocator);
            }
        },
        .return_stmt => {
            if (node.args) |args| optimizeExpr(args.items[0], tracking);
        },
        .break_stmt => {},
        .pass_stmt => {},
        .import_stmt => {
            tracking.clearRetainingCapacity();
        },
        .call => {
            if (node.args) |args| {
                for (args.items) |arg| optimizeExpr(arg, tracking);
            }
            tracking.clearRetainingCapacity();
        },
        else => {
            tracking.clearRetainingCapacity();
        },
    }
}

fn optimizeExpr(node: *AstNode, tracking: *std.StringHashMap(Value)) void {
    switch (node.node_type) {
        .var_ref => {
            if (node.target != null or std.mem.containsAtLeast(u8, node.name, 1, ".") or std.mem.containsAtLeast(u8, node.name, 1, "[")) return;
            const resolved = resolveName(node.name, tracking.*);
            if (tracking.get(resolved)) |val| {
                switch (val) {
                    .int => |n| {
                        node.node_type = .val_int;
                        node.val_int = n;
                    },
                    .float => |f| {
                        node.node_type = .val_float;
                        node.val_float = f;
                    },
                    .boolean => |b| {
                        node.node_type = .val_bool;
                        node.val_int = if (b) 1 else 0;
                    },
                    .string => |s| {
                        node.node_type = .val_string;
                        node.val_string = s;
                    },
                    .source => unreachable,
                }
            } else if (!std.mem.eql(u8, resolved, node.name)) {
                node.name = resolved;
            }
        },
        .add, .sub, .mul, .div, .mod, .int_div, .pow => {
            const lhs = node.args.?.items[0];
            const rhs = node.args.?.items[1];
            optimizeExpr(lhs, tracking);
            optimizeExpr(rhs, tracking);
            if (lhs.node_type == .val_int and rhs.node_type == .val_int) {
                const a = lhs.val_int;
                const b = rhs.val_int;
                const result: i64 = switch (node.node_type) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => @divTrunc(a, b),
                    .mod => @mod(a, b),
                    .int_div => if (b != 0) @divTrunc(a, b) else 0,
                    .pow => blk: {
                        var p: i64 = 1;
                        var i: u64 = 0;
                        while (i < @as(u64, @intCast(b))) {
                            p = @mulWithOverflow(p, a)[0];
                            i += 1;
                        }
                        break :blk p;
                    },
                    else => unreachable,
                };
                node.node_type = .val_int;
                node.val_int = result;
            }
        },
        .eq, .ne, .lt, .gt, .le, .ge => {
            const lhs = node.args.?.items[0];
            const rhs = node.args.?.items[1];
            optimizeExpr(lhs, tracking);
            optimizeExpr(rhs, tracking);
            if (lhs.node_type == .val_int and rhs.node_type == .val_int) {
                const result = switch (node.node_type) {
                    .eq => lhs.val_int == rhs.val_int,
                    .ne => lhs.val_int != rhs.val_int,
                    .lt => lhs.val_int < rhs.val_int,
                    .gt => lhs.val_int > rhs.val_int,
                    .le => lhs.val_int <= rhs.val_int,
                    .ge => lhs.val_int >= rhs.val_int,
                    else => unreachable,
                };
                node.node_type = .val_bool;
                node.val_int = if (result) 1 else 0;
            }
        },
        .call => {
            if (node.args) |args| {
                for (args.items) |arg| optimizeExpr(arg, tracking);
            }
        },
        .val_list => {
            if (node.args) |items| {
                for (items.items) |item| optimizeExpr(item, tracking);
            }
        },
        .val_dict => {
            if (node.args) |items| {
                for (items.items) |item| optimizeExpr(item, tracking);
            }
        },

        .and_op, .or_op => {
            const lhs = node.args.?.items[0];
            const rhs = node.args.?.items[1];
            optimizeExpr(lhs, tracking);
            optimizeExpr(rhs, tracking);
        },
        else => {},
    }
}
