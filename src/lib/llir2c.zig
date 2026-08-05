const std = @import("std");

// Translates the LLVM IR emitted by the builder into C, which is then compiled
// with the bundled zig (`zig cc -O2` fully optimizes C but refuses to optimize
// externally supplied .ll IR). The translation is goto-based: every basic
// block becomes a C label, every branch a `goto`, and every phi is assigned by
// its predecessors. Registers become C locals (`uint64_t Obj` for pointers,
// `long long`/`int`/`double`/`unsigned char` otherwise).

const LLVM_HEADER =
    \\#include <stdlib.h>
    \\#include <stdio.h>
    \\#include <string.h>
    \\#include <math.h>
    \\#include <stdint.h>
    \\typedef uint64_t Obj;
    \\#define TI(p) ((p)&1ULL)
    \\#define GI(p) ((long long)((p)>>1))
    \\#define MI(v) ((((uint64_t)(v))<<1)|1ULL)
    \\#define TF(p) (((p)&7ULL)==4)
    \\#define GF(p) ({uint64_t _b=(p);_b&=~7ULL;double _d;memcpy(&_d,&_b,8);_d;})
    \\#define MF(v) ({double _dv=(v);uint64_t _b;memcpy(&_b,&_dv,8);(Obj)(_b|4ULL);})
    \\#define TB(p) (((p)&3ULL)==2)
    \\#define GB(p) ((int)((p)>>2))
    \\#define MB(v) ((((uint64_t)((v)!=0))<<2)|2ULL)
    \\static inline long long D2I(double d){union{double d;long long i;}u;u.d=d;return u.i;}
    \\static inline double I2D(long long i){union{double d;long long i;}u;u.i=i;return u.d;}
    \\typedef struct { int32_t a,b,size,pad; Obj items; } IntListObj;
    \\extern int current_line,boblang_error_occurred,boblang_error_protect;
    \\extern int boblang_recursion_depth,boblang_tail_iterations;
    \\extern int boblang_cli_argc; extern char** boblang_cli_argv;
    \\extern Obj STR_CLASS,STR_BASES,STR_LENGTH,STR_NAME,STR_INIT,STR_CALL,STR_SPACE,STR_NEWLINE;
    \\extern Obj FUNC_PRINT,FUNC_INPUT,FUNC_INT,FUNC_FLOAT,FUNC_STR,FUNC_BOOL,FUNC_TYPE,FUNC_LEN,FUNC_RANGE,FUNC_MIN,FUNC_MAX,FUNC_CLAMP,FUNC_ASCII,FUNC_CHR,FUNC_LIST_SORT,FUNC_LIST_APPEND,FUNC_LIST_POP,FUNC_LIST_CLEAR,FUNC_LIST_REVERSE,FUNC_LIST_MAP,FUNC_LIST_FILTER,FUNC_LIST_REDUCE,FUNC_GET_ARGS;
    \\
;

const CType = enum { obj, i64, i32, i8, i1, f64, void_, intlist };

fn ByteContext(comptime V: type) type {
    _ = V;
    return struct {
        pub fn hash(_: @This(), s: []const u8) u64 {
            return std.hash.Wyhash.hash(0, s);
        }
        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };
}

const StrMap = std.HashMap([]const u8, void, ByteContext(void), 80);
const TypeMap = std.HashMap([]const u8, CType, ByteContext(CType), 80);

fn ctypeName(t: CType) []const u8 {
    return switch (t) {
        .obj => "Obj",
        .i64 => "long long",
        .i32 => "int",
        .i8 => "unsigned char",
        .i1 => "int",
        .f64 => "double",
        .void_ => "void",
        .intlist => "IntListObj",
    };
}

fn llvmCType(tok: []const u8) CType {
    if (std.mem.eql(u8, tok, "ptr")) return .obj;
    if (std.mem.eql(u8, tok, "i64")) return .i64;
    if (std.mem.eql(u8, tok, "i32")) return .i32;
    if (std.mem.eql(u8, tok, "i8")) return .i8;
    if (std.mem.eql(u8, tok, "i1")) return .i1;
    if (std.mem.eql(u8, tok, "double")) return .f64;
    if (std.mem.eql(u8, tok, "void")) return .void_;
    return .obj;
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    globals: StrMap = undefined,
    strings: StrMap = undefined,
    funcs: StrMap = undefined,
    allocas: StrMap = undefined,
    regtypes: TypeMap = undefined,
    params: StrMap = undefined,
};

fn gname(a: std.mem.Allocator, g: []const u8) ![]const u8 {
    var s = g;
    if (std.mem.startsWith(u8, s, "@")) s = s[1..];
    const n = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| n[i] = if (c == '.') '_' else c;
    return n;
}

fn sanitizeLabel(a: std.mem.Allocator, lbl: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    defer out.deinit();
    try out.append('L');
    for (lbl) |c| try out.append(if (c == '.') '_' else c);
    return out.toOwnedSlice();
}

