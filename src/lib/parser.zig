const std = @import("std");
const errors = @import("errors.zig");

pub const AstNodeType = enum {
    comment,
    val_int,
    val_float,
    val_string,
    val_nil,
    val_list,
    val_dict,
    val_bool,
    var_ref,
    assign,
    prop_access,
    aug_assign_add,
    aug_assign_mul,
    func_def,
    class_def,
    return_stmt,
    call,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    int_div,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    in_op,
    coalesce,
    if_stmt,
    elif_stmt,
    else_stmt,
    and_op,
    or_op,
    while_loop,
    for_loop,
    break_stmt,
    pass_stmt,
    block_wrapper,
    import_stmt,
    export_stmt,
    try_stmt,
    except_stmt,
};

pub const AstNode = struct {
    node_type: AstNodeType,
    line: usize = 0,
    name: []const u8 = "",
    val_string: []const u8 = "",
    val_int: i64 = 0,
    val_float: f64 = 0.0,
    args: ?std.ArrayList(*AstNode) = null,
    subtree: ?std.ArrayList(*AstNode) = null,
    elifs: ?std.ArrayList(*AstNode) = null,
    else_tree: ?std.ArrayList(*AstNode) = null,
    except_tree: ?std.ArrayList(*AstNode) = null,
    extra: ?[]const u8 = null,
    is_private: bool = false,
    is_extern: bool = false,
    target: ?*AstNode = null,
    decorators: ?std.ArrayList(*AstNode) = null,
    doc_string: ?[]const u8 = null,
    is_optional: bool = false,
};

pub fn freeAstNode(allocator: std.mem.Allocator, node: *AstNode) void {
    if (node.name.len > 0) allocator.free(node.name);
    if (node.val_string.len > 0) allocator.free(node.val_string);
    if (node.extra) |ex| allocator.free(ex);
    if (node.doc_string) |ds| allocator.free(ds);
    if (node.target) |t| freeAstNode(allocator, t);

    if (node.args) |args| {
        for (args.items) |arg| freeAstNode(allocator, arg);
        args.deinit();
    }
    if (node.subtree) |sub| {
        for (sub.items) |child| freeAstNode(allocator, child);
        sub.deinit();
    }
    if (node.elifs) |elifs| {
        for (elifs.items) |elif_node| freeAstNode(allocator, elif_node);
        elifs.deinit();
    }
    if (node.else_tree) |else_tree| {
        for (else_tree.items) |else_node| freeAstNode(allocator, else_node);
        else_tree.deinit();
    }
    if (node.except_tree) |except_tree| {
        for (except_tree.items) |except_node| freeAstNode(allocator, except_node);
        except_tree.deinit();
    }
    if (node.decorators) |decorators| {
        for (decorators.items) |d| freeAstNode(allocator, d);
        decorators.deinit();
    }
    allocator.destroy(node);
}

pub fn frtree(allocator: std.mem.Allocator, tree: std.ArrayList(*AstNode)) void {
    for (tree.items) |node| {
        freeAstNode(allocator, node);
    }
    tree.deinit();
}

const TokenType = enum {
    eof,
    identifier,
    number_int,
    number_float,
    string,
    plus,
    minus,
    star,
    star_star,
    slash,
    slash_slash,
    percent,
    caret,
    eq,
    eq_eq,
    plus_eq,
    star_eq,
    lt,
    gt,
    le,
    ge,
    ne,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    colon,
    period,
    question,
    question_period,
    coalesce,
    kw_func,
    kw_class,
    kw_return,
    kw_for,
    kw_in,
    kw_while,
    kw_if,
    kw_elif,
    kw_else,
    kw_break,
    kw_pass,
    kw_true,
    kw_false,
    kw_import,
    kw_try,
    kw_except,
    kw_as,
    kw_private,
    kw_and,
    kw_or,
    kw_export,
    kw_nil,
    kw_enum,
};

const Token = struct {
    tok_type: TokenType,
    text: []const u8,
};

