const std = @import("std");

pub const PackageEntry = struct {
    path: []const u8,
    alias: []const u8,
};

pub const BoblangConf = struct {
    dialect: []const u8 = "python-like",
    packages: []PackageEntry = &.{},
    output: []const u8 = "output",
    optimize: []const u8 = "ReleaseFast",
    target: ?[]const u8 = null,
    version: []const u8 = "0.1.0",
    entry: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    libs: []const []const u8 = &.{},
    obfuscate: bool = false,
    custom: std.StringHashMap([]const u8),

    pub fn deinit(self: *BoblangConf, allocator: std.mem.Allocator) void {
        allocator.free(self.dialect);
        allocator.free(self.output);
        allocator.free(self.optimize);
        if (self.target) |t| allocator.free(t);
        allocator.free(self.version);
        if (self.entry) |e| allocator.free(e);
        for (self.packages) |*p| {
            allocator.free(p.path);
            allocator.free(p.alias);
        }
        allocator.free(self.packages);
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
        for (self.libs) |l| allocator.free(l);
        allocator.free(self.libs);
        {
            var it = self.custom.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.custom.deinit();
        }
    }
};

pub fn parseBoblangConf(allocator: std.mem.Allocator, content: []const u8) !BoblangConf {
    var dialect: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var optimize: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var entry: ?[]const u8 = null;
    var packages = std.ArrayList(PackageEntry).init(allocator);
    var files = std.ArrayList([]const u8).init(allocator);
    var libs_list = std.ArrayList([]const u8).init(allocator);
    var custom_map = std.StringHashMap([]const u8).init(allocator);

    var i: usize = 0;
    while (i < content.len) {
        while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '\r' or content[i] == '\t' or content[i] == ',')) {
            i += 1;
        }
        if (i >= content.len) break;
        if (content[i] == '#') {
            while (i < content.len and content[i] != '\n') i += 1;
            continue;
        }
        const field_start = i;
        while (i < content.len and content[i] != ':') i += 1;
        if (i >= content.len) break;
        const field_name = std.mem.trim(u8, content[field_start..i], " \t\n\r");
        i += 1;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
        if (i >= content.len) break;
        if (content[i] == '{') {
            i += 1;
            var depth: usize = 1;
            const val_start = i;
            while (i < content.len and depth > 0) {
                if (content[i] == '{') depth += 1;
                if (content[i] == '}') depth -= 1;
                if (depth > 0) i += 1;
            }
            const val = content[val_start..i];
            i += 1;
            if (std.mem.eql(u8, field_name, "packages")) {
                try parsePackagesBlock(allocator, &packages, val);
                } else if (std.mem.eql(u8, field_name, "files")) {
                    var j: usize = 0;
                    while (j < val.len) {
                        while (j < val.len and (val[j] == ' ' or val[j] == '\n' or val[j] == '\r' or val[j] == '\t' or val[j] == ',')) j += 1;
                        if (j >= val.len) break;
                        const ps = j;
                        while (j < val.len and val[j] != ',' and val[j] != ' ' and val[j] != '\n' and val[j] != '\r' and val[j] != '}' and val[j] != '{') j += 1;
                        const f = std.mem.trim(u8, val[ps..j], " \t\n\r\"'");
                        if (f.len > 0) try files.append(try allocator.dupe(u8, f));
                    }
                } else if (std.mem.eql(u8, field_name, "libs")) {
                    var j: usize = 0;
                    while (j < val.len) {
                        while (j < val.len and (val[j] == ' ' or val[j] == '\n' or val[j] == '\r' or val[j] == '\t' or val[j] == ',')) j += 1;
                        if (j >= val.len) break;
                        const ps = j;
                        while (j < val.len and val[j] != ',' and val[j] != ' ' and val[j] != '\n' and val[j] != '\r' and val[j] != '}' and val[j] != '{') j += 1;
                        const l = std.mem.trim(u8, val[ps..j], " \t\n\r\"'");
                        if (l.len > 0) try libs_list.append(try allocator.dupe(u8, l));
                    }
                }
        } else if (content[i] == '[') {
            i += 1;
            var depth: usize = 1;
            while (i < content.len and depth > 0) {
                if (content[i] == '[') depth += 1;
                if (content[i] == ']') depth -= 1;
                if (depth > 0) i += 1;
            }
            i += 1;
        } else if (content[i] == '"' or content[i] == '\'') {
            const quote = content[i];
            i += 1;
            const val_start = i;
            while (i < content.len and content[i] != quote) i += 1;
            const val = content[val_start..i];
            i += 1;
            if (std.mem.eql(u8, field_name, "dialect")) dialect = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "output")) output = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "optimize")) optimize = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "target")) target = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "version")) version = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "entry")) entry = try allocator.dupe(u8, val);
            try custom_map.put(try allocator.dupe(u8, field_name), try allocator.dupe(u8, val));
        } else {
            const val_start = i;
            while (i < content.len and content[i] != '\n' and content[i] != ',' and content[i] != '}') i += 1;
            const val = std.mem.trim(u8, content[val_start..i], " \t\r\n");
            if (std.mem.eql(u8, field_name, "dialect")) dialect = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "output")) output = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "optimize")) optimize = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "target")) target = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "version")) version = try allocator.dupe(u8, val);
            if (std.mem.eql(u8, field_name, "entry")) entry = try allocator.dupe(u8, val);
            try custom_map.put(try allocator.dupe(u8, field_name), try allocator.dupe(u8, val));
        }
    }

    var obfuscate = false;
    if (custom_map.get("obfuscate")) |v| {
        obfuscate = std.mem.eql(u8, std.mem.trim(u8, v, " \t\"'"), "true");
    }

    return BoblangConf{
        .dialect = dialect orelse try allocator.dupe(u8, "python-like"),
        .packages = try packages.toOwnedSlice(),
        .output = output orelse try allocator.dupe(u8, "output"),
        .optimize = optimize orelse try allocator.dupe(u8, "ReleaseFast"),
        .target = target,
        .version = version orelse try allocator.dupe(u8, "0.1.0"),
        .entry = if (entry) |e| try allocator.dupe(u8, e) else null,
        .files = try files.toOwnedSlice(),
        .custom = custom_map,
        .libs = try libs_list.toOwnedSlice(),
        .obfuscate = obfuscate,
    };
}