// Returns the C expression for an LLVM operand (register, constant, or global).
fn operand(a: std.mem.Allocator, arg: []const u8, ctx: *const Ctx) ![]const u8 {
    const t = std.mem.trim(u8, arg, " \r");
    if (t.len == 0) return a.dupe(u8, "0");
    if (std.mem.eql(u8, t, "null")) return a.dupe(u8, "0");
    if (t[0] == '%') return a.dupe(u8, t[1..]);
    if (t[0] == '@') {
        const n = try gname(a, t);
        if (ctx.strings.contains(n) or ctx.funcs.contains(n)) {
            const res = try std.fmt.allocPrint(a, "(Obj)(uintptr_t){s}", .{n});
            a.free(n);
            return res;
        }
        return n;
    }
    if (std.mem.indexOfScalar(u8, t, ' ')) |sp| {
        const ty = t[0..sp];
        const val = std.mem.trim(u8, t[sp + 1 ..], " \r");
        if (std.mem.eql(u8, ty, "i1")) return a.dupe(u8, if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) "1" else "0");
        if (std.mem.eql(u8, ty, "ptr") and std.mem.eql(u8, val, "null")) return a.dupe(u8, "0");
        if (val.len > 0 and val[0] == '%') return a.dupe(u8, val[1..]);
        if (val.len > 0 and val[0] == '@') {
            const n = try gname(a, val);
            if (ctx.strings.contains(n) or ctx.funcs.contains(n)) {
                const res = try std.fmt.allocPrint(a, "(Obj)(uintptr_t){s}", .{n});
                a.free(n);
                return res;
            }
            return n;
        }
        if (std.mem.eql(u8, ty, "double")) {
            var s = val;
            if (std.mem.endsWith(u8, s, "e+00")) {
                s = s[0 .. s.len - 4];
            } else if (std.mem.endsWith(u8, s, "e-00")) {
                s = s[0 .. s.len - 4];
            }
            return a.dupe(u8, s);
        }
        return a.dupe(u8, val);
    }
    return a.dupe(u8, t);
}

fn emitStringConstant(a: std.mem.Allocator, out: anytype, name: []const u8, esc: []const u8) !void {
    var raw = std.ArrayList(u8).init(a);
    defer raw.deinit();
    var i: usize = 0;
    while (i < esc.len) : (i += 1) {
        if (esc[i] == '\\' and i + 2 < esc.len) {
            const byte = std.fmt.parseInt(u8, esc[i + 1 .. i + 3], 16) catch {
                try raw.append('\\');
                continue;
            };
            try raw.append(byte);
            i += 2;
        } else {
            try raw.append(esc[i]);
        }
    }
    if (raw.items.len > 0 and raw.items[raw.items.len - 1] == 0) _ = raw.pop();
    try out.writeAll("static const char ");
    try out.writeAll(name);
    try out.writeAll("[] = \"");
    for (raw.items) |b| {
        switch (b) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => if (b >= 32 and b < 127) {
                try out.writeByte(b);
            } else {
                try out.print("\\x{x:0>2}", .{b});
            },
        }
    }
    try out.writeAll("\";\n");
}

fn skipWord(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != ',' and s[i] != '\t') : (i += 1) {}
    while (i < s.len and (s[i] == ' ' or s[i] == ',' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn firstOperand(a: std.mem.Allocator, s: []const u8, ctx: *const Ctx) ![]const u8 {
    const rest = skipWord(s);
    return operand(a, std.mem.trim(u8, rest, " "), ctx);
}

fn twoOperands(a: std.mem.Allocator, s: []const u8, ctx: *const Ctx) !struct { []const u8, []const u8 } {
    var rest = skipWord(s); // opcode
    rest = skipWord(rest); // type
    const op1_end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    const op1 = try operand(a, std.mem.trim(u8, rest[0..op1_end], " "), ctx);
    var op2 = rest;
    if (op1_end < rest.len) op2 = std.mem.trim(u8, rest[op1_end + 1 ..], " ");
    return .{ op1, try operand(a, op2, ctx) };
}

fn icmpOperands(a: std.mem.Allocator, s: []const u8, ctx: *const Ctx) !struct { []const u8, []const u8 } {
    var rest = skipWord(s); // icmp
    rest = skipWord(rest); // predicate
    rest = skipWord(rest); // type
    const op1_end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    const op1 = try operand(a, std.mem.trim(u8, rest[0..op1_end], " "), ctx);
    var op2 = rest;
    if (op1_end < rest.len) op2 = std.mem.trim(u8, rest[op1_end + 1 ..], " ");
    return .{ op1, try operand(a, op2, ctx) };
}

fn castOperand(a: std.mem.Allocator, s: []const u8, ctx: *const Ctx) ![]const u8 {
    var rest = skipWord(s); // opcode
    rest = skipWord(rest); // source type
    const end = std.mem.indexOf(u8, rest, " to ") orelse rest.len;
    return operand(a, std.mem.trim(u8, rest[0..end], " "), ctx);
}

fn labelsOf(a: std.mem.Allocator, s: []const u8, out: anytype) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, s, search, "label %")) |p| {
        var end = p + 7;
        while (end < s.len and s[end] != ',' and s[end] != ' ') : (end += 1) {}
        const lbl = s[p + 7 .. end];
        try out.append(try a.dupe(u8, lbl));
        search = p + 7;
    }
}

const PhiEntry = struct { val: []const u8, pred: []const u8 };

const Phi = struct {
    result: []const u8,
    entries: std.ArrayList(PhiEntry),
};

const Block = struct {
    label: ?[]const u8,
    lines: std.ArrayList([]const u8),
};