const Tokenizer = struct {
    buffer: []const u8,
    source: []const u8,
    index: usize,
    line: usize,
    column: usize,
    paren_depth: usize,
    bracket_depth: usize,
    brace_depth: usize,

    fn init(source: []const u8, buffer: []const u8, line: usize) Tokenizer {
        return .{ .buffer = buffer, .source = source, .index = 0, .line = line, .column = 1, .paren_depth = 0, .bracket_depth = 0, .brace_depth = 0 };
    }

    fn syntaxError(self: *Tokenizer, msg: []const u8) void {
        errors.printSyntaxError(self.source, self.line, self.column, msg);
    }

    fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();
        if (self.index >= self.buffer.len) {
            if (self.paren_depth > 0) {
                self.syntaxError("Unclosed parenthesis '('");
                self.paren_depth = 0;
            }
            if (self.bracket_depth > 0) {
                self.syntaxError("Unclosed bracket '['");
                self.bracket_depth = 0;
            }
            if (self.brace_depth > 0) {
                self.syntaxError("Unclosed brace '{'");
                self.brace_depth = 0;
            }
            return .{ .tok_type = .eof, .text = "" };
        }

        const start = self.index;
        const c = self.buffer[self.index];

        if (c == '"' or c == '\'') {
            const quote = c;
            self.index += 1;
            self.column += 1;
            var found_close = false;
            while (self.index < self.buffer.len) {
                if (self.buffer[self.index] == '\\' and self.index + 1 < self.buffer.len) {
                    self.index += 2;
                    self.column += 2;
                } else if (self.buffer[self.index] == quote) {
                    self.index += 1;
                    self.column += 1;
                    found_close = true;
                    break;
                } else {
                    self.index += 1;
                    self.column += 1;
                }
            }
            if (!found_close) {
                self.syntaxError("Unclosed string literal");
            }
            return .{ .tok_type = .string, .text = self.buffer[start..self.index] };
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            self.index += 1;
            self.column += 1;
            while (self.index < self.buffer.len and (std.ascii.isAlphanumeric(self.buffer[self.index]) or self.buffer[self.index] == '_')) {
                self.index += 1;
                self.column += 1;
            }
            const text = self.buffer[start..self.index];
            if (std.mem.eql(u8, text, "func")) return .{ .tok_type = .kw_func, .text = text };
            if (std.mem.eql(u8, text, "class")) return .{ .tok_type = .kw_class, .text = text };
            if (std.mem.eql(u8, text, "return")) return .{ .tok_type = .kw_return, .text = text };
            if (std.mem.eql(u8, text, "for")) return .{ .tok_type = .kw_for, .text = text };
            if (std.mem.eql(u8, text, "in")) return .{ .tok_type = .kw_in, .text = text };
            if (std.mem.eql(u8, text, "while")) return .{ .tok_type = .kw_while, .text = text };
            if (std.mem.eql(u8, text, "if")) return .{ .tok_type = .kw_if, .text = text };
            if (std.mem.eql(u8, text, "elif")) return .{ .tok_type = .kw_elif, .text = text };
            if (std.mem.eql(u8, text, "else")) return .{ .tok_type = .kw_else, .text = text };
            if (std.mem.eql(u8, text, "break")) return .{ .tok_type = .kw_break, .text = text };
            if (std.mem.eql(u8, text, "pass")) return .{ .tok_type = .kw_pass, .text = text };
            if (std.mem.eql(u8, text, "True") or std.mem.eql(u8, text, "true")) return .{ .tok_type = .kw_true, .text = text };
            if (std.mem.eql(u8, text, "False") or std.mem.eql(u8, text, "false")) return .{ .tok_type = .kw_false, .text = text };
            if (std.mem.eql(u8, text, "import")) return .{ .tok_type = .kw_import, .text = text };
            if (std.mem.eql(u8, text, "try")) return .{ .tok_type = .kw_try, .text = text };
            if (std.mem.eql(u8, text, "except")) return .{ .tok_type = .kw_except, .text = text };
            if (std.mem.eql(u8, text, "as")) return .{ .tok_type = .kw_as, .text = text };
            if (std.mem.eql(u8, text, "private")) return .{ .tok_type = .kw_private, .text = text };
            if (std.mem.eql(u8, text, "and")) return .{ .tok_type = .kw_and, .text = text };
            if (std.mem.eql(u8, text, "or")) return .{ .tok_type = .kw_or, .text = text };
            if (std.mem.eql(u8, text, "export")) return .{ .tok_type = .kw_export, .text = text };
            if (std.mem.eql(u8, text, "nil") or std.mem.eql(u8, text, "null")) return .{ .tok_type = .kw_nil, .text = text };
            if (std.mem.eql(u8, text, "enum")) return .{ .tok_type = .kw_enum, .text = text };
            return .{ .tok_type = .identifier, .text = text };
        }

        if (std.ascii.isDigit(c)) {
            var is_float = false;
            self.index += 1;
            self.column += 1;
            while (self.index < self.buffer.len) {
                const tc = self.buffer[self.index];
                if (tc == '.') {
                    is_float = true;
                    self.index += 1;
                    self.column += 1;
                } else if (std.ascii.isDigit(tc)) {
                    self.index += 1;
                    self.column += 1;
                } else {
                    break;
                }
            }
            return .{ .tok_type = if (is_float) .number_float else .number_int, .text = self.buffer[start..self.index] };
        }

        self.index += 1;
        self.column += 1;
        switch (c) {
            '(' => {
                self.paren_depth += 1;
                return .{ .tok_type = .lparen, .text = self.buffer[start..self.index] };
            },
            ')' => {
                if (self.paren_depth == 0) {
                    self.syntaxError("Unexpected closing parenthesis ')'");
                } else {
                    self.paren_depth -= 1;
                }
                return .{ .tok_type = .rparen, .text = self.buffer[start..self.index] };
            },
            '{' => {
                self.brace_depth += 1;
                return .{ .tok_type = .lbrace, .text = self.buffer[start..self.index] };
            },
            '}' => {
                if (self.brace_depth == 0) {
                    self.syntaxError("Unexpected closing brace '}'");
                } else {
                    self.brace_depth -= 1;
                }
                return .{ .tok_type = .rbrace, .text = self.buffer[start..self.index] };
            },
            '[' => {
                self.bracket_depth += 1;
                return .{ .tok_type = .lbracket, .text = self.buffer[start..self.index] };
            },
            ']' => {
                if (self.bracket_depth == 0) {
                    self.syntaxError("Unexpected closing bracket ']'");
                } else {
                    self.bracket_depth -= 1;
                }
                return .{ .tok_type = .rbracket, .text = self.buffer[start..self.index] };
            },
            ',' => return .{ .tok_type = .comma, .text = self.buffer[start..self.index] },
            ':' => return .{ .tok_type = .colon, .text = self.buffer[start..self.index] },
            '.' => return .{ .tok_type = .period, .text = self.buffer[start..self.index] },
            '?' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '?') {
                    self.index += 1;
                    return .{ .tok_type = .coalesce, .text = self.buffer[start..self.index] };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '.') {
                    self.index += 1;
                    return .{ .tok_type = .question_period, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .question, .text = self.buffer[start..self.index] };
            },
            '+' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .plus_eq, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .plus, .text = self.buffer[start..self.index] };
            },
            '-' => return .{ .tok_type = .minus, .text = self.buffer[start..self.index] },
            '*' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '*') {
                    self.index += 1;
                    return .{ .tok_type = .star_star, .text = self.buffer[start..self.index] };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .star_eq, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .star, .text = self.buffer[start..self.index] };
            },
            '/' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '/') {
                    self.index += 1;
                    return .{ .tok_type = .slash_slash, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .slash, .text = self.buffer[start..self.index] };
            },
            '^' => return .{ .tok_type = .caret, .text = self.buffer[start..self.index] },
            '%' => return .{ .tok_type = .percent, .text = self.buffer[start..self.index] },
            '=' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .eq_eq, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .eq, .text = self.buffer[start..self.index] };
            },
            '<' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .le, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .lt, .text = self.buffer[start..self.index] };
            },
            '>' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .ge, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .gt, .text = self.buffer[start..self.index] };
            },
            '!' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .ne, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .eof, .text = self.buffer[start..self.index] };
            },
            else => return .{ .tok_type = .eof, .text = self.buffer[start..self.index] },
        }
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == ' ' or c == '\r' or c == '\t') {
                self.index += 1;
            } else if (c == '#') {
                while (self.index < self.buffer.len and self.buffer[self.index] != '\n') {
                    self.index += 1;
                }
            } else {
                break;
            }
        }
    }
};

