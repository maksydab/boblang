const std = @import("std");
const c_parser = @import("c_parser.zig");

pub const PackageFunction = struct {
    name: []const u8,
    params: []const Param,
    return_type: []const u8,
    description: ?[]const u8 = null,
};

pub const Param = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const ExportInfo = struct {
    source: []const u8,
    alias: []const u8,
    module: []const u8,
    name: []const u8,
};

pub fn parseLibBobExports(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(ExportInfo) {
    var exports = std.ArrayList(ExportInfo).init(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "export ")) continue;

        const body = std.mem.trim(u8, line["export ".len..], " ");

        var alias: []const u8 = undefined;
        var source_expr: []const u8 = undefined;

        if (std.mem.indexOf(u8, body, " as ")) |as_idx| {
            source_expr = std.mem.trim(u8, body[0..as_idx], " ");
            alias = std.mem.trim(u8, body[as_idx + 4 ..], " ");
        } else {
            source_expr = body;
            alias = body;
        }

        var module: []const u8 = "";
        var name: []const u8 = source_expr;
        if (std.mem.lastIndexOfScalar(u8, source_expr, '.')) |dot_idx| {
            module = source_expr[0..dot_idx];
            name = source_expr[dot_idx + 1 ..];
        }

        try exports.append(.{
            .source = try allocator.dupe(u8, source_expr),
            .alias = try allocator.dupe(u8, alias),
            .module = try allocator.dupe(u8, module),
            .name = try allocator.dupe(u8, name),
        });
    }
    return exports;
}

pub fn deinitExportInfo(allocator: std.mem.Allocator, exports: *std.ArrayList(ExportInfo)) void {
    for (exports.items) |e| {
        allocator.free(e.source);
        allocator.free(e.alias);
        allocator.free(e.module);
        allocator.free(e.name);
    }
    exports.deinit();
}

pub fn parseLibBob(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(PackageFunction) {
    var fns = std.ArrayList(PackageFunction).init(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, ";")) continue;

        const is_extern = std.mem.startsWith(u8, line, "extern func ");
        if (!is_extern and !std.mem.startsWith(u8, line, "func ")) continue;

        const prefix_len: usize = if (is_extern) "extern func ".len else "func ".len;
        var rest = line[prefix_len..];

        const paren_idx = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const fn_name = std.mem.trim(u8, rest[0..paren_idx], " \t");
        if (fn_name.len == 0) continue;

        const close_paren_idx = std.mem.lastIndexOfScalar(u8, rest, ')') orelse continue;
        const params_str = std.mem.trim(u8, rest[paren_idx + 1 .. close_paren_idx], " \t");

        var params = std.ArrayList(Param).init(allocator);
        if (params_str.len > 0) {
            var param_parts = std.mem.splitScalar(u8, params_str, ',');
            while (param_parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len == 0) continue;
                const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const pname = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
                const ptype = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
                try params.append(.{
                    .name = try allocator.dupe(u8, pname),
                    .type_name = try allocator.dupe(u8, ptype),
                });
            }
        }

        var return_type: []const u8 = "void";
        const arrow_idx = std.mem.indexOf(u8, rest[close_paren_idx + 1 ..], "->");
        if (arrow_idx) |ai| {
            const after_arrow = std.mem.trim(u8, rest[close_paren_idx + 1 + ai + 2 ..], " \t");
            if (after_arrow.len > 0) {
                var tok_end: usize = 0;
                while (tok_end < after_arrow.len and after_arrow[tok_end] != ' ' and after_arrow[tok_end] != '\t' and after_arrow[tok_end] != '{' and after_arrow[tok_end] != ':') {
                    tok_end += 1;
                }
                return_type = after_arrow[0..tok_end];
            }
        }

        try fns.append(.{
            .name = try allocator.dupe(u8, fn_name),
            .params = try params.toOwnedSlice(),
            .return_type = try allocator.dupe(u8, return_type),
        });
    }
    return fns;
}

pub fn cTypeStringToEnum(type_str: []const u8) c_parser.CType {
    if (std.mem.eql(u8, type_str, "void")) return .void;
    if (std.mem.eql(u8, type_str, "int")) return .int;
    if (std.mem.eql(u8, type_str, "i32")) return .int;
    if (std.mem.eql(u8, type_str, "long")) return .long;
    if (std.mem.eql(u8, type_str, "long_long")) return .long_long;
    if (std.mem.eql(u8, type_str, "i64")) return .long;
    if (std.mem.eql(u8, type_str, "float")) return .float;
    if (std.mem.eql(u8, type_str, "double")) return .double;
    if (std.mem.eql(u8, type_str, "char")) return .char;
    if (std.mem.eql(u8, type_str, "i8")) return .char;
    if (std.mem.eql(u8, type_str, "short")) return .short;
    if (std.mem.eql(u8, type_str, "i16")) return .short;
    if (std.mem.eql(u8, type_str, "boblang_ptr")) return .boblang_ptr;
    if (std.mem.eql(u8, type_str, "ptr")) return .boblang_ptr;
    return .unknown;
}

