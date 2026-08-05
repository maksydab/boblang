const std = @import("std");
const progress = @import("progress.zig");

threadlocal var current_file: []const u8 = "";
threadlocal var current_source: []const u8 = "";

pub fn setCurrentFile(file: []const u8) void {
    current_file = file;
}

pub fn getCurrentFile() []const u8 {
    return current_file;
}

pub fn setCurrentSource(source: []const u8) void {
    current_source = source;
}

pub const ErrorCode = enum(u32) {
    none = 0,
    variable_not_found = 1,
    function_not_found = 2,
    method_not_found = 3,
    type_assertion_failed = 4,
    index_out_of_bounds = 5,
    type_mismatch = 6,
    syntax_error = 7,
};

pub fn getErrorMessage(code: u32) []const u8 {
    const err = @as(ErrorCode, @enumFromInt(code));
    return switch (err) {
        .none => "Success",
        .variable_not_found => "Runtime Error: Attempted to reference a non-existent variable.",
        .function_not_found => "Runtime Error: Attempted to call a non-existent global function.",
        .method_not_found => "Runtime Error: Attempted to call a non-existent method context on an object.",
        .type_assertion_failed => "Runtime Error: Type assertion failed.",
        .index_out_of_bounds => "Runtime Error: Index out of bounds.",
        .type_mismatch => "Compile Error: Type mismatch.",
        .syntax_error => "Syntax Error: Invalid syntax.",
    };
}

fn red_start() void { std.debug.print("\x1b[1;31m", .{}); }
fn red_end() void { std.debug.print("\x1b[0m", .{}); }

fn printSourceContext(source: []const u8, line: usize, column: usize, end_column: usize) void {
    const start_line = if (line >= 3) line - 2 else 1;
    const end_line = line + 2;
    var line_iter = std.mem.splitSequence(u8, source, "\n");
    var current: usize = 1;
    while (line_iter.next()) |src_line| {
        if (current >= start_line and current <= end_line) {
            const clean = std.mem.trimRight(u8, src_line, " \r\n\t");
            if (current == line and column > 0 and column <= clean.len) {
                red_start();
                std.debug.print("{d:>4} | {s}\n", .{ current, clean });
                red_end();
                std.debug.print("     | ", .{});
                var col: usize = 0;
                while (col < column - 1 and col < clean.len) : (col += 1) {
                    if (clean[col] == '\t') {
                        std.debug.print("\t", .{});
                    } else {
                        std.debug.print(" ", .{});
                    }
                }
                const end = if (end_column > column and end_column <= clean.len) end_column else clean.len;
                var u: usize = column - 1;
                while (u < end) : (u += 1) {
                    std.debug.print("\x1b[1;31m~\x1b[0m", .{});
                }
                std.debug.print("\n", .{});
            } else {
                std.debug.print("{d:>4} | {s}\n", .{ current, clean });
            }
        }
        if (current > end_line) break;
        current += 1;
    }
}

var last_error_line: usize = 0;

pub fn printSyntaxError(source: []const u8, line: usize, column: usize, msg: []const u8) void {
    if (last_error_line == line) return;
    last_error_line = line;
    progress.clear();
    red_start();
    std.debug.print("error", .{});
    red_end();
    std.debug.print(": {s} at {s}:{d}\n", .{ msg, current_file, line });
    const src = if (source.len > 0) source else current_source;
    if (src.len > 0 and column > 0) printSourceContext(src, line, column, column + 1);
}

pub fn printExpectedError(source: []const u8, line: usize, expected: []const u8, got: []const u8) void {
    if (last_error_line == line) return;
    last_error_line = line;
    progress.clear();
    red_start();
    std.debug.print("error", .{});
    red_end();
    std.debug.print(": Expected '{s}' but got '{s}' at {s}:{d}\n", .{ expected, got, current_file, line });
    const src = if (source.len > 0) source else current_source;
    if (src.len > 0) printSourceContext(src, line, 1, 0);
}

pub fn printSemanticError(line: usize, msg: []const u8) void {
    if (last_error_line == line) return;
    last_error_line = line;
    progress.clear();
    red_start();
    std.debug.print("error", .{});
    red_end();
    std.debug.print(": {s} at {s}:{d}\n", .{ msg, current_file, line });
    if (current_source.len > 0) printSourceContext(current_source, line, 1, 0);
}

pub fn printSemanticNote(line: usize, msg: []const u8) void {
    red_start();
    std.debug.print("  -> {s}", .{msg});
    red_end();
    std.debug.print(" at {s}:{d}\n", .{ current_file, line });
    if (current_source.len > 0) printSourceContext(current_source, line, 1, 0);
}

pub fn printCompileError(source: []const u8, err_name: []const u8) void {
    _ = source;
    if (last_error_line > 0) return;
    last_error_line = std.math.maxInt(usize);
    progress.clear();
    red_start();
    std.debug.print("error", .{});
    red_end();
    std.debug.print(": {s}\n", .{err_name});
}
