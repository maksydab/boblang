const std = @import("std");

pub const GoFunction = struct {
    name: []const u8,
    param_count: usize,
};

pub fn parseGoExports(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(GoFunction) {
    var funcs = std.ArrayList(GoFunction).init(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var prev_export: bool = false;

    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0) {
            prev_export = false;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "//export ")) {
            prev_export = true;
            continue;
        }

        if (prev_export and std.mem.startsWith(u8, trimmed, "func ")) {
            prev_export = false;
            var rest = trimmed["func ".len..];

            var name_end: usize = 0;
            while (name_end < rest.len and rest[name_end] != '(' and rest[name_end] != ' ') : (name_end += 1) {}
            const name = rest[0..name_end];

            var paren_start: usize = name_end;
            while (paren_start < rest.len and rest[paren_start] != '(') : (paren_start += 1) {}
            if (paren_start >= rest.len) continue;

            var i = paren_start + 1;
            var depth: usize = 1;
            var param_count: usize = 0;

            while (i < rest.len and depth > 0) {
                if (rest[i] == '(') depth += 1;
                if (rest[i] == ')') depth -= 1;
                if (rest[i] == ',' and depth == 1) param_count += 1;
                i += 1;
            }

            if (param_count > 0) {
                param_count += 1;
            } else {
                var j = paren_start + 1;
                while (j < i - 1 and rest[j] == ' ') : (j += 1) {}
                if (j < i - 1) param_count = 1;
            }

            try funcs.append(.{
                .name = try allocator.dupe(u8, name),
                .param_count = param_count,
            });
        }
    }

    return funcs;
}

pub fn deinitGoFunctions(allocator: std.mem.Allocator, funcs: *std.ArrayList(GoFunction)) void {
    for (funcs.items) |f| allocator.free(f.name);
    funcs.deinit();
}