fn parseFunction(a: std.mem.Allocator, body: []const u8) !struct {
    blocks: std.ArrayList(Block),
    allocas: StrMap,
    regtypes: TypeMap,
    phis: std.ArrayList(std.ArrayList(Phi)),
} {
    var blocks = std.ArrayList(Block).init(a);
    var cur_label: ?[]const u8 = null;
    var cur_lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \r");
        if (s.len == 0 or s[0] == ';') continue;
        const is_label = s[s.len - 1] == ':' and !std.mem.startsWith(u8, s, "%");
        if (is_label) {
            try blocks.append(.{ .label = cur_label, .lines = cur_lines });
            cur_label = try a.dupe(u8, s[0 .. s.len - 1]);
            cur_lines = std.ArrayList([]const u8).init(a);
        } else {
            try cur_lines.append(try a.dupe(u8, s));
        }
    }
    try blocks.append(.{ .label = cur_label, .lines = cur_lines });

    var allocas = StrMap.init(a);
    var regtypes = TypeMap.init(a);
    var phis = std.ArrayList(std.ArrayList(Phi)).init(a);
    for (blocks.items) |_| try phis.append(std.ArrayList(Phi).init(a));

    for (blocks.items, 0..) |blk, bi| {
        for (blk.lines.items) |line| {
            if (line[0] == '%') {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const reg = std.mem.trim(u8, line[1..eq], " ");
                const rest = std.mem.trim(u8, line[eq + 1 ..], " ");
                if (std.mem.startsWith(u8, rest, "alloca")) {
                    try allocas.put(reg, {});
                    var t2 = std.mem.tokenizeAny(u8, skipWord(rest), " ,");
                    const ty = t2.next() orelse "ptr";
                    try regtypes.put(reg, llvmCType(ty));
                } else if (std.mem.startsWith(u8, rest, "load {")) {
                    try regtypes.put(reg, .intlist);
                } else if (std.mem.startsWith(u8, rest, "extractvalue")) {
                    try regtypes.put(reg, .i32);
                } else if (std.mem.startsWith(u8, rest, "load")) {
                    var t2 = std.mem.tokenizeAny(u8, skipWord(rest), " ,");
                    const ty = t2.next() orelse "ptr";
                    try regtypes.put(reg, llvmCType(ty));
                } else if (std.mem.startsWith(u8, rest, "call")) {
                    var t2 = std.mem.tokenizeAny(u8, skipWord(rest), " ,");
                    const ty = t2.next() orelse "ptr";
                    try regtypes.put(reg, llvmCType(ty));
                } else if (std.mem.startsWith(u8, rest, "phi")) {
                    var t2 = std.mem.tokenizeAny(u8, skipWord(rest), " ,");
                    const ty = t2.next() orelse "ptr";
                    try regtypes.put(reg, llvmCType(ty));
                    var p = Phi{ .result = try a.dupe(u8, reg), .entries = std.ArrayList(PhiEntry).init(a) };
                    var it2 = std.mem.splitSequence(u8, rest, "[");
                    _ = it2.next();
                    while (it2.next()) |chunk| {
                        const close = std.mem.indexOfScalar(u8, chunk, ']') orelse continue;
                        const inner = chunk[0..close];
                        const comma = std.mem.indexOfScalar(u8, inner, ',') orelse continue;
                        const val = std.mem.trim(u8, inner[0..comma], " ");
                        var pred = std.mem.trim(u8, inner[comma + 1 ..], " ");
                        if (std.mem.startsWith(u8, pred, "%")) pred = pred[1..];
                        try p.entries.append(.{ .val = try a.dupe(u8, val), .pred = try a.dupe(u8, pred) });
                    }
                    try phis.items[bi].append(p);
                } else {
                    try regtypes.put(reg, try guessResultType(rest));
                }
            }
        }
    }
    return .{ .blocks = blocks, .allocas = allocas, .regtypes = regtypes, .phis = phis };
}

fn guessResultType(rest: []const u8) !CType {
    var it = std.mem.tokenizeAny(u8, rest, " ");
    const op = it.next() orelse return .obj;
    if (std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "mul") or
        std.mem.eql(u8, op, "sdiv") or std.mem.eql(u8, op, "srem") or std.mem.eql(u8, op, "and") or
        std.mem.eql(u8, op, "or") or std.mem.eql(u8, op, "xor") or std.mem.eql(u8, op, "shl") or
        std.mem.eql(u8, op, "ashr") or std.mem.eql(u8, op, "lshr"))
    {
        const ty = it.next() orelse return .i64;
        return llvmCType(ty);
    }
    if (std.mem.eql(u8, op, "fadd") or std.mem.eql(u8, op, "fsub") or std.mem.eql(u8, op, "fmul") or std.mem.eql(u8, op, "fdiv"))
        return .f64;
    if (std.mem.eql(u8, op, "icmp") or std.mem.eql(u8, op, "fcmp") or std.mem.eql(u8, op, "select"))
        return .i1;
    if (std.mem.eql(u8, op, "zext") or std.mem.eql(u8, op, "sext")) return .i64;
    if (std.mem.eql(u8, op, "trunc")) {
        if (std.mem.indexOf(u8, rest, " to ")) |p| return llvmCType(std.mem.trim(u8, rest[p + 4 ..], " "));
        return .i8;
    }
    if (std.mem.eql(u8, op, "sitofp")) return .f64;
    if (std.mem.eql(u8, op, "fptosi")) return .i64;
    if (std.mem.eql(u8, op, "bitcast")) {
        if (std.mem.indexOf(u8, rest, " to ")) |p| return llvmCType(std.mem.trim(u8, rest[p + 4 ..], " "));
        return .i64;
    }
    if (std.mem.eql(u8, op, "inttoptr")) return .obj;
    if (std.mem.eql(u8, op, "ptrtoint")) return .i64;
    if (std.mem.eql(u8, op, "getelementptr")) return .obj;
    if (std.mem.eql(u8, op, "load")) {
        const ty = it.next() orelse return .obj;
        if (ty[0] == '{') return .intlist;
        return llvmCType(ty);
    }
    return .obj;
}

