const std = @import("std");
const parser = @import("parser.zig");
const lua_parser = @import("lua_parser.zig");
const c_like_parser = @import("c_like_parser.zig");
pub const AstNode = parser.AstNode;

pub fn parseToAst(allocator: std.mem.Allocator, source: []const u8, dialect: []const u8) !std.ArrayList(*AstNode) {
    if (std.mem.eql(u8, dialect, "lua") or std.mem.eql(u8, dialect, "lua-like")) {
        return try lua_parser.parseToAst(allocator, source);
    }
    if (std.mem.eql(u8, dialect, "c") or std.mem.eql(u8, dialect, "c-like")) {
        return try c_like_parser.ptoast(allocator, source);
    }
    return try parser.ptoast(allocator, source);
}

pub fn freeAstTree(allocator: std.mem.Allocator, tree: std.ArrayList(*AstNode)) void {
    parser.frtree(allocator, tree);
}