const ExpressionParser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    current_token: Token,
    line_num: usize,
    source: []const u8,

    fn init(allocator: std.mem.Allocator, full_source: []const u8, expr_source: []const u8, line_num: usize) ExpressionParser {
        var tokenizer = Tokenizer.init(full_source, expr_source, line_num);
        const current_token = tokenizer.next();
        return .{
            .allocator = allocator,
            .tokenizer = tokenizer,
            .current_token = current_token,
            .line_num = line_num,
            .source = full_source,
        };
    }


    fn advance(self: *ExpressionParser) void {
        self.current_token = self.tokenizer.next();
    }

    fn consume(self: *ExpressionParser, tok_type: TokenType) !void {
        if (self.current_token.tok_type == tok_type) {
            self.advance();
        } else {
            errors.printExpectedError(self.source, self.line_num, @tagName(tok_type), @tagName(self.current_token.tok_type));
            return error.InvalidExpression;
        }
    }

    fn parse(self: *ExpressionParser) !*AstNode {
        return try self.parseAssignment();
    }

    fn parseAssignment(self: *ExpressionParser) !*AstNode {
        const left = try self.parseLogical();
        if (self.current_token.tok_type == .colon and left.node_type == .var_ref and left.target == null) {
            try self.consume(.colon);
            const type_name = self.current_token.text;
            try self.consume(.identifier);
            var full_type: []const u8 = type_name;
            if (self.current_token.tok_type == .lbracket) {
                var full = std.ArrayList(u8).init(self.allocator);
                defer full.deinit();
                try full.appendSlice(type_name);
                var depth: usize = 0;
                while (self.current_token.tok_type != .eof) {
                    if (self.current_token.tok_type == .lbracket) {
                        depth += 1;
                        try full.appendSlice(self.current_token.text);
                        self.advance();
                    } else if (self.current_token.tok_type == .rbracket) {
                        depth -= 1;
                        try full.appendSlice(self.current_token.text);
                        self.advance();
                        if (depth == 0) break;
                    } else {
                        try full.appendSlice(self.current_token.text);
                        self.advance();
                    }
                }
                full_type = try full.toOwnedSlice();
            }
            if (self.current_token.tok_type == .eq) {
                try self.consume(.eq);
                const right = try self.parseAssignment();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .node_type = .assign,
                    .line = self.line_num,
                    .name = try self.allocator.dupe(u8, left.name),
                    .extra = try self.allocator.dupe(u8, full_type),
                };
                node.args = std.ArrayList(*AstNode).init(self.allocator);
                try node.args.?.append(right);
                freeAstNode(self.allocator, left);
                return node;
            }
            left.extra = try self.allocator.dupe(u8, full_type);
            return left;
        }
        if (self.current_token.tok_type == .eq) {
            try self.consume(.eq);
            const right = try self.parseAssignment();
            const node = try self.allocator.create(AstNode);
            const target = left.target;
            const is_optional = left.is_optional;
            left.target = null;
            node.* = .{
                .node_type = .assign,
                .line = self.line_num,
                .name = try self.allocator.dupe(u8, left.name),
                .target = target,
                .is_optional = is_optional,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(right);
            freeAstNode(self.allocator, left);
            return node;
        } else if (self.current_token.tok_type == .plus_eq) {
            try self.consume(.plus_eq);
            const right = try self.parseAssignment();
            const node = try self.allocator.create(AstNode);
            const target = left.target;
            left.target = null;
            node.* = .{
                .node_type = .aug_assign_add,
                .line = self.line_num,
                .name = try self.allocator.dupe(u8, left.name),
                .target = target,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(right);
            freeAstNode(self.allocator, left);
            return node;
        } else if (self.current_token.tok_type == .star_eq) {
            try self.consume(.star_eq);
            const right = try self.parseAssignment();
            const node = try self.allocator.create(AstNode);
            const target = left.target;
            left.target = null;
            node.* = .{
                .node_type = .aug_assign_mul,
                .line = self.line_num,
                .name = try self.allocator.dupe(u8, left.name),
                .target = target,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(right);
            freeAstNode(self.allocator, left);
            return node;
        }
        return left;
    }

    fn parseLogical(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parseCoalesce();
        while (self.current_token.tok_type == .kw_and or self.current_token.tok_type == .kw_or) {
            const op = self.current_token.tok_type;
            try self.consume(op);
            const right = try self.parseCoalesce();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = if (op == .kw_and) .and_op else .or_op,
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parseCoalesce(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parseEquality();
        while (self.current_token.tok_type == .coalesce) {
            try self.consume(.coalesce);
            const right = try self.parseEquality();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = .coalesce,
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parseEquality(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parseComparison();
        while (self.current_token.tok_type == .eq_eq or self.current_token.tok_type == .ne) {
            const op = self.current_token.tok_type;
            try self.consume(op);
            const right = try self.parseComparison();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = if (op == .eq_eq) .eq else .ne,
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parseComparison(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parseAddSub();
        while (self.current_token.tok_type == .lt or self.current_token.tok_type == .gt or self.current_token.tok_type == .le or self.current_token.tok_type == .ge or self.current_token.tok_type == .kw_in) {
            const op = self.current_token.tok_type;
            try self.consume(op);
            const right = try self.parseAddSub();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = switch (op) {
                    .lt => .lt,
                    .gt => .gt,
                    .le => .le,
                    .ge => .ge,
                    .kw_in => .in_op,
                    else => unreachable,
                },
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parseAddSub(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parseMulDiv();
        while (self.current_token.tok_type == .plus or self.current_token.tok_type == .minus) {
            const op = self.current_token.tok_type;
            try self.consume(op);
            const right = try self.parseMulDiv();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = if (op == .plus) .add else .sub,
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parseMulDiv(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parsePower();
        while (self.current_token.tok_type == .star or self.current_token.tok_type == .slash or self.current_token.tok_type == .percent or self.current_token.tok_type == .slash_slash) {
            const op = self.current_token.tok_type;
            try self.consume(op);
            const right = try self.parsePower();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = if (op == .star) .mul else if (op == .slash) .div else if (op == .percent) .mod else .int_div,
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parsePower(self: *ExpressionParser) anyerror!*AstNode {
        var expr = try self.parsePrimary();
        while (self.current_token.tok_type == .star_star or self.current_token.tok_type == .caret) {
            const op = self.current_token.tok_type;
            try self.consume(op);
            const right = try self.parsePower();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .node_type = .pow,
                .line = self.line_num,
            };
            node.args = std.ArrayList(*AstNode).init(self.allocator);
            try node.args.?.append(expr);
            try node.args.?.append(right);
            expr = node;
        }
        return expr;
    }

    fn parseRawArray(self: *ExpressionParser) anyerror!*AstNode {
        try self.consume(.identifier); // 'raw'
        const type_tok = self.current_token;
        try self.consume(.identifier);
        var type_name: []const u8 = "";
        if (std.mem.eql(u8, type_tok.text, "int")) {
            type_name = "raw_int";
        } else if (std.mem.eql(u8, type_tok.text, "float")) {
            type_name = "raw_float";
        } else if (std.mem.eql(u8, type_tok.text, "bool")) {
            type_name = "raw_bool";
        } else {
            return error.InvalidExpression;
        }
        try self.consume(.lbracket);
        const size_node = try self.parseAssignment();
        try self.consume(.rbracket);
        const n = try self.allocator.create(AstNode);
        n.* = .{ .node_type = .call, .line = self.line_num, .name = try self.allocator.dupe(u8, type_name) };
        n.args = std.ArrayList(*AstNode).init(self.allocator);
        try n.args.?.append(size_node);
        return n;
    }

    fn parsePrimary(self: *ExpressionParser) anyerror!*AstNode {
        const tok = self.current_token;
        if (tok.tok_type == .identifier and std.mem.eql(u8, tok.text, "raw")) {
            return try self.parseRawArray();
        }
        var node: *AstNode = undefined;
        switch (tok.tok_type) {
            .number_int => {
                try self.consume(.number_int);
                const n = try self.allocator.create(AstNode);
                const raw_text = try self.allocator.dupe(u8, tok.text);
                n.* = .{
                    .node_type = .val_int,
                    .line = self.line_num,
                    .val_int = std.fmt.parseInt(i64, tok.text, 10) catch 0,
                    .val_string = raw_text,
                };
                node = n;
            },
            .number_float => {
                try self.consume(.number_float);
                const n = try self.allocator.create(AstNode);
                const raw_text = try self.allocator.dupe(u8, tok.text);
                n.* = .{
                    .node_type = .val_float,
                    .line = self.line_num,
                    .val_float = try std.fmt.parseFloat(f64, tok.text),
                    .val_string = raw_text,
                };
                node = n;
            },
            .string => {
                try self.consume(.string);
                const inner = tok.text[1 .. tok.text.len - 1];
                if (std.mem.indexOf(u8, inner, "{{")) |_| {
                    var parts = std.ArrayList(*AstNode).init(self.allocator);
                    var i: usize = 0;
                    var start: usize = 0;
                    while (i < inner.len) {
                        if (inner[i] == '\\' and i + 1 < inner.len) {
                            i += 2;
                            continue;
                        }
                        if (i + 1 < inner.len and inner[i] == '{' and inner[i + 1] == '{') {
                            if (i > start) {
                                const lit = try unescapeString(self.allocator, inner[start..i]);
                                const ln = try self.allocator.create(AstNode);
                                ln.* = .{ .node_type = .val_string, .line = self.line_num, .val_string = lit };
                                try parts.append(ln);
                            }
                            i += 2;
                            var depth: usize = 1;
                            const expr_start = i;
                            while (i < inner.len and depth > 0) {
                                if (inner[i] == '{') depth += 1;
                                if (inner[i] == '}') depth -= 1;
                                if (depth > 0) i += 1;
                            }
                            const expr_text = inner[expr_start..i];
                            var ep = ExpressionParser.init(self.allocator, self.source, expr_text, self.line_num);
                            const expr_node = try ep.parse();
                            const str_call = try self.allocator.create(AstNode);
                            str_call.* = .{ .node_type = .call, .line = self.line_num, .name = try self.allocator.dupe(u8, "str") };
                            str_call.args = std.ArrayList(*AstNode).init(self.allocator);
                            try str_call.args.?.append(expr_node);
                            try parts.append(str_call);
                            i += 1;
                            if (i < inner.len and inner[i] == '}') i += 1;
                            start = i;
                        } else {
                            i += 1;
                        }
                    }
                    if (start < inner.len) {
                        const lit = try unescapeString(self.allocator, inner[start..]);
                        const ln = try self.allocator.create(AstNode);
                        ln.* = .{ .node_type = .val_string, .line = self.line_num, .val_string = lit };
                        try parts.append(ln);
                    }
                    node = parts.items[0];
                    var j: usize = 1;
                    while (j < parts.items.len) : (j += 1) {
                        const add = try self.allocator.create(AstNode);
                        add.* = .{ .node_type = .add, .line = self.line_num };
                        add.args = std.ArrayList(*AstNode).init(self.allocator);
                        try add.args.?.append(node);
                        try add.args.?.append(parts.items[j]);
                        node = add;
                    }
                    parts.deinit();
                } else {
                    const n = try self.allocator.create(AstNode);
                    n.* = .{
                        .node_type = .val_string,
                        .line = self.line_num,
                        .val_string = try unescapeString(self.allocator, inner),
                    };
                    node = n;
                }
            },
            .kw_true => {
                try self.consume(.kw_true);
                const n = try self.allocator.create(AstNode);
                n.* = .{
                    .node_type = .val_bool,
                    .line = self.line_num,
                    .val_int = 1,
                };
                node = n;
            },
            .kw_false => {
                try self.consume(.kw_false);
                const n = try self.allocator.create(AstNode);
                n.* = .{
                    .node_type = .val_bool,
                    .line = self.line_num,
                    .val_int = 0,
                };
                node = n;
            },
            .kw_nil => {
                try self.consume(.kw_nil);
                const n = try self.allocator.create(AstNode);
                n.* = .{
                    .node_type = .val_nil,
                    .line = self.line_num,
                };
                node = n;
            },
            .identifier => {
                try self.consume(.identifier);
                var full_path = std.ArrayList(u8).init(self.allocator);
                defer full_path.deinit();
                try full_path.appendSlice(tok.text);

                while (self.current_token.tok_type == .period or self.current_token.tok_type == .lbracket) {
                    if (self.current_token.tok_type == .period) {
                        try full_path.append('.');
                        self.advance();
                        if (self.current_token.tok_type == .identifier) {
                            try full_path.appendSlice(self.current_token.text);
                            self.advance();
                        } else {
                            return error.InvalidExpression;
                        }
                    } else if (self.current_token.tok_type == .lbracket) {
                        try full_path.append('[');
                        self.advance();

                        while (self.current_token.tok_type != .rbracket and self.current_token.tok_type != .eof) {
                            try full_path.appendSlice(self.current_token.text);
                            self.advance();
                        }

                        if (self.current_token.tok_type == .rbracket) {
                            try full_path.append(']');
                            self.advance();
                        }
                    }
                }

                if (self.current_token.tok_type == .lparen) {
                    try self.consume(.lparen);
                    const n = try self.allocator.create(AstNode);
                    n.* = .{
                        .node_type = .call,
                        .line = self.line_num,
                        .name = try self.allocator.dupe(u8, full_path.items),
                    };
                    n.args = std.ArrayList(*AstNode).init(self.allocator);
                    while (self.current_token.tok_type != .rparen and self.current_token.tok_type != .eof) {
                        const arg = try self.parseAssignment();
                        try n.args.?.append(arg);
                        if (self.current_token.tok_type == .comma) {
                            try self.consume(.comma);
                        }
                    }
                    try self.consume(.rparen);
                    node = n;
                } else {
                    const n = try self.allocator.create(AstNode);
                    n.* = .{
                        .node_type = .var_ref,
                        .line = self.line_num,
                        .name = try self.allocator.dupe(u8, full_path.items),
                    };
                    node = n;
                }
            },
            .lparen => {
                try self.consume(.lparen);
                node = try self.parseAssignment();
                try self.consume(.rparen);
            },
            .lbrace => {
                try self.consume(.lbrace);
                const n = try self.allocator.create(AstNode);
                n.* = .{
                    .node_type = .val_dict,
                    .line = self.line_num,
                };
                n.args = std.ArrayList(*AstNode).init(self.allocator);
                while (self.current_token.tok_type != .rbrace and self.current_token.tok_type != .eof) {
                    const key = try self.parseAssignment();
                    try n.args.?.append(key);
                    try self.consume(.colon);
                    const val = try self.parseAssignment();
                    try n.args.?.append(val);
                    if (self.current_token.tok_type == .comma) {
                        try self.consume(.comma);
                    }
                }
                try self.consume(.rbrace);
                node = n;
            },
            .lbracket => {
                try self.consume(.lbracket);
                const n = try self.allocator.create(AstNode);
                n.* = .{
                    .node_type = .val_list,
                    .line = self.line_num,
                };
                n.args = std.ArrayList(*AstNode).init(self.allocator);
                while (self.current_token.tok_type != .rbracket and self.current_token.tok_type != .eof) {
                    const item = try self.parseAssignment();
                    try n.args.?.append(item);
                    if (self.current_token.tok_type == .comma) {
                        try self.consume(.comma);
                    }
                }
                try self.consume(.rbracket);
                node = n;
            },
            .minus => {
                try self.consume(.minus);
                var inner = try self.parsePrimary();
                if (inner.node_type == .val_int) {
                    inner.val_int = -inner.val_int;
                    if (inner.val_string.len > 0) {
                        inner.val_string = try std.fmt.allocPrint(self.allocator, "-{s}", .{inner.val_string});
                    }
                    node = inner;
                } else if (inner.node_type == .val_float) {
                    inner.val_float = -inner.val_float;
                    if (inner.val_string.len > 0) {
                        inner.val_string = try std.fmt.allocPrint(self.allocator, "-{s}", .{inner.val_string});
                    }
                    node = inner;
                } else {
                    const zero = try self.allocator.create(AstNode);
                    zero.* = .{ .node_type = .val_int, .line = self.line_num, .val_int = 0 };
                    const n = try self.allocator.create(AstNode);
                    n.* = .{ .node_type = .sub, .line = self.line_num };
                    n.args = std.ArrayList(*AstNode).init(self.allocator);
                    try n.args.?.append(zero);
                    try n.args.?.append(inner);
                    node = n;
                }
            },
            else => {
                errors.printSyntaxError(self.source, self.line_num, 0, "Unexpected token");
                return error.InvalidExpression;
            },
        }
        while (self.current_token.tok_type == .period or self.current_token.tok_type == .question_period or self.current_token.tok_type == .lbracket) {
            const is_opt = self.current_token.tok_type == .question_period;
            if (self.current_token.tok_type == .period or self.current_token.tok_type == .question_period) {
                self.advance();
                if (self.current_token.tok_type == .identifier) {
                    const prop_name = self.current_token.text;
                    self.advance();
                    if (self.current_token.tok_type == .lparen) {
                        try self.consume(.lparen);
                        const call_node = try self.allocator.create(AstNode);
                        call_node.* = .{
                            .node_type = .call,
                            .line = self.line_num,
                            .name = try self.allocator.dupe(u8, prop_name),
                            .is_optional = is_opt,
                        };
                        call_node.args = std.ArrayList(*AstNode).init(self.allocator);
                        while (self.current_token.tok_type != .rparen and self.current_token.tok_type != .eof) {
                            const arg = try self.parseAssignment();
                            try call_node.args.?.append(arg);
                            if (self.current_token.tok_type == .comma) {
                                try self.consume(.comma);
                            }
                        }
                        try self.consume(.rparen);
                        call_node.target = node;
                        node = call_node;
                    } else {
                        const prop_node = try self.allocator.create(AstNode);
                        prop_node.* = .{
                            .node_type = .var_ref,
                            .line = self.line_num,
                            .name = try self.allocator.dupe(u8, prop_name),
                            .target = node,
                            .is_optional = is_opt,
                        };
                        node = prop_node;
                    }
                } else {
                    return error.InvalidExpression;
                }
            } else if (self.current_token.tok_type == .lbracket) {
                self.advance();
                const index_node = try self.parseAssignment();
                try self.consume(.rbracket);
                const access_node = try self.allocator.create(AstNode);
                access_node.* = .{
                    .node_type = .call,
                    .line = self.line_num,
                    .name = try self.allocator.dupe(u8, "__getitem__"),
                };
                access_node.args = std.ArrayList(*AstNode).init(self.allocator);
                try access_node.args.?.append(index_node);
                access_node.target = node;
                node = access_node;
            }
        }
        if (self.current_token.tok_type == .question) {
            self.advance();
            node.is_optional = true;
        }
        return node;
    }
};
const LineInfo = struct {
    indent: usize,
    content: []const u8,
};

pub fn unescapeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '\\' => try result.append('\\'),
                '"' => try result.append('"'),
                '\'' => try result.append('\''),
                'n' => try result.append('\n'),
                't' => try result.append('\t'),
                'r' => try result.append('\r'),
                '0' => try result.append(0),
                else => {
                    try result.append('\\');
                    try result.append(s[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(s[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

fn getLineInfo(allocator: std.mem.Allocator, line: []const u8) !LineInfo {
    var indent: usize = 0;
    while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
    const trimmed = std.mem.trim(u8, line[indent..], " \r\n\t");
    return .{
        .indent = indent,
        .content = try allocator.dupe(u8, trimmed),
    };
}

fn hasPrivatePrefix(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "private ")) return true;
    if (std.mem.startsWith(u8, trimmed, "private\t")) return true;
    return false;
}

fn splitTopLevel(allocator: std.mem.Allocator, src: []const u8, sep: u8) !std.ArrayList([]const u8) {
    // split on `sep` that is not inside a string literal or a [] {} () group
    var result = std.ArrayList([]const u8).init(allocator);
    var start: usize = 0;
    var depth: usize = 0;
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str != 0) {
            if (c == '\\') { i += 1; continue; }
            if (c == in_str) in_str = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_str = c,
            '[', '{', '(' => depth += 1,
            ']', '}', ')' => if (depth > 0) {
                depth -= 1;
            },
            else => {
                if (c == sep and depth == 0) {
                    try result.append(src[start..i]);
                    start = i + 1;
                }
            },
        }
    }
    try result.append(src[start..]);
    return result;
}

fn findTopLevelChar(src: []const u8, needle: u8) ?usize {
    var depth: usize = 0;
    var in_str: u8 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str != 0) {
            if (c == '\\') { i += 1; continue; }
            if (c == in_str) in_str = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => in_str = c,
            '[', '{', '(' => depth += 1,
            ']', '}', ')' => if (depth > 0) {
                depth -= 1;
            },
            else => {
                if (c == needle and depth == 0) return i;
            },
        }
    }
    return null;
}

fn parseEnum(allocator: std.mem.Allocator, full_source: []const u8, line: []const u8, line_num: usize) anyerror!*AstNode {
    // line = "enum Name { A, B = 5, C = "hi" }" (single-line declaration)
    const after_kw = std.mem.trim(u8, line[5..], " \r\n\t");
    const brace = std.mem.indexOfScalar(u8, after_kw, '{') orelse {
        errors.printSyntaxError(full_source, line_num, 0, "expected '{' after enum name");
        return error.InvalidExpression;
    };
    const name = std.mem.trim(u8, after_kw[0..brace], " \r\n\t");
    const close = std.mem.lastIndexOfScalar(u8, after_kw, '}') orelse {
        errors.printSyntaxError(full_source, line_num, 0, "unclosed enum declaration");
        return error.InvalidExpression;
    };
    const members = after_kw[brace + 1 .. close];

    const dict = try allocator.create(AstNode);
    dict.* = .{ .node_type = .val_dict, .line = line_num };
    dict.args = std.ArrayList(*AstNode).init(allocator);

    var value: i64 = 0;
    var member_list = try splitTopLevel(allocator, members, ',');
    defer member_list.deinit();
    for (member_list.items) |member_raw| {
        const member = std.mem.trim(u8, member_raw, " \r\n\t");
        if (member.len == 0) continue;
        var member_name: []const u8 = member;
        var val_node: *AstNode = undefined;
        if (findTopLevelChar(member, '=')) |eq| {
            member_name = std.mem.trim(u8, member[0..eq], " \r\n\t");
            const val_text = std.mem.trim(u8, member[eq + 1 ..], " \r\n\t");
            val_node = try pltn(allocator, full_source, val_text, line_num);
            if (val_node.node_type == .val_int) {
                value = val_node.val_int;
                value += 1;
            }
        } else {
            const auto_node = try allocator.create(AstNode);
            auto_node.* = .{ .node_type = .val_int, .line = line_num, .val_int = value };
            val_node = auto_node;
            value += 1;
        }
        const key_node = try allocator.create(AstNode);
        key_node.* = .{ .node_type = .val_string, .line = line_num, .val_string = try allocator.dupe(u8, member_name) };
        try dict.args.?.append(key_node);
        try dict.args.?.append(val_node);
    }

    const node = try allocator.create(AstNode);
    node.* = .{
        .node_type = .assign,
        .line = line_num,
        .name = try allocator.dupe(u8, name),
        .extra = try allocator.dupe(u8, "enum"),
    };
    node.args = std.ArrayList(*AstNode).init(allocator);
    try node.args.?.append(dict);
    return node;
}

fn parseStatement(allocator: std.mem.Allocator, full_source: []const u8, line: []const u8, line_num: usize) !*AstNode {
    var trimmed = line;
    if (std.mem.endsWith(u8, trimmed, ":")) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    trimmed = std.mem.trim(u8, trimmed, " \r\n\t");

    var is_private = false;
    if (hasPrivatePrefix(trimmed)) {
        is_private = true;
        trimmed = std.mem.trim(u8, trimmed[8..], " \r\n\t");
    }

    if (std.mem.startsWith(u8, trimmed, "enum ")) {
        return try parseEnum(allocator, full_source, trimmed, line_num);
    }

    if (std.mem.startsWith(u8, trimmed, "extern func ")) {
        const signature = std.mem.trim(u8, trimmed[10..], " ");
        var it = std.mem.splitSequence(u8, signature, "(");
        const name = std.mem.trim(u8, it.next().?, " ");
        const rest = it.next().?;
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len;
        const args_str = rest[0..close];
        const ret_str = std.mem.trim(u8, rest[close + 1 ..], " ");

        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .func_def,
            .line = line_num,
            .name = try allocator.dupe(u8, name),
            .is_private = is_private,
            .is_extern = true,
            .extra = if (ret_str.len > 0) try allocator.dupe(u8, ret_str) else null,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);

        var arg_it = std.mem.splitSequence(u8, args_str, ",");
        while (arg_it.next()) |arg| {
            const cleaned_arg = std.mem.trim(u8, arg, " ");
            if (cleaned_arg.len > 0) {
                var eq_it = std.mem.splitSequence(u8, cleaned_arg, "=");
                const raw_arg_name = std.mem.trim(u8, eq_it.next().?, " ");
                var arg_name: []const u8 = raw_arg_name;
                var arg_type: ?[]const u8 = null;
                if (std.mem.indexOf(u8, raw_arg_name, ":")) |colon_idx| {
                    arg_name = std.mem.trim(u8, raw_arg_name[0..colon_idx], " ");
                    arg_type = std.mem.trim(u8, raw_arg_name[colon_idx + 1 ..], " ");
                } else if (std.mem.indexOf(u8, raw_arg_name, " ")) |space_idx| {
                    const first = std.mem.trim(u8, raw_arg_name[0..space_idx], " ");
                    const second = std.mem.trim(u8, raw_arg_name[space_idx + 1 ..], " ");
                    if (second.len > 0) {
                        arg_type = first;
                        arg_name = second;
                    }
                }
                const arg_node = try allocator.create(AstNode);
                arg_node.* = .{
                    .node_type = .var_ref,
                    .line = line_num,
                    .name = try allocator.dupe(u8, arg_name),
                };
                if (arg_type) |t| {
                    arg_node.extra = try allocator.dupe(u8, t);
                }
                try node.args.?.append(arg_node);
            }
        }

        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "func ")) {
        const signature = std.mem.trim(u8, trimmed[5..], " ");
        var it = std.mem.splitSequence(u8, signature, "(");
        const name = std.mem.trim(u8, it.next().?, " ");
        const rest = it.next().?;
        const close_paren = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len;
        const args_str = rest[0..close_paren];
        var ret_type_str = std.mem.trim(u8, rest[close_paren + 1 ..], " \t\r");
        if (ret_type_str.len > 0 and ret_type_str[ret_type_str.len - 1] == ':') {
            ret_type_str = std.mem.trim(u8, ret_type_str[0 .. ret_type_str.len - 1], " \t\r");
        }
        if (std.mem.startsWith(u8, ret_type_str, "->")) {
            ret_type_str = std.mem.trim(u8, ret_type_str[2..], " \t\r");
        }

        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .func_def,
            .line = line_num,
            .name = try allocator.dupe(u8, name),
            .is_private = is_private,
            .extra = if (ret_type_str.len > 0) try allocator.dupe(u8, ret_type_str) else null,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);

        var arg_it = std.mem.splitSequence(u8, args_str, ",");
        while (arg_it.next()) |arg| {
            const cleaned_arg = std.mem.trim(u8, arg, " ");
            if (cleaned_arg.len > 0) {
                var eq_it = std.mem.splitSequence(u8, cleaned_arg, "=");
                const raw_arg_name = std.mem.trim(u8, eq_it.next().?, " ");
                const default_str = if (eq_it.next()) |d| std.mem.trim(u8, d, " ") else "";
                var arg_name: []const u8 = raw_arg_name;
                var arg_type: ?[]const u8 = null;
                if (std.mem.indexOf(u8, raw_arg_name, ":")) |colon_idx| {
                    arg_name = std.mem.trim(u8, raw_arg_name[0..colon_idx], " ");
                    arg_type = std.mem.trim(u8, raw_arg_name[colon_idx + 1 ..], " ");
                } else if (std.mem.indexOf(u8, raw_arg_name, " ")) |space_idx| {
                    const first = std.mem.trim(u8, raw_arg_name[0..space_idx], " ");
                    const second = std.mem.trim(u8, raw_arg_name[space_idx + 1 ..], " ");
                    if (second.len > 0) {
                        arg_type = first;
                        arg_name = second;
                    }
                }
                var is_optional = false;
                if (std.mem.endsWith(u8, arg_name, "?")) {
                    is_optional = true;
                    arg_name = std.mem.trim(u8, arg_name[0 .. arg_name.len - 1], " ");
                }
                const arg_node = try allocator.create(AstNode);
                arg_node.* = .{
                    .node_type = .var_ref,
                    .line = line_num,
                    .name = try allocator.dupe(u8, arg_name),
                    .is_optional = is_optional,
                };
                if (arg_type) |t| {
                    arg_node.extra = try allocator.dupe(u8, t);
                }
                if (default_str.len > 0) {
                    var ep = ExpressionParser.init(allocator, full_source, default_str, line_num);
                    const default_node = try ep.parse();
                    arg_node.args = std.ArrayList(*AstNode).init(allocator);
                    try arg_node.args.?.append(default_node);
                }
                try node.args.?.append(arg_node);
            }
        }
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "class ")) {
        const body = std.mem.trim(u8, trimmed[6..], " ");
        var name = body;
        var base: ?[]const u8 = null;
        if (std.mem.containsAtLeast(u8, body, 1, "(")) {
            var it = std.mem.splitSequence(u8, body, "(");
            name = std.mem.trim(u8, it.next().?, " ");
            const rest = it.next().?;
            base = std.mem.trim(u8, rest[0 .. rest.len - 1], " ");
        }

        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .class_def,
            .line = line_num,
            .name = try allocator.dupe(u8, name),
            .extra = if (base) |b| try allocator.dupe(u8, b) else null,
        };
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "if ")) {
        const cond_str = std.mem.trim(u8, trimmed[3..], " ");
        var ep = ExpressionParser.init(allocator, full_source, cond_str, line_num);
        const cond_node = try ep.parse();
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .if_stmt,
            .line = line_num,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);
        try node.args.?.append(cond_node);
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "elif ")) {
        const cond_str = std.mem.trim(u8, trimmed[5..], " ");
        var ep = ExpressionParser.init(allocator, full_source, cond_str, line_num);
        const cond_node = try ep.parse();
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .elif_stmt,
            .line = line_num,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);
        try node.args.?.append(cond_node);
        return node;
    }

    if (std.mem.eql(u8, trimmed, "else")) {
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .else_stmt,
            .line = line_num,
        };
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "while ")) {
        const cond_str = std.mem.trim(u8, trimmed[6..], " ");
        var ep = ExpressionParser.init(allocator, full_source, cond_str, line_num);
        const cond_node = try ep.parse();
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .while_loop,
            .line = line_num,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);
        try node.args.?.append(cond_node);
        return node;
    }

    if (std.mem.eql(u8, trimmed, "return")) {
        const zero = try allocator.create(AstNode);
        zero.* = .{ .node_type = .val_int, .line = line_num, .val_int = 0 };
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .return_stmt,
            .line = line_num,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);
        try node.args.?.append(zero);
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "return ")) {
        const expr_str = std.mem.trim(u8, trimmed[7..], " ");
        var ep = ExpressionParser.init(allocator, full_source, expr_str, line_num);
        const expr_node = try ep.parse();
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .return_stmt,
            .line = line_num,
        };
        node.args = std.ArrayList(*AstNode).init(allocator);
        try node.args.?.append(expr_node);
        return node;
    }

    if (std.mem.eql(u8, trimmed, "break")) {
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .break_stmt,
            .line = line_num,
        };
        return node;
    }

    if (std.mem.eql(u8, trimmed, "pass")) {
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .pass_stmt,
            .line = line_num,
        };
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "for ")) {
        const body = std.mem.trim(u8, trimmed[4..], " ");
        var it = std.mem.splitSequence(u8, body, " in ");
        const var_name = std.mem.trim(u8, it.next().?, " ");
        const iter_expr = it.next().?;

        var ep = ExpressionParser.init(allocator, full_source, iter_expr, line_num);
        const iter_node = try ep.parse();

        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .for_loop,
            .line = line_num,
            .name = try allocator.dupe(u8, var_name),
        };
        node.args = std.ArrayList(*AstNode).init(allocator);
        try node.args.?.append(iter_node);
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "import crate ")) {
        const body = std.mem.trim(u8, trimmed[13..], " ");
        var name: []const u8 = undefined;
        var alias: []const u8 = undefined;
        if (std.mem.indexOf(u8, body, " as ")) |as_idx| {
            name = std.mem.trim(u8, body[0..as_idx], " ");
            alias = std.mem.trim(u8, body[as_idx + 4 ..], " ");
        } else {
            name = std.mem.trim(u8, body, " ");
            alias = name;
        }
        const crate_path = try std.fmt.allocPrint(allocator, "crate:{s}", .{name});
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .import_stmt,
            .line = line_num,
            .name = try allocator.dupe(u8, alias),
            .extra = crate_path,
        };
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "import ")) {
        const body = std.mem.trim(u8, trimmed[7..], " ");
        var raw: []const u8 = undefined;
        var alias: []const u8 = undefined;
        var deps_part: ?[]const u8 = null;

        if (std.mem.indexOf(u8, body, " with ")) |with_idx| {
            deps_part = std.mem.trim(u8, body[with_idx + 6 ..], " ");
            const before_with = std.mem.trim(u8, body[0..with_idx], " ");
            if (std.mem.indexOf(u8, before_with, " as ")) |as_idx| {
                raw = std.mem.trim(u8, before_with[0..as_idx], " ");
                alias = std.mem.trim(u8, before_with[as_idx + 4 ..], " ");
            } else {
                raw = std.mem.trim(u8, before_with, " ");
                alias = raw;
            }
        } else if (std.mem.indexOf(u8, body, " as ")) |as_idx| {
            raw = std.mem.trim(u8, body[0..as_idx], " ");
            alias = std.mem.trim(u8, body[as_idx + 4 ..], " ");
        } else {
            raw = std.mem.trim(u8, body, " ");
            alias = raw;
        }

        var path: []const u8 = raw;
        if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
            path = path[1 .. path.len - 1];
        }

        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .import_stmt,
            .line = line_num,
            .name = try allocator.dupe(u8, alias),
            .extra = try allocator.dupe(u8, path),
        };


        if (deps_part) |deps_str| {
            node.args = std.ArrayList(*AstNode).init(allocator);
            var dep_it = std.mem.splitSequence(u8, deps_str, ",");
            while (dep_it.next()) |dep_entry| {
                const trimmed_dep = std.mem.trim(u8, dep_entry, " ");
                if (trimmed_dep.len == 0) continue;
                if (std.mem.indexOf(u8, trimmed_dep, " = ")) |eq_idx| {
                    const dep_name = std.mem.trim(u8, trimmed_dep[0..eq_idx], " ");
                    var dep_ver = std.mem.trim(u8, trimmed_dep[eq_idx + 3 ..], " ");
                    if (dep_ver.len >= 2 and dep_ver[0] == '"' and dep_ver[dep_ver.len - 1] == '"') {
                        dep_ver = dep_ver[1 .. dep_ver.len - 1];
                    }
                    const spec = try std.fmt.allocPrint(allocator, "{s} = \"{s}\"", .{ dep_name, dep_ver });
                    const dep_node = try allocator.create(AstNode);
                    dep_node.* = .{
                        .node_type = .val_string,
                        .line = line_num,
                        .val_string = spec,
                    };
                    try node.args.?.append(dep_node);
                }
            }
        }

        return node;
    }

    if (std.mem.eql(u8, trimmed, "try")) {
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .try_stmt,
            .line = line_num,
        };
        return node;
    }

    if (std.mem.eql(u8, trimmed, "except")) {
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .except_stmt,
            .line = line_num,
        };
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "except ")) {
        var exc_var = std.mem.trim(u8, trimmed[7..], " \r\n\t");
        if (std.mem.endsWith(u8, exc_var, ":")) {
            exc_var = std.mem.trim(u8, exc_var[0 .. exc_var.len - 1], " \r\n\t");
        }
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .except_stmt,
            .line = line_num,
            .name = try allocator.dupe(u8, exc_var),
        };
        return node;
    }

    if (std.mem.startsWith(u8, trimmed, "export ")) {
        const body = std.mem.trim(u8, trimmed[7..], " ");

        var source_part: []const u8 = undefined;
        var func_name: []const u8 = undefined;
        var alias: []const u8 = undefined;

        if (std.mem.indexOf(u8, body, " as ")) |as_idx| {
            const before_as = std.mem.trim(u8, body[0..as_idx], " ");
            alias = std.mem.trim(u8, body[as_idx + 4 ..], " ");


            if (std.mem.lastIndexOfScalar(u8, before_as, '.')) |dot_idx| {
                source_part = std.mem.trim(u8, before_as[0..dot_idx], " ");
                func_name = std.mem.trim(u8, before_as[dot_idx + 1 ..], " ");
            } else {
                source_part = "";
                func_name = before_as;
            }
        } else {

            if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot_idx| {
                source_part = std.mem.trim(u8, body[0..dot_idx], " ");
                func_name = std.mem.trim(u8, body[dot_idx + 1 ..], " ");
                alias = func_name;
            } else {
                source_part = "";
                func_name = body;
                alias = func_name;
            }
        }

        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = .export_stmt,
            .line = line_num,
            .name = try allocator.dupe(u8, func_name),
            .extra = if (source_part.len > 0) try allocator.dupe(u8, source_part) else null,
            .val_string = try allocator.dupe(u8, alias),
        };
        return node;
    }

    var ep = ExpressionParser.init(allocator, full_source, trimmed, line_num);
    return try ep.parse();
}