fn parsePackagesBlock(allocator: std.mem.Allocator, packages: *std.ArrayList(PackageEntry), val: []const u8) !void {
    var j: usize = 0;
    while (j < val.len) {
        while (j < val.len and (val[j] == ' ' or val[j] == '\n' or val[j] == '\r' or val[j] == '\t' or val[j] == ',')) j += 1;
        if (j >= val.len) break;
        const ps = j;
        while (j < val.len and val[j] != ',' and val[j] != ':' and val[j] != '=' and val[j] != ' ' and val[j] != '\n' and val[j] != '\r' and val[j] != '}' and val[j] != '{') j += 1;
        const pkg_path = std.mem.trim(u8, val[ps..j], " \t\n\r\"'");
        if (pkg_path.len > 0) {
            const after_key = j;
            while (j < val.len and val[j] == ' ') j += 1;
            if (j < val.len and val[j] == ':') {
                j += 1;
                while (j < val.len and (val[j] == ' ' or val[j] == '\n' or val[j] == '\r' or val[j] == '\t')) j += 1;
                if (j < val.len and val[j] == '{') {
                    j += 1;
                    var depth: usize = 1;
                    const sub_start = j;
                    while (j < val.len and depth > 0) {
                        if (val[j] == '{') depth += 1;
                        if (val[j] == '}') depth -= 1;
                        if (depth > 0) j += 1;
                    }
                    try parsePackagesBlock(allocator, packages, val[sub_start..j]);
                    if (j < val.len) j += 1;
                }
            } else if (j < val.len and val[j] == '=') {
                j += 1;
                while (j < val.len and val[j] == ' ') j += 1;
                if (j < val.len and (val[j] == '"' or val[j] == '\'')) {
                    const quote = val[j];
                    j += 1;
                    while (j < val.len and val[j] != quote) j += 1;
                    if (j < val.len) j += 1;
                }
                try packages.append(.{
                    .path = try allocator.dupe(u8, pkg_path),
                    .alias = try allocator.dupe(u8, pkg_path),
                });
            } else {
                var alias_val: []const u8 = pkg_path;
                var check_pos = after_key;
                while (check_pos < val.len and val[check_pos] == ' ') check_pos += 1;
                if (check_pos + 3 < val.len and val[check_pos] == 'a' and val[check_pos + 1] == 's' and val[check_pos + 2] == ' ') {
                    check_pos += 3;
                    while (check_pos < val.len and val[check_pos] == ' ') check_pos += 1;
                    const alias_start = check_pos;
                    while (check_pos < val.len and val[check_pos] != ',' and val[check_pos] != ' ' and val[check_pos] != '\n' and val[check_pos] != '\r' and val[check_pos] != '}' and val[check_pos] != '{') check_pos += 1;
                    if (check_pos > alias_start) {
                        alias_val = std.mem.trim(u8, val[alias_start..check_pos], " \t\n\r\"'");
                        j = check_pos;
                    }
                } else {
                    j = after_key;
                }
                try packages.append(.{
                    .path = try allocator.dupe(u8, pkg_path),
                    .alias = try allocator.dupe(u8, alias_val),
                });
            }
        }
    }
}

