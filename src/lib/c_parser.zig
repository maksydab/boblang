const std = @import("std");

pub const CType = enum {
    void,
    int,
    long,
    long_long,
    float,
    double,
    char,
    short,
    unknown,
    boblang_ptr,
};

pub const CParam = struct {
    param_type: CType,
    name: []const u8,
};

pub const CFunction = struct {
    return_type: CType,
    name: []const u8,
    params: []const CParam,
};

pub fn ctypeToString(ct: CType) []const u8 {
    return switch (ct) {
        .void => "void",
        .int => "int",
        .long => "long",
        .long_long => "long long",
        .float => "float",
        .double => "double",
        .char => "char",
        .short => "short",
        .unknown => "unknown",
        .boblang_ptr => "boblang_ptr",
    };
}

pub fn ctllvm(ct: CType) []const u8 {
    return switch (ct) {
        .void => "void",
        .int => "i32",
        .long => "i64",
        .long_long => "i64",
        .float => "float",
        .double => "double",
        .char => "i8",
        .short => "i16",
        .unknown => "ptr",
        .boblang_ptr => "ptr",
    };
}

pub fn pcsign(allocator: std.mem.Allocator, source: []const u8) !std.StringHashMap(CFunction) {
    var result = std.StringHashMap(CFunction).init(allocator);
    var i: usize = 0;

    while (i < source.len) {
        while (i < source.len and (source[i] == ' ' or source[i] == '\n' or source[i] == '\r' or source[i] == '\t')) {
            i += 1;
        }
        if (i >= source.len) break;

        if (source[i] == '/' and i + 1 < source.len) {
            if (source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i += 2;
                continue;
            }
        }

        if (source[i] == '#') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }

        const return_type = try parseCType(source, &i);
        if (return_type == .unknown) {
            if (i < source.len and source[i] == '{') {
                var brace_depth: usize = 1;
                i += 1;
                while (i < source.len and brace_depth > 0) {
                    if (source[i] == '{') {
                        brace_depth += 1;
                    } else if (source[i] == '}') {
                        brace_depth -= 1;
                    }
                    i += 1;
                }
                continue;
            }
            if (i < source.len and source[i] == '(') {
                var paren_depth: usize = 1;
                i += 1;
                while (i < source.len and paren_depth > 0) {
                    if (source[i] == '(') {
                        paren_depth += 1;
                    } else if (source[i] == ')') {
                        paren_depth -= 1;
                    }
                    i += 1;
                }
                continue;
            }
            while (i < source.len and source[i] != ';' and source[i] != '\n' and source[i] != '{') i += 1;
            if (i < source.len) i += 1;
            continue;
        }

        skipWhitespace(source, &i);
        if (i >= source.len) break;

        const func_name_start = i;
        while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
        if (i == func_name_start) {
            while (i < source.len and source[i] != ';' and source[i] != '{' and source[i] != '\n' and source[i] != '(') i += 1;
            if (i < source.len and (source[i] == ';' or source[i] == '\n')) i += 1;
            continue;
        }
        const func_name = source[func_name_start..i];

        skipWhitespace(source, &i);
        if (i >= source.len or source[i] != '(') {
            while (i < source.len and source[i] != ';' and source[i] != '{' and source[i] != '\n') i += 1;
            if (i < source.len and (source[i] == ';' or source[i] == '\n')) i += 1;
            continue;
        }
        i += 1;

        var params = std.ArrayList(CParam).init(allocator);
        if (i < source.len and source[i] != ')') {
            var is_void_convention = false;
            if (source[i] == 'v' and i + 3 < source.len and std.mem.eql(u8, source[i .. i + 4], "void")) {
                var check_idx: usize = i + 4;
                skipWhitespace(source, &check_idx);
                if (check_idx < source.len and source[check_idx] == ')') {
                    is_void_convention = true;
                    i = check_idx;
                }
            }
            if (!is_void_convention) {
                while (i < source.len and source[i] != ')') {
                    const param_type = try parseCType(source, &i);
                    if (param_type == .unknown) break;
                    skipWhitespace(source, &i);

                    const param_name_start = i;
                    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
                    const param_name = if (i > param_name_start)
                        source[param_name_start..i]
                    else
                        "";

                    try params.append(.{ .param_type = param_type, .name = try allocator.dupe(u8, param_name) });

                    skipWhitespace(source, &i);
                    if (i < source.len and source[i] == ',') {
                        i += 1;
                        skipWhitespace(source, &i);
                    } else if (i < source.len and source[i] == ')') {
                        break;
                    }
                }
            }
        }

        if (i < source.len and source[i] == ')') i += 1;

        skipWhitespace(source, &i);
        if (i < source.len and source[i] == '{') {
            var brace_depth: usize = 1;
            i += 1;
            while (i < source.len and brace_depth > 0) {
                if (source[i] == '{') {
                    brace_depth += 1;
                } else if (source[i] == '}') {
                    brace_depth -= 1;
                }
                i += 1;
            }
        } else if (i < source.len and source[i] == ';') {
            i += 1;
        }

        const func = CFunction{
            .return_type = return_type,
            .name = try allocator.dupe(u8, func_name),
            .params = try params.toOwnedSlice(),
        };
        try result.put(func.name, func);
    }

    return result;
}

fn skipWhitespace(source: []const u8, idx: *usize) void {
    while (idx.* < source.len and (source[idx.*] == ' ' or source[idx.*] == '\n' or source[idx.*] == '\r' or source[idx.*] == '\t')) {
        idx.* += 1;
    }
}

fn parseCType(source: []const u8, idx: *usize) !CType {
    skipWhitespace(source, idx);
    if (idx.* >= source.len) return .unknown;


    if (idx.* + 4 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 5], "const")) {
        idx.* += 5;
        skipWhitespace(source, idx);
        if (idx.* + 4 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 5], "const")) {
            idx.* += 5;
            skipWhitespace(source, idx);
        }
    }

    const ct: CType = if (idx.* + 3 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 4], "void"))
        .void
    else if (idx.* + 2 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 3], "int"))
        .int
    else if (idx.* + 5 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 6], "double"))
        .double
    else if (idx.* + 4 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 5], "float"))
        .float
    else if (idx.* + 3 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 4], "char"))
        .char
    else if (idx.* + 4 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 5], "short"))
        .short
    else if (idx.* + 3 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 4], "long"))
        .long
    else
        return .unknown;


    switch (ct) {
        .void => idx.* += 4,
        .int => idx.* += 3,
        .double => idx.* += 6,
        .float => idx.* += 5,
        .char => idx.* += 4,
        .short => idx.* += 5,
        .long => {
            idx.* += 4;
            skipWhitespace(source, idx);
            if (idx.* + 3 < source.len and std.mem.eql(u8, source[idx.* .. idx.* + 4], "long")) {
                idx.* += 4;
            }
        },
        else => {},
    }


    skipWhitespace(source, idx);
    if (idx.* < source.len and source[idx.*] == '*') {
        while (idx.* < source.len and source[idx.*] == '*') {
            idx.* += 1;
            skipWhitespace(source, idx);
        }
        return .boblang_ptr;
    }

    return ct;
}

pub fn dcfuns(allocator: std.mem.Allocator, funcs: *std.StringHashMap(CFunction)) void {
    var it = funcs.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.name);
        for (entry.value_ptr.params) |p| {
            allocator.free(p.name);
        }
        allocator.free(entry.value_ptr.params);
    }
    funcs.deinit();
}