pub fn pltn(allocator: std.mem.Allocator, full_source: []const u8, line: []const u8, line_num: usize) !*AstNode {
    return try parseStatement(allocator, full_source, line, line_num);
}

fn buildTreeRecursively(allocator: std.mem.Allocator, full_source: []const u8, lines: []const LineInfo, line_idx: *usize, current_depth: usize) anyerror!std.ArrayList(*AstNode) {
    var block = std.ArrayList(*AstNode).init(allocator);
    errdefer {
        for (block.items) |n| freeAstNode(allocator, n);
        block.deinit();
    }
    var pending_decorators = std.ArrayList(*AstNode).init(allocator);
    errdefer {
        for (pending_decorators.items) |d| freeAstNode(allocator, d);
        pending_decorators.deinit();
    }

    var pending_doc: ?[]const u8 = null;
    var in_doc: bool = false;
    var doc_lines = std.ArrayList(u8).init(allocator);
    defer doc_lines.deinit();

    while (line_idx.* < lines.len) {
        const raw_line = lines[line_idx.*].content;
        const indent = lines[line_idx.*].indent;

        if (raw_line.len == 0 or std.mem.startsWith(u8, raw_line, "#") or std.mem.startsWith(u8, raw_line, "//")) {
            line_idx.* += 1;
            continue;
        }

        const calculated_depth = indent / 4;
        if (calculated_depth < current_depth) {
            break;
        }

        const trimmed_line = std.mem.trim(u8, raw_line, " \r\n\t");

        if (std.mem.startsWith(u8, trimmed_line, "\"\"\"")) {
            if (in_doc) {
                in_doc = false;
                pending_doc = try doc_lines.toOwnedSlice();
                line_idx.* += 1;
                continue;
            }
            in_doc = true;
            doc_lines.shrinkRetainingCapacity(0);
            const after = std.mem.trim(u8, trimmed_line[3..], " \r\n\t");
            if (after.len > 0 and (after.len < 3 or !std.mem.eql(u8, after[after.len-3..], "\"\"\""))) {
                if (after.len > 0) {
                    try doc_lines.appendSlice(after);
                    try doc_lines.append('\n');
                }
            }
            line_idx.* += 1;
            continue;
        }

        if (in_doc) {
            if (std.mem.endsWith(u8, trimmed_line, "\"\"\"")) {
                const content = std.mem.trim(u8, trimmed_line[0..trimmed_line.len-3], " \r\n\t");
                if (content.len > 0) {
                    try doc_lines.appendSlice(content);
                }
                in_doc = false;
                pending_doc = try doc_lines.toOwnedSlice();
            } else {
                try doc_lines.appendSlice(raw_line);
                try doc_lines.append('\n');
            }
            line_idx.* += 1;
            continue;
        }

        if (trimmed_line.len > 0 and trimmed_line[0] == '@') {
            const expr_str = std.mem.trim(u8, trimmed_line[1..], " ");
            var ep = ExpressionParser.init(allocator, full_source, expr_str, line_idx.* + 1);
            const expr_node = try ep.parse();
            try pending_decorators.append(expr_node);
            line_idx.* += 1;
            continue;
        }

        const node = try pltn(allocator, full_source, raw_line, line_idx.* + 1);
        line_idx.* += 1;

        if (node.node_type == .func_def or node.node_type == .for_loop or node.node_type == .while_loop or node.node_type == .if_stmt or node.node_type == .elif_stmt or node.node_type == .else_stmt or node.node_type == .class_def or node.node_type == .try_stmt or node.node_type == .except_stmt) {
            node.subtree = try buildTreeRecursively(allocator, full_source, lines, line_idx, calculated_depth + 1);
        }

        if (pending_decorators.items.len > 0) {
            if (node.node_type == .func_def or node.node_type == .class_def) {
                node.decorators = std.ArrayList(*AstNode).init(allocator);
                for (pending_decorators.items) |d| {
                    try node.decorators.?.append(d);
                }
                pending_decorators.clearAndFree();
            } else {
                for (pending_decorators.items) |d| freeAstNode(allocator, d);
                pending_decorators.clearAndFree();
                errors.printSyntaxError(full_source, node.line, 1, "decorator without function or class definition");
                return error.InvalidExpression;
            }
        }

        if (pending_doc) |ds| {
            if (node.node_type == .func_def) {
                node.doc_string = ds;
            } else {
                allocator.free(ds);
            }
            pending_doc = null;
        }

        if (node.node_type == .elif_stmt) {
            if (block.items.len > 0 and block.items[block.items.len - 1].node_type == .if_stmt) {
                var last_if = block.items[block.items.len - 1];
                if (last_if.elifs == null) last_if.elifs = std.ArrayList(*AstNode).init(allocator);
                try last_if.elifs.?.append(node);
            }
            continue;
        }

        if (node.node_type == .else_stmt) {
            if (block.items.len > 0 and block.items[block.items.len - 1].node_type == .if_stmt) {
                block.items[block.items.len - 1].else_tree = node.subtree;
            }
            if (node.name.len > 0) allocator.free(node.name);
            if (node.val_string.len > 0) allocator.free(node.val_string);
            if (node.args) |args| args.deinit();
            allocator.destroy(node);
            continue;
        }

        if (node.node_type == .except_stmt) {
            if (block.items.len > 0 and block.items[block.items.len - 1].node_type == .try_stmt) {
                block.items[block.items.len - 1].except_tree = node.subtree;
                if (node.name.len > 0) {
                    block.items[block.items.len - 1].name = node.name;
                    node.name = "";
                }
            }
            if (node.name.len > 0) allocator.free(node.name);
            if (node.val_string.len > 0) allocator.free(node.val_string);
            if (node.args) |args| args.deinit();
            allocator.destroy(node);
            continue;
        }

        try block.append(node);
    }
    if (pending_decorators.items.len > 0) {
        for (pending_decorators.items) |d| freeAstNode(allocator, d);
        pending_decorators.deinit();
    } else {
        pending_decorators.deinit();
    }
    return block;
}

pub fn ptoast(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(*AstNode) {
    var lines_list = std.ArrayList(LineInfo).init(allocator);
    defer {
        for (lines_list.items) |info| allocator.free(info.content);
        lines_list.deinit();
    }

    var it = std.mem.splitSequence(u8, source, "\n");
    while (it.next()) |line| {
        const info = try getLineInfo(allocator, line);
        try lines_list.append(info);
    }

    var line_idx: usize = 0;
    return try buildTreeRecursively(allocator, source, lines_list.items, &line_idx, 0);
}