pub fn findBoblangConf(allocator: std.mem.Allocator) ?[]const u8 {
    const candidates = [_][]const u8{ "boblang.conf", "Boblang.conf", "boblang.json" };
    for (candidates) |name| {
        if (std.fs.cwd().access(name, .{})) {
            if (std.fs.cwd().readFileAlloc(allocator, name, 1024 * 1024)) |content| {
                return content;
            } else |_| {}
        } else |_| {}
    }
    return null;
}

pub fn serializeBoblangConf(allocator: std.mem.Allocator, conf: *const BoblangConf) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("dialect: \"{s}\"\n", .{conf.dialect});
    try w.print("output: \"{s}\"\n", .{conf.output});
    try w.print("optimize: \"{s}\"\n", .{conf.optimize});
    if (conf.obfuscate) try w.print("obfuscate: true\n", .{});

    if (conf.target) |t| {
        try w.print("target: \"{s}\"\n", .{t});
    }

    try w.print("packages: ", .{});
    if (conf.packages.len == 0) {
        try w.print("{{}}\n", .{});
    } else {
        try w.print("{{\n", .{});
        for (conf.packages) |pkg| {
            if (std.mem.eql(u8, pkg.path, pkg.alias)) {
                try w.print("    {s}\n", .{pkg.path});
            } else {
                try w.print("    {s} as {s}\n", .{ pkg.path, pkg.alias });
            }
        }
        try w.print("}}\n", .{});
    }

    try w.print("version: \"{s}\"\n", .{conf.version});

    if (conf.entry) |e| {
        try w.print("entry: \"{s}\"\n", .{e});
    }

    try w.print("files: ", .{});
    if (conf.files.len == 0) {
        try w.print("{{}}\n", .{});
    } else {
        try w.print("{{\n", .{});
        for (conf.files) |f| {
            try w.print("    {s}\n", .{f});
        }
        try w.print("}}\n", .{});
    }

    try w.print("libs: ", .{});
    if (conf.libs.len == 0) {
        try w.print("{{}}\n", .{});
    } else {
        try w.print("{{\n", .{});
        for (conf.libs) |l| {
            try w.print("    {s}\n", .{l});
        }
        try w.print("}}\n", .{});
    }

    return try buf.toOwnedSlice();
}

pub fn addPackageToConf(allocator: std.mem.Allocator, conf: *const BoblangConf, path: []const u8, alias: []const u8) !BoblangConf {
    var new_packages = std.ArrayList(PackageEntry).init(allocator);
    errdefer new_packages.deinit();

    for (conf.packages) |pkg| {
        try new_packages.append(.{
            .path = try allocator.dupe(u8, pkg.path),
            .alias = try allocator.dupe(u8, pkg.alias),
        });
    }

    try new_packages.append(.{
        .path = try allocator.dupe(u8, path),
        .alias = try allocator.dupe(u8, alias),
    });

    var new_files = std.ArrayList([]const u8).init(allocator);
    defer new_files.deinit();
    for (conf.files) |f| {
        try new_files.append(try allocator.dupe(u8, f));
    }

    var new_libs = std.ArrayList([]const u8).init(allocator);
    defer new_libs.deinit();
    for (conf.libs) |l| {
        try new_libs.append(try allocator.dupe(u8, l));
    }

    return BoblangConf{
        .dialect = try allocator.dupe(u8, conf.dialect),
        .packages = try new_packages.toOwnedSlice(),
        .output = try allocator.dupe(u8, conf.output),
        .optimize = try allocator.dupe(u8, conf.optimize),
        .target = if (conf.target) |t| try allocator.dupe(u8, t) else null,
        .version = try allocator.dupe(u8, conf.version),
        .entry = if (conf.entry) |e| try allocator.dupe(u8, e) else null,
        .files = try new_files.toOwnedSlice(),
        .libs = try new_libs.toOwnedSlice(),
        .obfuscate = conf.obfuscate,
    };
}