fn loadStorePtr(a: std.mem.Allocator, s: []const u8, ctx: *const Ctx) ![]const u8 {
    var ptr_str: []const u8 = undefined;
    if (s[0] == '{') {
        const close = std.mem.indexOfScalar(u8, s, '}') orelse return a.dupe(u8, "0");
        ptr_str = std.mem.trim(u8, s[close + 1 ..], " ");
        if (ptr_str.len > 0 and ptr_str[0] == ',') ptr_str = std.mem.trim(u8, ptr_str[1..], " ");
    } else {
        const comma = std.mem.indexOfScalar(u8, s, ',') orelse return a.dupe(u8, "0");
        ptr_str = std.mem.trim(u8, s[comma + 1 ..], " ");
    }
    if (!std.mem.startsWith(u8, ptr_str, "ptr ")) return a.dupe(u8, "0");
    const p = std.mem.trim(u8, ptr_str["ptr ".len..], " ");
    const end = std.mem.indexOfScalar(u8, p, ',') orelse p.len;
    return operand(a, std.mem.trim(u8, p[0..end], " "), ctx);
}

fn emitInstruction(a: std.mem.Allocator, out: anytype, line: []const u8, ctx: *const Ctx) !void {
    if (line.len == 0 or line[0] == ';') return;
    var result: ?[]const u8 = null;
    var rest = line;
    if (line[0] == '%') {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
        result = std.mem.trim(u8, line[1..eq], " ");
        rest = std.mem.trim(u8, line[eq + 1 ..], " ");
    }
    const r = result;

    if (std.mem.startsWith(u8, rest, "alloca")) return;
    if (std.mem.startsWith(u8, rest, "phi")) return;

    if (std.mem.startsWith(u8, rest, "store")) {
        var s = rest;
        if (std.mem.startsWith(u8, s, "store volatile")) {
            s = s["store volatile".len..];
        } else {
            s = s["store".len..];
        }
        s = std.mem.trim(u8, s, " ");
        const ty_end = std.mem.indexOfScalar(u8, s, ' ') orelse return;
        const ty_tok = s[0..ty_end];
        const val = std.mem.trim(u8, s[ty_end + 1 ..], " ");
        const val_end = std.mem.indexOfScalar(u8, val, ',') orelse val.len;
        const val_tok = std.mem.trim(u8, val[0..val_end], " ");
        const pe = try loadStorePtr(a, s, ctx);
        defer a.free(pe);
        const ve = try operand(a, val_tok, ctx);
        defer a.free(ve);

        if (ctx.allocas.contains(pe)) {
            try out.print("  {s} = {s};\n", .{ pe, ve });
            return;
        }
        if (ctx.globals.contains(pe)) {
            try out.print("  {s} = {s};\n", .{ pe, ve });
            return;
        }
        try out.print("  *({s}*)(uintptr_t)({s}) = ({s})({s});\n", .{ ctypeName(llvmCType(ty_tok)), pe, ctypeName(llvmCType(ty_tok)), ve });
        return;
    }

    if (std.mem.startsWith(u8, rest, "load")) {
        var s = rest;
        if (std.mem.startsWith(u8, s, "load volatile")) {
            s = s["load volatile".len..];
        } else {
            s = s["load".len..];
        }
        s = std.mem.trim(u8, s, " ");
        const pe = try loadStorePtr(a, s, ctx);
        defer a.free(pe);
        if (s[0] == '{') {
            try out.print("  {s} = *(IntListObj*)(uintptr_t)({s});\n", .{ r.?, pe });
            return;
        }
        const ty_end = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
        const ty_tok = std.mem.trim(u8, s[0..ty_end], " ");
        if (ctx.allocas.contains(pe)) {
            try out.print("  {s} = {s};\n", .{ r.?, pe });
            return;
        }
        if (ctx.globals.contains(pe)) {
            try out.print("  {s} = {s};\n", .{ r.?, pe });
            return;
        }
        try out.print("  {s} = *({s}*)(uintptr_t)({s});\n", .{ r.?, ctypeName(llvmCType(ty_tok)), pe });
        return;
    }

    if (std.mem.startsWith(u8, rest, "getelementptr")) {
        const s = skipWord(rest);
        const elt = std.mem.trim(u8, s, " ");
        const elt_end = std.mem.indexOfScalar(u8, elt, ',') orelse return;
        const elt_tok = std.mem.trim(u8, elt[0..elt_end], " ");
        const after_elt = std.mem.trim(u8, elt[elt_end + 1 ..], " ");
        const base_str = std.mem.trim(u8, after_elt, " ");
        if (!std.mem.startsWith(u8, base_str, "ptr ")) return;
        const base_operand_str = std.mem.trim(u8, base_str["ptr ".len..], " ");
        const base_end = std.mem.indexOfScalar(u8, base_operand_str, ',') orelse base_operand_str.len;
        const base_tok = std.mem.trim(u8, base_operand_str[0..base_end], " ");
        const idx_part = std.mem.trim(u8, base_operand_str[base_end + 1 ..], " ");
        // idx_part: "i64 %x"
        const idx = std.mem.trim(u8, idx_part, " ");
        const idx_op = try operand(a, idx, ctx);
        defer a.free(idx_op);
        const base = try operand(a, base_tok, ctx);
        defer a.free(base);
        const scale: []const u8 = if (std.mem.eql(u8, elt_tok, "i64") or std.mem.eql(u8, elt_tok, "double") or std.mem.eql(u8, elt_tok, "ptr")) "*8" else "";
        try out.print("  {s} = (Obj)(({s}) + (uint64_t)({s}){s});\n", .{ r.?, base, idx_op, scale });
        return;
    }

    if (std.mem.startsWith(u8, rest, "inttoptr")) {
        const v = try castOperand(a, rest, ctx);
        defer a.free(v);
        try out.print("  {s} = (Obj)(uint64_t)({s});\n", .{ r.?, v });
        return;
    }
    if (std.mem.startsWith(u8, rest, "ptrtoint")) {
        const v = try castOperand(a, rest, ctx);
        defer a.free(v);
        try out.print("  {s} = (long long)({s});\n", .{ r.?, v });
        return;
    }
    if (std.mem.startsWith(u8, rest, "bitcast")) {
        const s = skipWord(rest);
        const frm = std.mem.trim(u8, s, " ");
        const frm_end = std.mem.indexOfScalar(u8, frm, ' ') orelse return;
        const frm_tok = frm[0..frm_end];
        const val = std.mem.trim(u8, frm[frm_end + 1 ..], " ");
        const val_end = std.mem.indexOf(u8, val, " to ") orelse return;
        const val_tok = std.mem.trim(u8, val[0..val_end], " ");
        const to_tok = std.mem.trim(u8, val[val_end + 4 ..], " ");
        const ve = try operand(a, val_tok, ctx);
        defer a.free(ve);
        if (std.mem.eql(u8, frm_tok, "double") and std.mem.eql(u8, to_tok, "i64")) {
            try out.print("  {s} = D2I({s});\n", .{ r.?, ve });
        } else if (std.mem.eql(u8, frm_tok, "i64") and std.mem.eql(u8, to_tok, "double")) {
            try out.print("  {s} = I2D({s});\n", .{ r.?, ve });
        } else {
            try out.print("  {s} = (Obj)({s});\n", .{ r.?, ve });
        }
        return;
    }
    if (std.mem.startsWith(u8, rest, "icmp")) {
        const after_icmp = std.mem.trim(u8, rest["icmp".len..], " ");
        const pred_end = std.mem.indexOfScalar(u8, after_icmp, ' ') orelse return;
        const pred = after_icmp[0..pred_end];
        const cop: []const u8 = if (std.mem.eql(u8, pred, "eq")) "==" else if (std.mem.eql(u8, pred, "ne")) "!=" else if (std.mem.eql(u8, pred, "slt")) "<" else if (std.mem.eql(u8, pred, "sgt")) ">" else if (std.mem.eql(u8, pred, "sle")) "<=" else if (std.mem.eql(u8, pred, "sge")) ">=" else return;
        const ops = try icmpOperands(a, rest, ctx);
        defer a.free(ops[0]);
        defer a.free(ops[1]);
        try out.print("  {s} = ({s} {s} {s});\n", .{ r.?, ops[0], cop, ops[1] });
        return;
    }
    if (std.mem.startsWith(u8, rest, "extractvalue")) {
        const pi = std.mem.indexOfScalar(u8, rest, '%') orelse return;
        const reg_end = std.mem.indexOfScalar(u8, rest[pi + 1 ..], ',') orelse return;
        const reg = rest[pi + 1 .. pi + 1 + reg_end];
        const idx = std.mem.trim(u8, rest[pi + 1 + reg_end + 1 ..], " ");
        const field = if (std.mem.eql(u8, idx, "2")) "size" else if (std.mem.eql(u8, idx, "4")) "items" else "pad";
        try out.print("  {s} = {s}.{s};\n", .{ r.?, reg, field });
        return;
    }
    if (std.mem.startsWith(u8, rest, "select")) {
        // select i1 %c, TYPE %a, TYPE %b
        var s = skipWord(rest);
        s = skipWord(s); // i1
        const c_end = std.mem.indexOfScalar(u8, s, ',') orelse return;
        const c = try operand(a, std.mem.trim(u8, s[0..c_end], " "), ctx);
        defer a.free(c);
        var rest2 = std.mem.trim(u8, s[c_end + 1 ..], " ");
        rest2 = skipWord(rest2); // type of %a
        const a_end = std.mem.indexOfScalar(u8, rest2, ',') orelse return;
        const av = try operand(a, std.mem.trim(u8, rest2[0..a_end], " "), ctx);
        defer a.free(av);
        var rest3 = std.mem.trim(u8, rest2[a_end + 1 ..], " ");
        rest3 = skipWord(rest3); // type of %b
        const bv = try operand(a, rest3, ctx);
        defer a.free(bv);
        try out.print("  {s} = {s} ? {s} : {s};\n", .{ r.?, c, av, bv });
        return;
    }
    if (std.mem.startsWith(u8, rest, "call")) {
        const ret = tokenAfter(rest, "call") orelse return;
        const at = std.mem.indexOfScalar(u8, rest, '@') orelse return;
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return;
        const fn_name = rest[at + 1 .. paren];
        const args_str = rest[paren + 1 .. std.mem.lastIndexOfScalar(u8, rest, ')') orelse rest.len];

        var args = std.ArrayList([]const u8).init(a);
        defer {
            for (args.items) |x| a.free(x);
            args.deinit();
        }
        if (std.mem.trim(u8, args_str, " ").len > 0) {
            var it = std.mem.splitScalar(u8, args_str, ',');
            while (it.next()) |arg| try args.append(try operand(a, std.mem.trim(u8, arg, " "), ctx));
        }
        const fname = try gname(a, fn_name);
        defer a.free(fname);
        const is_slot = std.mem.eql(u8, fname, "boblang_gc_register_slot");
        const is_pow = std.mem.eql(u8, fname, "llvm_pow_f64");
        var call = std.ArrayList(u8).init(a);
        defer call.deinit();
        const cw = call.writer();
        if (is_pow) try cw.writeAll("pow(") else try cw.print("{s}(", .{fname});
        for (args.items, 0..) |arg, i| {
            if (i > 0) try cw.writeAll(", ");
            if (is_slot) try cw.print("(Obj*)&{s}", .{arg}) else try cw.writeAll(arg);
        }
        try cw.writeByte(')');
        if (std.mem.eql(u8, ret, "void")) {
            try out.print("  {s};\n", .{call.items});
        } else {
            try out.print("  {s} = {s};\n", .{ r.?, call.items });
        }
        return;
    }
    if (std.mem.startsWith(u8, rest, "br")) {
        if (std.mem.indexOf(u8, rest, "i1")) |_| {
            var s = skipWord(rest); // br
            s = skipWord(s); // i1
            const c_end = std.mem.indexOfScalar(u8, s, ',') orelse return;
            const c = try operand(a, std.mem.trim(u8, s[0..c_end], " "), ctx);
            defer a.free(c);
            var labels = std.ArrayList([]const u8).init(a);
            defer {
                for (labels.items) |x| a.free(x);
                labels.deinit();
            }
            try labelsOf(a, s, &labels);
            if (labels.items.len < 2) return;
            const la = try sanitizeLabel(a, labels.items[0]);
            defer a.free(la);
            const lb = try sanitizeLabel(a, labels.items[1]);
            defer a.free(lb);
            try out.print("  if ({s}) goto {s}; goto {s};\n", .{ c, la, lb });
        } else {
            var labels = std.ArrayList([]const u8).init(a);
            defer {
                for (labels.items) |x| a.free(x);
                labels.deinit();
            }
            try labelsOf(a, rest, &labels);
            if (labels.items.len < 1) return;
            const la = try sanitizeLabel(a, labels.items[0]);
            defer a.free(la);
            try out.print("  goto {s};\n", .{la});
        }
        return;
    }
    if (std.mem.startsWith(u8, rest, "ret")) {
        const after = std.mem.trim(u8, rest["ret".len..], " ");
        if (std.mem.eql(u8, after, "void")) {
            try out.writeAll("  return;\n");
        } else {
            const v = try operand(a, after, ctx);
            defer a.free(v);
            try out.print("  return {s};\n", .{v});
        }
        return;
    }
    // binary arithmetic
    const bin = [_][]const u8{ "add", "sub", "mul", "sdiv", "srem", "and", "or", "xor", "shl", "ashr", "lshr", "fadd", "fsub", "fmul", "fdiv" };
    const binop = [_][]const u8{ "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>", ">>", "+", "-", "*", "/" };
    inline for (bin, binop) |op, cop| {
        if (std.mem.startsWith(u8, rest, op ++ " ")) {
            const ops = try twoOperands(a, rest, ctx);
            defer a.free(ops[0]);
            defer a.free(ops[1]);
            try out.print("  {s} = ({s}) {s} ({s});\n", .{ r.?, ops[0], cop, ops[1] });
            return;
        }
    }
    if (std.mem.startsWith(u8, rest, "zext") or std.mem.startsWith(u8, rest, "sext")) {
        const v = try castOperand(a, rest, ctx);
        defer a.free(v);
        try out.print("  {s} = (long long)(unsigned long long)({s});\n", .{ r.?, v });
        return;
    }
    if (std.mem.startsWith(u8, rest, "trunc")) {
        const to = if (std.mem.indexOf(u8, rest, " to ")) |p| std.mem.trim(u8, rest[p + 4 ..], " ") else "i8";
        const v = try castOperand(a, rest, ctx);
        defer a.free(v);
        try out.print("  {s} = ({s})({s});\n", .{ r.?, ctypeName(llvmCType(to)), v });
        return;
    }
    if (std.mem.startsWith(u8, rest, "sitofp")) {
        const v = try castOperand(a, rest, ctx);
        defer a.free(v);
        try out.print("  {s} = (double)({s});\n", .{ r.?, v });
        return;
    }
    if (std.mem.startsWith(u8, rest, "fptosi")) {
        const v = try castOperand(a, rest, ctx);
        defer a.free(v);
        try out.print("  {s} = (long long)({s});\n", .{ r.?, v });
        return;
    }
    try out.print("  /* UNHANDLED: {s} */\n", .{line});
}

