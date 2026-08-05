const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const AstNode = parser.AstNode;
const freeAstNode = parser.freeAstNode;
const unescapeString = @import("parser.zig").unescapeString;

const TokenType = enum {
    eof, identifier, number_int, number_float, string,
    plus, minus, star, star_star, slash, percent,
    eq, eq_eq, tilde_eq, lt, gt, le, ge,
    lparen, rparen, lbrace, rbrace, lbracket, rbracket,
    comma, colon, period,
    kw_function, kw_end, kw_return, kw_for, kw_while,
    kw_if, kw_elseif, kw_else, kw_then, kw_do, kw_break,
    kw_true, kw_false, kw_import, kw_as, kw_and, kw_or, kw_not, kw_nil, kw_in,
    kw_try, kw_except, kw_export, kw_private, kw_class,
    plus_eq, star_eq, question, question_period, coalesce,
};

const Token = struct { tok_type: TokenType, text: []const u8 };

const Tokenizer = struct {
    buffer: []const u8, source: []const u8, index: usize, line: usize,
    paren_depth: usize, bracket_depth: usize, brace_depth: usize,
    fn init(s: []const u8, buf: []const u8, line: usize) Tokenizer { return .{ .buffer = buf, .source = s, .index = 0, .line = line, .paren_depth = 0, .bracket_depth = 0, .brace_depth = 0 }; }
    fn err(self: *Tokenizer, msg: []const u8) void { errors.printSyntaxError(self.source, self.line, 0, msg); }
    fn next(self: *Tokenizer) Token {
        self.skipWS();
        if (self.index >= self.buffer.len) {
            if (self.paren_depth > 0) self.err("Unclosed '('");
            if (self.bracket_depth > 0) self.err("Unclosed '['");
            if (self.brace_depth > 0) self.err("Unclosed '{'");
            return .{ .tok_type = .eof, .text = "" };
        }
        const start = self.index;
        const c = self.buffer[self.index];
        if (c == '"' or c == '\'') {
            const q = c; self.index += 1;
            var found = false;
            while (self.index < self.buffer.len) {
                if (self.buffer[self.index] == '\\' and self.index + 1 < self.buffer.len) self.index += 2
                else if (self.buffer[self.index] == q) { self.index += 1; found = true; break; }
                else self.index += 1;
            }
            if (!found) self.err("Unclosed string");
            return .{ .tok_type = .string, .text = self.buffer[start..self.index] };
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            self.index += 1;
            while (self.index < self.buffer.len and (std.ascii.isAlphanumeric(self.buffer[self.index]) or self.buffer[self.index] == '_')) self.index += 1;
            const text = self.buffer[start..self.index];
            if (std.mem.eql(u8, text, "func")) return .{ .tok_type = .kw_function, .text = text };
            if (std.mem.eql(u8, text, "end")) return .{ .tok_type = .kw_end, .text = text };
            if (std.mem.eql(u8, text, "return")) return .{ .tok_type = .kw_return, .text = text };
            if (std.mem.eql(u8, text, "for")) return .{ .tok_type = .kw_for, .text = text };
            if (std.mem.eql(u8, text, "while")) return .{ .tok_type = .kw_while, .text = text };
            if (std.mem.eql(u8, text, "if")) return .{ .tok_type = .kw_if, .text = text };
            if (std.mem.eql(u8, text, "elseif")) return .{ .tok_type = .kw_elseif, .text = text };
            if (std.mem.eql(u8, text, "else")) return .{ .tok_type = .kw_else, .text = text };
            if (std.mem.eql(u8, text, "then")) return .{ .tok_type = .kw_then, .text = text };
            if (std.mem.eql(u8, text, "do")) return .{ .tok_type = .kw_do, .text = text };
            if (std.mem.eql(u8, text, "break")) return .{ .tok_type = .kw_break, .text = text };
            if (std.mem.eql(u8, text, "true")) return .{ .tok_type = .kw_true, .text = text };
            if (std.mem.eql(u8, text, "false")) return .{ .tok_type = .kw_false, .text = text };
            if (std.mem.eql(u8, text, "import")) return .{ .tok_type = .kw_import, .text = text };
            if (std.mem.eql(u8, text, "as")) return .{ .tok_type = .kw_as, .text = text };
            if (std.mem.eql(u8, text, "and")) return .{ .tok_type = .kw_and, .text = text };
            if (std.mem.eql(u8, text, "or")) return .{ .tok_type = .kw_or, .text = text };
            if (std.mem.eql(u8, text, "not")) return .{ .tok_type = .kw_not, .text = text };
            if (std.mem.eql(u8, text, "nil")) return .{ .tok_type = .kw_nil, .text = text };
            if (std.mem.eql(u8, text, "in")) return .{ .tok_type = .kw_in, .text = text };
            if (std.mem.eql(u8, text, "try")) return .{ .tok_type = .kw_try, .text = text };
            if (std.mem.eql(u8, text, "except")) return .{ .tok_type = .kw_except, .text = text };
            if (std.mem.eql(u8, text, "export")) return .{ .tok_type = .kw_export, .text = text };
            if (std.mem.eql(u8, text, "private")) return .{ .tok_type = .kw_private, .text = text };
            if (std.mem.eql(u8, text, "class")) return .{ .tok_type = .kw_class, .text = text };
            return .{ .tok_type = .identifier, .text = text };
        }
        if (std.ascii.isDigit(c)) {
            var is_float = false; self.index += 1;
            while (self.index < self.buffer.len) {
                const tc = self.buffer[self.index];
                if (tc == '.') { if (is_float) break; is_float = true; self.index += 1; }
                else if (std.ascii.isDigit(tc)) self.index += 1
                else break;
            }
            return .{ .tok_type = if (is_float) .number_float else .number_int, .text = self.buffer[start..self.index] };
        }
        self.index += 1;
        switch (c) {
            '(' => { self.paren_depth += 1; return .{ .tok_type = .lparen, .text = self.buffer[start..self.index] }; },
            ')' => { if (self.paren_depth == 0) self.err("Unexpected ')'") else self.paren_depth -= 1; return .{ .tok_type = .rparen, .text = self.buffer[start..self.index] }; },
            '{' => { self.brace_depth += 1; return .{ .tok_type = .lbrace, .text = self.buffer[start..self.index] }; },
            '}' => { if (self.brace_depth == 0) self.err("Unexpected '}'") else self.brace_depth -= 1; return .{ .tok_type = .rbrace, .text = self.buffer[start..self.index] }; },
            '[' => { self.bracket_depth += 1; return .{ .tok_type = .lbracket, .text = self.buffer[start..self.index] }; },
            ']' => { if (self.bracket_depth == 0) self.err("Unexpected ']'") else self.bracket_depth -= 1; return .{ .tok_type = .rbracket, .text = self.buffer[start..self.index] }; },
            ',' => return .{ .tok_type = .comma, .text = self.buffer[start..self.index] },
            ':' => return .{ .tok_type = .colon, .text = self.buffer[start..self.index] },
            '.' => return .{ .tok_type = .period, .text = self.buffer[start..self.index] },
            '?' => { if (self.index < self.buffer.len and self.buffer[self.index] == '?') { self.index += 1; return .{ .tok_type = .coalesce, .text = self.buffer[start..self.index] }; } if (self.index < self.buffer.len and self.buffer[self.index] == '.') { self.index += 1; return .{ .tok_type = .question_period, .text = self.buffer[start..self.index] }; } return .{ .tok_type = .question, .text = self.buffer[start..self.index] }; },
            '+' => { if (self.index < self.buffer.len and self.buffer[self.index] == '=') { self.index += 1; return .{ .tok_type = .plus_eq, .text = self.buffer[start..self.index] }; } return .{ .tok_type = .plus, .text = self.buffer[start..self.index] }; },
            '-' => return .{ .tok_type = .minus, .text = self.buffer[start..self.index] },
            '*' => { if (self.index < self.buffer.len and self.buffer[self.index] == '*') { self.index += 1; return .{ .tok_type = .star_star, .text = self.buffer[start..self.index] }; } if (self.index < self.buffer.len and self.buffer[self.index] == '=') { self.index += 1; return .{ .tok_type = .star_eq, .text = self.buffer[start..self.index] }; } return .{ .tok_type = .star, .text = self.buffer[start..self.index] }; },
            '/' => return .{ .tok_type = .slash, .text = self.buffer[start..self.index] },
            '%' => return .{ .tok_type = .percent, .text = self.buffer[start..self.index] },
            '~' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .tilde_eq, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .eof, .text = self.buffer[start..self.index] };
            },
            '!' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return .{ .tok_type = .tilde_eq, .text = self.buffer[start..self.index] };
                }
                return .{ .tok_type = .eof, .text = self.buffer[start..self.index] };
            },
            '=' => { if (self.index < self.buffer.len and self.buffer[self.index] == '=') { self.index += 1; return .{ .tok_type = .eq_eq, .text = self.buffer[start..self.index] }; } return .{ .tok_type = .eq, .text = self.buffer[start..self.index] }; },
            '<' => { if (self.index < self.buffer.len and self.buffer[self.index] == '=') { self.index += 1; return .{ .tok_type = .le, .text = self.buffer[start..self.index] }; } return .{ .tok_type = .lt, .text = self.buffer[start..self.index] }; },
            '>' => { if (self.index < self.buffer.len and self.buffer[self.index] == '=') { self.index += 1; return .{ .tok_type = .ge, .text = self.buffer[start..self.index] }; } return .{ .tok_type = .gt, .text = self.buffer[start..self.index] }; },
            else => return .{ .tok_type = .eof, .text = self.buffer[start..self.index] },
        }
    }
    fn skipWS(self: *Tokenizer) void {
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == ' ' or c == '\r' or c == '\t') self.index += 1
            else if (c == '\n') { self.index += 1; self.line += 1; }
            else if (c == '-' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '-') {
                self.index += 2;
                if (self.index + 1 < self.buffer.len and self.buffer[self.index] == '[' and self.buffer[self.index + 1] == '[') {
                    self.index += 2;
                    while (self.index + 1 < self.buffer.len) {
                        if (self.buffer[self.index] == ']' and self.buffer[self.index + 1] == ']') { self.index += 2; break; }
                        if (self.buffer[self.index] == '\n') self.line += 1;
                        self.index += 1;
                    }
                } else while (self.index < self.buffer.len and self.buffer[self.index] != '\n') self.index += 1;
            } else if (c == '#' or (c == '/' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '/')) {
                while (self.index < self.buffer.len and self.buffer[self.index] != '\n') self.index += 1;
            } else break;
        }
    }
};