pub fn cTypeStringToLlvm(type_str: []const u8) []const u8 {
    if (std.mem.eql(u8, type_str, "void")) return "void";
    if (std.mem.eql(u8, type_str, "int") or std.mem.eql(u8, type_str, "i32")) return "i32";
    if (std.mem.eql(u8, type_str, "long") or std.mem.eql(u8, type_str, "long_long") or std.mem.eql(u8, type_str, "i64")) return "i64";
    if (std.mem.eql(u8, type_str, "float")) return "float";
    if (std.mem.eql(u8, type_str, "double")) return "double";
    if (std.mem.eql(u8, type_str, "char") or std.mem.eql(u8, type_str, "i8")) return "i8";
    if (std.mem.eql(u8, type_str, "short") or std.mem.eql(u8, type_str, "i16")) return "i16";
    return "ptr";
}

pub fn generateLlvmIr(allocator: std.mem.Allocator, pkg_name: []const u8, functions: []const PackageFunction, exports: []const ExportInfo) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("; LLVM IR for boblang package '{s}'\n", .{pkg_name});
    try w.print("; Generated types for foreign function signatures\n\n", .{});

    for (functions) |f| {
        if (std.mem.eql(u8, f.name, "main")) continue;
        const ret_type = cTypeStringToLlvm(f.return_type);
        try w.print("declare {s} @{s}(", .{ ret_type, f.name });
        for (f.params, 0..) |p, pidx| {
            if (pidx > 0) try w.writeAll(", ");
            try w.print("{s}", .{cTypeStringToLlvm(p.type_name)});
        }
        try w.writeAll(")\n");
    }

    for (exports) |e| {
        if (std.mem.startsWith(u8, e.module, "gfx")) {
            const ret_type: []const u8 = "void";
            try w.print("declare {s} @{s}(...)\n", .{ ret_type, e.name });
        }
    }

    return buf.toOwnedSlice();
}

pub fn generateLibBob(allocator: std.mem.Allocator, pkg_name: []const u8, functions: []const PackageFunction) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("; Auto-generated by boblang pack for package '{s}'\n", .{pkg_name});
    try w.print("; This file declares the C bridge functions for this package.\n", .{});
    try w.print("; Users import this package and call these functions via the module alias.\n\n", .{});

    for (functions) |f| {
        if (std.mem.eql(u8, f.name, "main")) continue;
        const ret_type = f.return_type;
        const is_void = std.mem.eql(u8, ret_type, "void");
        try w.print("pub fn {s}(", .{f.name});
        for (f.params, 0..) |p, pidx| {
            if (pidx > 0) try w.writeAll(", ");
            try w.print("{s}: {s}", .{ p.name, p.type_name });
        }
        try w.writeAll(")");
        if (!is_void) {
            try w.print(" -> {s}", .{ret_type});
        }
        try w.writeAll("\n");
    }

    return buf.toOwnedSlice();
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    for (input) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:04}", .{c}),
            else => try w.writeByte(c),
        }
    }
    return buf.toOwnedSlice();
}

pub fn generatePackageJson(allocator: std.mem.Allocator, pkg_name: []const u8, version: []const u8, functions: []const PackageFunction, exports: []const ExportInfo) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\n");
    try w.print("  \"name\": \"{s}\",\n", .{pkg_name});
    try w.print("  \"version\": \"{s}\",\n", .{version});
    try w.writeAll("  \"exports\": [\n");

    for (exports, 0..) |e, ei| {
        if (ei > 0) try w.writeAll(",\n");
        try w.print("    {{\"from\": \"{s}\", \"as\": \"{s}\"}}", .{ e.source, e.alias });
    }

    try w.writeAll("\n  ],\n");
    try w.writeAll("  \"functions\": [\n");

    var func_count: usize = 0;

    for (functions) |f| {
        if (func_count > 0) try w.writeAll(",\n");
        func_count += 1;
        try w.writeAll("    {\n");
        try w.print("      \"name\": \"{s}\",\n", .{f.name});
        try w.writeAll("      \"params\": [\n");
        for (f.params, 0..) |p, pi| {
            if (pi > 0) try w.writeAll(",\n");
            try w.print("        {{\"name\": \"{s}\", \"type\": \"{s}\"}}", .{ p.name, p.type_name });
        }
        try w.writeAll("\n      ],\n");
        try w.print("      \"return_type\": \"{s}\"", .{f.return_type});
        if (f.description) |desc| {
            try w.writeAll(",\n");
            const escaped = try escapeJsonString(allocator, desc);
            defer allocator.free(escaped);
            try w.print("      \"desc\": \"{s}\"", .{escaped});
        }
        try w.writeAll("\n    }");
    }

    try w.writeAll("\n  ]\n");
    try w.writeAll("}\n");

    return buf.toOwnedSlice();
}