fn tokenAfter(s: []const u8, kw: []const u8) ?[]const u8 {
    const p = std.mem.indexOf(u8, s, kw) orelse return null;
    const after = std.mem.trim(u8, s[p + kw.len ..], " ");
    var i: usize = 0;
    while (i < after.len and after[i] != ',' and after[i] != ' ' and after[i] != ';') : (i += 1) {}
    if (i == 0) return null;
    return after[0..i];
}

pub fn translate(a: std.mem.Allocator, ir_source: []const u8, out: anytype) !void {
    var ctx = Ctx{
        .allocator = a,
        .globals = StrMap.init(a),
        .strings = StrMap.init(a),
        .funcs = StrMap.init(a),
        .allocas = StrMap.init(a),
        .regtypes = TypeMap.init(a),
        .params = StrMap.init(a),
    };
    defer {
        ctx.globals.deinit();
        ctx.strings.deinit();
        ctx.funcs.deinit();
    }

    try out.writeAll(LLVM_HEADER);
    var declare_it = std.mem.splitSequence(u8, ir_source, "declare ");
    _ = declare_it.next();
    while (declare_it.next()) |chunk| {
        const line = chunk[0 .. std.mem.indexOfScalar(u8, chunk, '\n') orelse chunk.len];
        if (std.mem.indexOfScalar(u8, line, '@')) |at| {
            const paren = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            const ret = std.mem.trim(u8, line[0..at], " ");
            const name = std.mem.trim(u8, line[at + 1 .. paren], " ");
            const params = line[paren + 1 .. std.mem.lastIndexOfScalar(u8, line, ')') orelse line.len];
            const gn = try gname(a, name);
            try ctx.globals.put(gn, {});
            var is_var = false;
            var ps = std.ArrayList([]const u8).init(a);
            defer {
                for (ps.items) |x| a.free(x);
                ps.deinit();
            }
            var pit = std.mem.splitScalar(u8, params, ',');
            while (pit.next()) |p| {
                const pt = std.mem.trim(u8, p, " ");
                if (std.mem.eql(u8, pt, "...")) {
                    is_var = true;
                    continue;
                }
                if (pt.len == 0) continue;
                var t2 = std.mem.tokenizeAny(u8, pt, " ");
                const ty = t2.next() orelse continue;
                try ps.append(try a.dupe(u8, ctypeName(llvmCType(ty))));
            }
            try out.writeAll("extern ");
            try out.writeAll(ctypeName(llvmCType(ret)));
            try out.writeByte(' ');
            try out.writeAll(gn);
            try out.writeByte('(');
            if (std.mem.eql(u8, gn, "boblang_gc_register_slot")) {
                try out.writeAll("Obj*");
                try out.writeAll(");\n");
                continue;
            }
            for (ps.items, 0..) |p, i| {
                if (i > 0) try out.writeAll(", ");
                try out.writeAll(p);
            }
            if (is_var) try out.writeAll(", ...");
            try out.writeAll(");\n");
        }
    }

    const FnSig = struct { name: []const u8, ret: []const u8, params: []const u8 };
    var func_names = std.ArrayList(FnSig).init(a);
    defer {
        for (func_names.items) |f| {
            a.free(f.name);
            a.free(f.ret);
            a.free(f.params);
        }
        func_names.deinit();
    }
    var flines = std.mem.splitScalar(u8, ir_source, '\n');
    while (flines.next()) |line| {
        if (std.mem.indexOf(u8, line, "= external global")) |p| {
            const at = std.mem.lastIndexOfScalar(u8, line[0..p], '@') orelse continue;
            const after = line[at + 1 ..];
            const name = after[0 .. std.mem.indexOfScalar(u8, after, ' ') orelse after.len];
            const gn = try gname(a, name);
            try ctx.globals.put(gn, {});
        } else if (std.mem.indexOf(u8, line, "private unnamed_addr constant")) |p| {
            const at = std.mem.lastIndexOfScalar(u8, line[0..p], '@') orelse continue;
            const name = line[at + 1 .. std.mem.indexOfScalar(u8, line, ' ') orelse continue];
            const quote = std.mem.indexOf(u8, line, "c\"") orelse continue;
            const end = std.mem.indexOfScalarPos(u8, line, quote + 2, '"') orelse continue;
            const esc = line[quote + 2 .. end];
            const gn = try gname(a, name);
            try ctx.strings.put(gn, {});
            try ctx.globals.put(gn, {});
            try emitStringConstant(a, out, gn, esc);
        } else if (std.mem.indexOf(u8, line, "= global ptr null")) |p| {
            const at = std.mem.lastIndexOfScalar(u8, line[0..p], '@') orelse continue;
            var s = line[at + 1 ..];
            const name = if (std.mem.indexOfScalar(u8, s, ' ')) |sp| s[0..sp] else s;
            const gn = try gname(a, name);
            try ctx.globals.put(gn, {});
            try out.print("Obj {s} = 0;\n", .{gn});
        } else if (std.mem.startsWith(u8, line, "define ")) {
            const at = std.mem.indexOfScalar(u8, line, '@') orelse continue;
            const paren = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            const pclose = std.mem.indexOfScalar(u8, line[paren + 1 ..], ')') orelse 0;
            const gn = try gname(a, line[at + 1 .. paren]);
            try func_names.append(.{
                .name = gn,
                .ret = try a.dupe(u8, std.mem.trim(u8, line[0..at], " ")),
                .params = try a.dupe(u8, line[paren + 1 .. paren + 1 + pclose]),
            });
            try ctx.funcs.put(gn, {});
        }
    }
    for (func_names.items) |fs| {
        if (std.mem.eql(u8, fs.name, "main")) continue;
        var pdecl = std.ArrayList([]const u8).init(a);
        defer {
            for (pdecl.items) |x| a.free(x);
            pdecl.deinit();
        }
        var pit = std.mem.splitScalar(u8, fs.params, ',');
        while (pit.next()) |p| {
            const pt = std.mem.trim(u8, p, " ");
            if (pt.len == 0) continue;
            var t2 = std.mem.tokenizeAny(u8, pt, " ");
            const ty = t2.next() orelse continue;
            try pdecl.append(try a.dupe(u8, ctypeName(llvmCType(ty))));
        }
        try out.print("extern {s} {s}(", .{ ctypeName(llvmCType(fs.ret)), fs.name });
        for (pdecl.items, 0..) |pd, i| {
            if (i > 0) try out.writeAll(", ");
            try out.writeAll(pd);
        }
        try out.writeAll(");\n");
    }

    // translate each function
    var fit = std.mem.splitSequence(u8, ir_source, "define ");
    _ = fit.next();
    while (fit.next()) |chunk| {
        const at = std.mem.indexOfScalar(u8, chunk, '@') orelse continue;
        const paren = std.mem.indexOfScalar(u8, chunk, '(') orelse continue;
        const ret = std.mem.trim(u8, chunk[0..at], " ");
        const fname = chunk[at + 1 .. paren];
        const body_start = std.mem.indexOfScalar(u8, chunk, '{') orelse continue;
        const body = chunk[body_start + 1 ..];
        const gn = try gname(a, fname);
        defer a.free(gn);

        var parsed = try parseFunction(a, body);
        defer {
            for (parsed.blocks.items) |*b| {
                if (b.label) |l| a.free(l);
                for (b.lines.items) |x| a.free(x);
                b.lines.deinit();
            }
            parsed.blocks.deinit();
            for (parsed.phis.items) |*plist| {
                for (plist.items) |*phi| {
                    a.free(phi.result);
                    for (phi.entries.items) |e| {
                        a.free(e.val);
                        a.free(e.pred);
                    }
                    phi.entries.deinit();
                }
                plist.deinit();
            }
            parsed.phis.deinit();
        }

        ctx.allocas = parsed.allocas;
        ctx.regtypes = parsed.regtypes;
        ctx.params = StrMap.init(a);
        defer {
            ctx.params.deinit();
            ctx.allocas.deinit();
            ctx.regtypes.deinit();
        }

        if (std.mem.eql(u8, gn, "main")) {
            try out.writeAll("int main(int argc, char** argv) {\n");
            try ctx.params.put("argc", {});
            try ctx.params.put("argv", {});
        } else {
            const pclose = std.mem.indexOfScalar(u8, chunk[paren + 1 ..], ')') orelse 0;
            const pstr = chunk[paren + 1 .. paren + 1 + pclose];
            var pdecl = std.ArrayList([]const u8).init(a);
            defer {
                for (pdecl.items) |x| a.free(x);
                pdecl.deinit();
            }
            var pit = std.mem.splitScalar(u8, pstr, ',');
            while (pit.next()) |p| {
                const pt = std.mem.trim(u8, p, " ");
                if (pt.len == 0) continue;
                var t2 = std.mem.tokenizeAny(u8, pt, " ");
                const ty = t2.next() orelse continue;
                const pn = t2.next() orelse continue;
                const pn_nopct = if (pn.len > 1 and pn[0] == '%') pn[1..] else pn;
                try ctx.params.put(pn_nopct, {});
                try pdecl.append(try std.fmt.allocPrint(a, "{s} {s}", .{ ctypeName(llvmCType(ty)), pn_nopct }));
            }
            try out.print("Obj {s}(", .{gn});
            for (pdecl.items, 0..) |pd, i| {
                if (i > 0) try out.writeAll(", ");
                try out.writeAll(pd);
            }
            try out.writeAll(") {\n");
        }
        _ = ret;

        // any register token used but not defined in this function (ex. >_< a closure reading an enclosing function's slot) -> declare as Obj
        var tok_it = std.mem.tokenizeAny(u8, body, " \n\r,()[]");
        while (tok_it.next()) |tok| {
            if (tok.len > 1 and tok[0] == '%' and tok[1] != '.') {
                const rn = tok[1..];
                if (!ctx.params.contains(rn) and !ctx.regtypes.contains(rn)) {
                    try ctx.regtypes.put(rn, .obj);
                }
            }
        }

        // declare registers
        var keys = std.ArrayList([]const u8).init(a);
        defer {
            for (keys.items) |k| a.free(k);
            keys.deinit();
        }
        var kit = ctx.regtypes.keyIterator();
        while (kit.next()) |k| {
            if (ctx.params.contains(k.*)) continue;
            try keys.append(try a.dupe(u8, k.*));
        }
        std.sort.pdq([]const u8, keys.items, {}, regLess);
        for (keys.items) |k| {
            try out.print("  {s} {s};\n", .{ ctypeName(ctx.regtypes.get(k).?), k });
        }

        var lbl_to_idx = std.StringHashMap(usize).init(a);
        defer lbl_to_idx.deinit();
        for (parsed.blocks.items, 0..) |b, i| {
            if (b.label) |l| try lbl_to_idx.put(l, i);
        }

        // emit blocks
        for (parsed.blocks.items) |blk| {
            if (blk.label) |lbl| {
                const sl = try sanitizeLabel(a, lbl);
                defer a.free(sl);
                try out.print("{s}:\n", .{sl});
            }
            if (blk.lines.items.len == 0) continue;
            const term = blk.lines.items[blk.lines.items.len - 1];
            for (blk.lines.items[0 .. blk.lines.items.len - 1]) |line| {
                try emitInstruction(a, out, line, &ctx);
            }
            const is_ret = std.mem.startsWith(u8, term, "ret");
            if (!is_ret) {
                var labels = std.ArrayList([]const u8).init(a);
                defer {
                    for (labels.items) |x| a.free(x);
                    labels.deinit();
                }
                try labelsOf(a, term, &labels);
                const pred_lbl = blk.label orelse "entry";
                for (labels.items) |tgt| {
                    const tidx = lbl_to_idx.get(tgt) orelse continue;
                    for (parsed.phis.items[tidx].items) |phi| {
                        for (phi.entries.items) |e| {
                            if (std.mem.eql(u8, e.pred, pred_lbl)) {
                                const v = try operand(a, e.val, &ctx);
                                defer a.free(v);
                                try out.print("  {s} = {s};\n", .{ phi.result, v });
                            }
                        }
                    }
                }
            }
            try emitInstruction(a, out, term, &ctx);
        }
        try out.writeAll("}\n");
    }
}

fn regLess(_: void, x: []const u8, y: []const u8) bool {
    const xi = std.fmt.parseInt(usize, x[1..], 10) catch 999999999;
    const yi = std.fmt.parseInt(usize, y[1..], 10) catch 999999999;
    if (xi != yi) return xi < yi;
    return std.mem.lessThan(u8, x, y);
}