const ExParser = struct {
    alloc: std.mem.Allocator, tokr: Tokenizer, cur: Token, line: usize, src: []const u8,
    fn init(a: std.mem.Allocator, s: []const u8, buf: []const u8, l: usize) ExParser {
        var t = Tokenizer.init(s, buf, l); const c = t.next();
        return .{ .alloc = a, .tokr = t, .cur = c, .line = l, .src = s };
    }
    fn adv(self: *ExParser) void { self.cur = self.tokr.next(); }
    fn con(self: *ExParser, tt: TokenType) !void { if (self.cur.tok_type == tt) self.adv() else return errors.printExpectedError(self.src, self.line, @tagName(tt), @tagName(self.cur.tok_type)); }
    fn parse(self: *ExParser) !*AstNode { return try self.asgn(); }

    fn asgn(self: *ExParser) !*AstNode {
        const left = try self.logical();
        if (self.cur.tok_type == .colon and left.node_type == .var_ref and left.target == null) {
            try self.con(.colon);
            const type_name = self.cur.text;
            try self.con(.identifier);
            var full_type: []const u8 = type_name;
            if (self.cur.tok_type == .lbracket) {
                try self.con(.lbracket);
                const inner_name = self.cur.text;
                try self.con(.identifier);
                try self.con(.rbracket);
                full_type = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ type_name, inner_name });
            }
            if (self.cur.tok_type == .eq) {
                try self.con(.eq);
                const right = try self.asgn();
                const n = try self.alloc.create(AstNode);
                n.* = .{ .node_type = .assign, .line = self.line, .name = try self.alloc.dupe(u8, left.name), .extra = try self.alloc.dupe(u8, full_type) };
                n.args = std.ArrayList(*AstNode).init(self.alloc);
                try n.args.?.append(right);
                freeAstNode(self.alloc, left);
                return n;
            }
            left.extra = try self.alloc.dupe(u8, full_type);
            return left;
        }
        if (self.cur.tok_type == .eq) { self.con(.eq) catch {}; const right = try self.asgn(); const n = try self.alloc.create(AstNode); const t = left.target; const is_opt = left.is_optional; left.target = null; n.* = .{ .node_type = .assign, .line = self.line, .name = try self.alloc.dupe(u8, left.name), .target = t, .is_optional = is_opt }; n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(right); freeAstNode(self.alloc, left); return n; }
        if (self.cur.tok_type == .plus_eq) { self.con(.plus_eq) catch {}; const right = try self.asgn(); const n = try self.alloc.create(AstNode); const t = left.target; left.target = null; n.* = .{ .node_type = .aug_assign_add, .line = self.line, .name = try self.alloc.dupe(u8, left.name), .target = t }; n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(right); freeAstNode(self.alloc, left); return n; }
        if (self.cur.tok_type == .star_eq) { self.con(.star_eq) catch {}; const right = try self.asgn(); const n = try self.alloc.create(AstNode); const t = left.target; left.target = null; n.* = .{ .node_type = .aug_assign_mul, .line = self.line, .name = try self.alloc.dupe(u8, left.name), .target = t }; n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(right); freeAstNode(self.alloc, left); return n; }
        return left;
    }
    fn logical(self: *ExParser) anyerror!*AstNode {
        var expr = try self.coalesce();
        while (self.cur.tok_type == .kw_and or self.cur.tok_type == .kw_or) {
            const op = self.cur.tok_type; try self.con(op);
            const right = try self.coalesce();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = if (op == .kw_and) .and_op else .or_op, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn coalesce(self: *ExParser) anyerror!*AstNode {
        var expr = try self.unary();
        while (self.cur.tok_type == .coalesce) {
            try self.con(.coalesce);
            const right = try self.unary();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .coalesce, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn unary(self: *ExParser) anyerror!*AstNode {
        if (self.cur.tok_type == .kw_not) {
            try self.con(.kw_not);
            const op = try self.unary();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .eq, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc);
            const zero = try self.alloc.create(AstNode); zero.* = .{ .node_type = .val_int, .line = self.line, .val_int = 0 };
            try n.args.?.append(op); try n.args.?.append(zero); return n;
        }
        return try self.eq();
    }
    fn eq(self: *ExParser) anyerror!*AstNode {
        var expr = try self.cmp();
        while (self.cur.tok_type == .eq_eq or self.cur.tok_type == .tilde_eq) {
            const op = self.cur.tok_type; try self.con(op);
            const right = try self.cmp();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = if (op == .eq_eq) .eq else .ne, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn cmp(self: *ExParser) anyerror!*AstNode {
        var expr = try self.addsub();
        while (self.cur.tok_type == .lt or self.cur.tok_type == .gt or self.cur.tok_type == .le or self.cur.tok_type == .ge) {
            const op = self.cur.tok_type; try self.con(op);
            const right = try self.addsub();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = switch (op) { .lt => .lt, .gt => .gt, .le => .le, .ge => .ge, else => unreachable }, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn addsub(self: *ExParser) anyerror!*AstNode {
        var expr = try self.muldiv();
        while (self.cur.tok_type == .plus or self.cur.tok_type == .minus) {
            const op = self.cur.tok_type; try self.con(op);
            const right = try self.muldiv();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = if (op == .plus) .add else .sub, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn muldiv(self: *ExParser) anyerror!*AstNode {
        var expr = try self.pow();
        while (self.cur.tok_type == .star or self.cur.tok_type == .slash or self.cur.tok_type == .percent) {
            const op = self.cur.tok_type; try self.con(op);
            const right = try self.pow();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = if (op == .star) .mul else if (op == .slash) .div else .mod, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn pow(self: *ExParser) anyerror!*AstNode {
        var expr = try self.prim();
        while (self.cur.tok_type == .star_star) {
            try self.con(.star_star); const right = try self.pow();
            const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .pow, .line = self.line };
            n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(expr); try n.args.?.append(right); expr = n;
        }
        return expr;
    }
    fn prim(self: *ExParser) anyerror!*AstNode {
        const tok = self.cur;
        var node: *AstNode = undefined;
        if (tok.tok_type == .identifier and std.mem.eql(u8, tok.text, "raw")) {
            try self.con(.identifier); // 'raw'
            const type_tok = self.cur;
            try self.con(.identifier);
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
            try self.con(.lbracket);
            const size = try self.asgn();
            try self.con(.rbracket);
            const n = try self.alloc.create(AstNode);
            n.* = .{ .node_type = .call, .line = self.line, .name = try self.alloc.dupe(u8, type_name) };
            n.args = std.ArrayList(*AstNode).init(self.alloc);
            try n.args.?.append(size);
            return n;
        }
        switch (tok.tok_type) {
            .number_int => { try self.con(.number_int); const n = try self.alloc.create(AstNode); const r = try self.alloc.dupe(u8, tok.text); n.* = .{ .node_type = .val_int, .line = self.line, .val_int = try std.fmt.parseInt(i64, tok.text, 10), .val_string = r }; node = n; },
            .number_float => { try self.con(.number_float); const n = try self.alloc.create(AstNode); const r = try self.alloc.dupe(u8, tok.text); n.* = .{ .node_type = .val_float, .line = self.line, .val_float = try std.fmt.parseFloat(f64, tok.text), .val_string = r }; node = n; },
            .string => {
                try self.con(.string);
                const raw = tok.text[1 .. tok.text.len - 1];
                if (std.mem.indexOf(u8, raw, "{{")) |_| {
                    var parts = std.ArrayList(*AstNode).init(self.alloc);
                    var i: usize = 0;
                    var start: usize = 0;
                    while (i < raw.len) {
                        if (raw[i] == '\\' and i + 1 < raw.len) { i += 2; continue; }
                        if (i + 1 < raw.len and raw[i] == '{' and raw[i + 1] == '{') {
                            if (i > start) {
                                const lit = try unescapeString(self.alloc, raw[start..i]);
                                const ln = try self.alloc.create(AstNode);
                                ln.* = .{ .node_type = .val_string, .line = self.line, .val_string = lit };
                                try parts.append(ln);
                            }
                            i += 2; var depth: usize = 1;
                            const expr_start = i;
                            while (i < raw.len and depth > 0) {
                                if (raw[i] == '{') depth += 1;
                                if (raw[i] == '}') depth -= 1;
                                if (depth > 0) i += 1;
                            }
                            const expr_text = raw[expr_start..i];
                            var ep = ExParser.init(self.alloc, self.src, expr_text, self.line);
                            const expr_node = try ep.parse();
                            const sc = try self.alloc.create(AstNode);
                            sc.* = .{ .node_type = .call, .line = self.line, .name = try self.alloc.dupe(u8, "str") };
                            sc.args = std.ArrayList(*AstNode).init(self.alloc);
                            try sc.args.?.append(expr_node);
                            try parts.append(sc);
                            i += 1;
                            if (i < raw.len and raw[i] == '}') i += 1;
                            start = i;
                        } else { i += 1; }
                    }
                    if (start < raw.len) {
                        const lit = try unescapeString(self.alloc, raw[start..]);
                        const ln = try self.alloc.create(AstNode);
                        ln.* = .{ .node_type = .val_string, .line = self.line, .val_string = lit };
                        try parts.append(ln);
                    }
                    node = parts.items[0];
                    var j: usize = 1;
                    while (j < parts.items.len) : (j += 1) {
                        const add = try self.alloc.create(AstNode);
                        add.* = .{ .node_type = .add, .line = self.line };
                        add.args = std.ArrayList(*AstNode).init(self.alloc);
                        try add.args.?.append(node);
                        try add.args.?.append(parts.items[j]);
                        node = add;
                    }
                    parts.deinit();
                } else {
                    const n = try self.alloc.create(AstNode);
                    n.* = .{ .node_type = .val_string, .line = self.line, .val_string = try unescapeString(self.alloc, raw) };
                    node = n;
                }
            },
            .kw_true => { try self.con(.kw_true); const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .val_bool, .line = self.line, .val_int = 1 }; node = n; },
            .kw_false => { try self.con(.kw_false); const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .val_bool, .line = self.line, .val_int = 0 }; node = n; },
            .kw_nil => { try self.con(.kw_nil); const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .val_nil, .line = self.line }; node = n; },
            .identifier => {
                try self.con(.identifier);
                var fp = std.ArrayList(u8).init(self.alloc); defer fp.deinit();
                try fp.appendSlice(tok.text);
                while (self.cur.tok_type == .period or self.cur.tok_type == .lbracket) {
                    if (self.cur.tok_type == .period) { try fp.append('.'); self.adv(); if (self.cur.tok_type == .identifier) { try fp.appendSlice(self.cur.text); self.adv(); } else return error.InvalidExpression; }
                    else if (self.cur.tok_type == .lbracket) { try fp.append('['); self.adv(); while (self.cur.tok_type != .rbracket and self.cur.tok_type != .eof) { try fp.appendSlice(self.cur.text); self.adv(); } if (self.cur.tok_type == .rbracket) { try fp.append(']'); self.adv(); } }
                }
                if (self.cur.tok_type == .lparen) {
                    try self.con(.lparen); const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .call, .line = self.line, .name = try self.alloc.dupe(u8, fp.items) };
                    n.args = std.ArrayList(*AstNode).init(self.alloc);
                    while (self.cur.tok_type != .rparen and self.cur.tok_type != .eof) { const arg = try self.asgn(); try n.args.?.append(arg); if (self.cur.tok_type == .comma) try self.con(.comma); }
                    try self.con(.rparen); node = n;
                } else { const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .var_ref, .line = self.line, .name = try self.alloc.dupe(u8, fp.items) }; node = n; }
            },
            .lparen => { try self.con(.lparen); node = try self.asgn(); try self.con(.rparen); },
            .lbrace => { try self.con(.lbrace); const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .val_dict, .line = self.line }; n.args = std.ArrayList(*AstNode).init(self.alloc); while (self.cur.tok_type != .rbrace and self.cur.tok_type != .eof) { const k = try self.asgn(); try n.args.?.append(k); try self.con(.colon); const v = try self.asgn(); try n.args.?.append(v); if (self.cur.tok_type == .comma) try self.con(.comma); } try self.con(.rbrace); node = n; },
            .lbracket => { try self.con(.lbracket); const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .val_list, .line = self.line }; n.args = std.ArrayList(*AstNode).init(self.alloc); while (self.cur.tok_type != .rbracket and self.cur.tok_type != .eof) { const it = try self.asgn(); try n.args.?.append(it); if (self.cur.tok_type == .comma) try self.con(.comma); } try self.con(.rbracket); node = n; },
            .minus => { try self.con(.minus); var inner = try self.prim(); if (inner.node_type == .val_int) { inner.val_int = -inner.val_int; node = inner; } else if (inner.node_type == .val_float) { inner.val_float = -inner.val_float; node = inner; } else { const z = try self.alloc.create(AstNode); z.* = .{ .node_type = .val_int, .line = self.line, .val_int = 0 }; const n = try self.alloc.create(AstNode); n.* = .{ .node_type = .sub, .line = self.line }; n.args = std.ArrayList(*AstNode).init(self.alloc); try n.args.?.append(z); try n.args.?.append(inner); node = n; } },
            else => { errors.printSyntaxError(self.src, self.line, 0, "Unexpected token"); return error.InvalidExpression; },
        }
        while (self.cur.tok_type == .period or self.cur.tok_type == .question_period or self.cur.tok_type == .lbracket) {
            const is_opt = self.cur.tok_type == .question_period;
            if (self.cur.tok_type == .period or self.cur.tok_type == .question_period) {
                self.adv();
                if (self.cur.tok_type == .identifier) {
                    const pn = self.cur.text; self.adv();
                    if (self.cur.tok_type == .lparen) {
                        try self.con(.lparen); const cn = try self.alloc.create(AstNode); cn.* = .{ .node_type = .call, .line = self.line, .name = try self.alloc.dupe(u8, pn), .is_optional = is_opt };
                        cn.args = std.ArrayList(*AstNode).init(self.alloc);
                        while (self.cur.tok_type != .rparen and self.cur.tok_type != .eof) { const a = try self.asgn(); try cn.args.?.append(a); if (self.cur.tok_type == .comma) try self.con(.comma); }
                        try self.con(.rparen); cn.target = node; node = cn;
                    } else { const pn2 = try self.alloc.create(AstNode); pn2.* = .{ .node_type = .var_ref, .line = self.line, .name = try self.alloc.dupe(u8, pn), .target = node, .is_optional = is_opt }; node = pn2; }
                } else return error.InvalidExpression;
            } else if (self.cur.tok_type == .lbracket) { self.adv(); const idx = try self.asgn(); try self.con(.rbracket); const an = try self.alloc.create(AstNode); an.* = .{ .node_type = .call, .line = self.line, .name = try self.alloc.dupe(u8, "__getitem__") }; an.args = std.ArrayList(*AstNode).init(self.alloc); try an.args.?.append(idx); an.target = node; node = an; }
        }
        if (self.cur.tok_type == .question) { self.adv(); node.is_optional = true; }
        return node;
    }
};

fn trimLine(line: []const u8) []const u8 { return std.mem.trim(u8, line, " \r\n\t"); }

fn hasKw(line: []const u8, kw: []const u8) bool {
    const t = std.mem.trim(u8, line, " ");
    if (std.mem.startsWith(u8, t, kw)) {
        const after = t[kw.len..];
        return after.len == 0 or after[0] == ' ' or after[0] == '(';
    }
    return false;
}

fn parseBlock(allocator: std.mem.Allocator, source: []const u8, lines: []const []const u8, i: *usize, stop_at_elseif: bool) !std.ArrayList(*AstNode) {
    var block = std.ArrayList(*AstNode).init(allocator);
    var pending_decorators = std.ArrayList(*AstNode).init(allocator);
    errdefer {
        for (pending_decorators.items) |d| parser.freeAstNode(allocator, d);
        pending_decorators.deinit();
    }
    while (i.* < lines.len) {
        const raw = trimLine(lines[i.*]);
        if (raw.len == 0 or std.mem.startsWith(u8, raw, "#") or std.mem.startsWith(u8, raw, "//")) { i.* += 1; continue; }
        if (std.mem.eql(u8, raw, "end")) { i.* += 1; break; }
        if (stop_at_elseif and (hasKw(raw, "elseif") or std.mem.eql(u8, raw, "else"))) break;

        if (raw.len > 0 and raw[0] == '@') {
            const expr_str = std.mem.trim(u8, raw[1..], " ");
            var ep = ExParser.init(allocator, source, expr_str, i.* + 1);
            const expr_node = try ep.parse();
            try pending_decorators.append(expr_node);
            i.* += 1;
            continue;
        }

        if (hasKw(raw, "func")) {
            const sig = std.mem.trim(u8, raw["func".len..], " ");
            var it = std.mem.splitSequence(u8, sig, "(");
            const fname = std.mem.trim(u8, it.next().?, " ");
            const rest = it.next().?;
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse rest.len;
            const args_str = rest[0..close];
            const ret_str = std.mem.trim(u8, rest[close + 1 ..], " ");
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .func_def, .line = i.* + 1, .name = try allocator.dupe(u8, fname), .extra = if (ret_str.len > 0) try allocator.dupe(u8, ret_str) else null };
            node.args = std.ArrayList(*AstNode).init(allocator);
            var ait = std.mem.splitSequence(u8, args_str, ",");
            while (ait.next()) |arg| {
                const cleaned = std.mem.trim(u8, arg, " ");
                if (cleaned.len > 0) {
                    var eq_it = std.mem.splitSequence(u8, cleaned, "=");
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
                        if (second.len > 0) { arg_type = first; arg_name = second; }
                    }
                    var is_optional = false;
                    if (std.mem.endsWith(u8, arg_name, "?")) {
                        is_optional = true;
                        arg_name = std.mem.trim(u8, arg_name[0 .. arg_name.len - 1], " ");
                    }
                    const an = try allocator.create(AstNode);
                    an.* = .{ .node_type = .var_ref, .line = i.* + 1, .name = try allocator.dupe(u8, arg_name), .is_optional = is_optional };
                    if (arg_type) |t| an.extra = try allocator.dupe(u8, t);
                    if (default_str.len > 0) {
                        var ep = ExParser.init(allocator, source, default_str, i.* + 1);
                        const default_node = try ep.parse();
                        an.args = std.ArrayList(*AstNode).init(allocator);
                        try an.args.?.append(default_node);
                    }
                    try node.args.?.append(an);
                }
            }
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, false);
            if (pending_decorators.items.len > 0) {
                node.decorators = pending_decorators;
                pending_decorators = std.ArrayList(*AstNode).init(allocator);
            }
            try block.append(node);
            continue;
        }

        if (hasKw(raw, "if")) {
            const cond_str = std.mem.trim(u8, raw["if".len..], " ");
            var ct = cond_str;
            if (std.mem.endsWith(u8, ct, " then")) ct = std.mem.trim(u8, ct[0 .. ct.len - 5], " ");
            var ep = ExParser.init(allocator, source, ct, i.* + 1);
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .if_stmt, .line = i.* + 1 };
            node.args = std.ArrayList(*AstNode).init(allocator); try node.args.?.append(try ep.parse());
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, true);
            while (i.* < lines.len) {
                const nraw = trimLine(lines[i.*]);
                if (nraw.len == 0 or std.mem.startsWith(u8, nraw, "#") or std.mem.startsWith(u8, nraw, "//")) { i.* += 1; continue; }
                if (std.mem.eql(u8, nraw, "end")) { i.* += 1; break; }
                if (hasKw(nraw, "elseif")) {
                    const econd = std.mem.trim(u8, nraw["elseif".len..], " ");
                    var et = econd;
                    if (std.mem.endsWith(u8, et, " then")) et = std.mem.trim(u8, et[0 .. et.len - 5], " ");
                    var ep2 = ExParser.init(allocator, source, et, i.* + 1);
                    const en = try allocator.create(AstNode); en.* = .{ .node_type = .elif_stmt, .line = i.* + 1 };
                    en.args = std.ArrayList(*AstNode).init(allocator); try en.args.?.append(try ep2.parse());
                    i.* += 1;
                    en.subtree = try parseBlock(allocator, source, lines, i, true);
                    if (node.elifs == null) node.elifs = std.ArrayList(*AstNode).init(allocator);
                    try node.elifs.?.append(en);
                    continue;
                }
                if (hasKw(nraw, "else") or std.mem.eql(u8, nraw, "else")) {
                    i.* += 1;
                    node.else_tree = try parseBlock(allocator, source, lines, i, false);
                    continue;
                }
                break;
            }
            try block.append(node);
            continue;
        }

        if (hasKw(raw, "while")) {
            const cond_str = std.mem.trim(u8, raw["while".len..], " ");
            var ct = cond_str;
            if (std.mem.endsWith(u8, ct, " do")) ct = std.mem.trim(u8, ct[0 .. ct.len - 3], " ");
            var ep = ExParser.init(allocator, source, ct, i.* + 1);
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .while_loop, .line = i.* + 1 };
            node.args = std.ArrayList(*AstNode).init(allocator); try node.args.?.append(try ep.parse());
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, false);
            try block.append(node);
            continue;
        }

        if (hasKw(raw, "for")) {
            const body = std.mem.trim(u8, raw["for".len..], " ");
            var bt = body;
            if (std.mem.endsWith(u8, bt, " do")) bt = std.mem.trim(u8, bt[0 .. bt.len - 3], " ");
            var it2 = std.mem.splitSequence(u8, bt, " in ");
            const var_name = std.mem.trim(u8, it2.next().?, " ");
            const iter_expr = it2.next().?;
            var ep = ExParser.init(allocator, source, iter_expr, i.* + 1);
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .for_loop, .line = i.* + 1, .name = try allocator.dupe(u8, var_name) };
            node.args = std.ArrayList(*AstNode).init(allocator); try node.args.?.append(try ep.parse());
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, false);
            try block.append(node);
            continue;
        }

        if (hasKw(raw, "class")) {
            const body = std.mem.trim(u8, raw["class".len..], " ");
            var name = body;
            var base: ?[]const u8 = null;
            if (std.mem.containsAtLeast(u8, body, 1, "(")) { var it3 = std.mem.splitSequence(u8, body, "("); name = std.mem.trim(u8, it3.next().?, " "); const rest = it3.next().?; base = std.mem.trim(u8, rest[0 .. rest.len - 1], " "); }
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .class_def, .line = i.* + 1, .name = try allocator.dupe(u8, name), .extra = if (base) |b| try allocator.dupe(u8, b) else null };
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, false);
            if (pending_decorators.items.len > 0) {
                node.decorators = pending_decorators;
                pending_decorators = std.ArrayList(*AstNode).init(allocator);
            }
            try block.append(node);
            continue;
        }

        if (std.mem.eql(u8, raw, "try")) {
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .try_stmt, .line = i.* + 1 };
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, false);
            try block.append(node);
            continue;
        }

        if (hasKw(raw, "except")) {
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .except_stmt, .line = i.* + 1 };
            var exc_rest = std.mem.trim(u8, raw["except".len..], " \t");
            if (exc_rest.len > 0 and exc_rest[0] == '(') {
                exc_rest = std.mem.trim(u8, exc_rest[1..], " \t");
            }
            if (std.mem.endsWith(u8, exc_rest, ")")) exc_rest = std.mem.trim(u8, exc_rest[0 .. exc_rest.len - 1], " \t");
            if (std.mem.endsWith(u8, exc_rest, ":")) exc_rest = std.mem.trim(u8, exc_rest[0 .. exc_rest.len - 1], " \t");
            if (exc_rest.len > 0) {
                node.name = try allocator.dupe(u8, exc_rest);
            }
            i.* += 1;
            node.subtree = try parseBlock(allocator, source, lines, i, false);
            if (block.items.len > 0 and block.items[block.items.len - 1].node_type == .try_stmt) {
                block.items[block.items.len - 1].except_tree = node.subtree;
                if (node.name.len > 0) {
                    block.items[block.items.len - 1].name = node.name;
                    node.name = "";
                }
            }
            continue;
        }

        if (hasKw(raw, "return")) {
            const rest = std.mem.trim(u8, raw["return".len..], " ");
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .return_stmt, .line = i.* + 1 };
            node.args = std.ArrayList(*AstNode).init(allocator);
            if (rest.len > 0) { var ep = ExParser.init(allocator, source, rest, i.* + 1); try node.args.?.append(try ep.parse()); }
            else { const z = try allocator.create(AstNode); z.* = .{ .node_type = .val_int, .line = i.* + 1, .val_int = 0 }; try node.args.?.append(z); }
            try block.append(node);
            i.* += 1;
            continue;
        }

        if (std.mem.eql(u8, raw, "break")) { const n = try allocator.create(AstNode); n.* = .{ .node_type = .break_stmt, .line = i.* + 1 }; try block.append(n); i.* += 1; continue; }

        if (std.mem.eql(u8, raw, "pass")) { const n = try allocator.create(AstNode); n.* = .{ .node_type = .pass_stmt, .line = i.* + 1 }; try block.append(n); i.* += 1; continue; }

        if (hasKw(raw, "import")) {
            const body0 = std.mem.trim(u8, raw["import".len..], " ");
            var raw_path: []const u8 = body0; var alias: []const u8 = body0;
            if (std.mem.indexOf(u8, body0, " as ")) |as_idx| { raw_path = std.mem.trim(u8, body0[0..as_idx], " "); alias = std.mem.trim(u8, body0[as_idx + 4 ..], " "); }
            var path = raw_path;
            if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') path = path[1 .. path.len - 1];
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .import_stmt, .line = i.* + 1, .name = try allocator.dupe(u8, alias), .extra = try allocator.dupe(u8, path) };
            try block.append(node); i.* += 1; continue;
        }

        if (hasKw(raw, "export")) {
            const body = std.mem.trim(u8, raw["export".len..], " ");
            var source_part: []const u8 = ""; var func_name: []const u8 = body; var alias2: []const u8 = body;
            if (std.mem.indexOf(u8, body, " as ")) |as_idx| { const before_as = std.mem.trim(u8, body[0..as_idx], " "); alias2 = std.mem.trim(u8, body[as_idx + 4 ..], " "); if (std.mem.lastIndexOfScalar(u8, before_as, '.')) |dot_idx| { source_part = std.mem.trim(u8, before_as[0..dot_idx], " "); func_name = std.mem.trim(u8, before_as[dot_idx + 1 ..], " "); } else func_name = before_as; }
            else { if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot_idx| { source_part = std.mem.trim(u8, body[0..dot_idx], " "); func_name = std.mem.trim(u8, body[dot_idx + 1 ..], " "); alias2 = func_name; } }
            const node = try allocator.create(AstNode); node.* = .{ .node_type = .export_stmt, .line = i.* + 1, .name = try allocator.dupe(u8, func_name), .extra = if (source_part.len > 0) try allocator.dupe(u8, source_part) else null, .val_string = try allocator.dupe(u8, alias2) };
            try block.append(node); i.* += 1; continue;
        }

        var ep = ExParser.init(allocator, source, raw, i.* + 1);
        const expr_node = try ep.parse();
        try block.append(expr_node);
        i.* += 1;
    }
    if (pending_decorators.items.len > 0) {
        for (pending_decorators.items) |d| parser.freeAstNode(allocator, d);
    }
    pending_decorators.deinit();
    return block;
}

pub fn parseToAst(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(*AstNode) {
    var lines = std.ArrayList([]const u8).init(allocator);
    defer { for (lines.items) |l| allocator.free(l); lines.deinit(); }
    {
        var it = std.mem.splitSequence(u8, source, "\n");
        while (it.next()) |line| {
            var l = try allocator.dupe(u8, line);
            if (std.mem.indexOf(u8, l, "--")) |ci| { if (ci == 0 or l[ci - 1] != '[') l = l[0..ci]; }
            try lines.append(l);
        }
    }
    var i: usize = 0;
    return try parseBlock(allocator, source, lines.items, &i, false);
}
