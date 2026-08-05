const std = @import("std");
const builtin = @import("builtin");

fn isExecutable(full: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        // Windows has no exec permission bit: existence is enough.
        std.fs.accessAbsolute(full, .{}) catch return false;
        return true;
    }
    std.posix.access(full, std.posix.X_OK) catch return false;
    return true;
}

const zig_search_paths = [_][]const u8{
    "lib/zig/zig.exe", // portable: boblang + lib/ side-by-side (Windows)
    "lib/zig/zig", // portable: boblang + lib/ side-by-side
    "lib/boblang/zig/zig.exe", // standard install: /usr/local/bin/boblang with /usr/local/lib/boblang/zig/zig (Windows)
    "lib/boblang/zig/zig", // standard install: /usr/local/bin/boblang with /usr/local/lib/boblang/zig/zig
    "../lib/boblang/zig/zig.exe", // alt: bin/boblang + lib/boblang/zig/zig (Windows)
    "../lib/boblang/zig/zig", // alt: bin/boblang + lib/boblang/zig/zig
    "../lib/zig/zig.exe", // alt: bin/boblang + lib/zig/zig (Windows)
    "../lib/zig/zig", // alt: bin/boblang + lib/zig/zig
    "../libexec/zig-home/zig", // legacy
};

pub const CacheDirs = struct {
    runtime: []const u8,
    crates: []const u8,
    bridge: []const u8,
    packages: []const u8,
    cache: []const u8,
};

pub fn ensureBoblangCache() !CacheDirs {
    try std.fs.cwd().makePath(".boblang/runtime");
    try std.fs.cwd().makePath(".boblang/crates");
    try std.fs.cwd().makePath(".boblang/bridge");
    try std.fs.cwd().makePath(".boblang/packages");
    try std.fs.cwd().makePath(".boblang/cache");

    return CacheDirs{
        .runtime = ".boblang/runtime",
        .crates = ".boblang/crates",
        .bridge = ".boblang/bridge",
        .packages = ".boblang/packages",
        .cache = ".boblang/cache",
    };
}

pub fn extractRuntimeToCache(allocator: std.mem.Allocator, cache: CacheDirs) !void {
    const embedded = @import("embedded_runtime.zig");
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "runtime.c", .content = embedded.runtime_c },
        .{ .name = "gc.c", .content = embedded.gc_c },
        .{ .name = "gc.h", .content = embedded.gc_h },
    };
    for (files) |f| {
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache.runtime, f.name });
        defer allocator.free(dst);
        const existing = std.fs.cwd().readFileAlloc(allocator, dst, 16 * 1024 * 1024) catch null;
        if (existing) |ex| {
            defer allocator.free(ex);
            if (std.mem.eql(u8, ex, f.content)) continue;
        }
        var file = try std.fs.cwd().createFile(dst, .{});
        defer file.close();
        try file.writer().writeAll(f.content);
    }
}

fn searchForZig(allocator: std.mem.Allocator, exe_dir: []const u8) !?[]const u8 {
    for (zig_search_paths) |rel| {
        const bundled = std.fs.path.resolve(allocator, &[_][]const u8{ exe_dir, rel }) catch continue;
        if (std.fs.accessAbsolute(bundled, .{})) |_| {
            return bundled;
        } else |_| allocator.free(bundled);
        if (!std.mem.endsWith(u8, rel, ".exe")) {
            const rel_exe = std.fmt.allocPrint(allocator, "{s}.exe", .{rel}) catch continue;
            defer allocator.free(rel_exe);
            const bundled_exe = std.fs.path.resolve(allocator, &[_][]const u8{ exe_dir, rel_exe }) catch continue;
            if (std.fs.accessAbsolute(bundled_exe, .{})) |_| {
                return bundled_exe;
            } else |_| allocator.free(bundled_exe);
        }
    }
    return null;
}

fn getExeDirFromArgs(allocator: std.mem.Allocator) ?[]const u8 {
    var args = std.process.argsWithAllocator(allocator) catch return null;
    defer args.deinit();
    const arg0 = args.next() orelse return null;
    const dir = std.fs.path.dirname(arg0) orelse return null;
    return allocator.dupe(u8, dir) catch return null;
}

pub fn findBundledZig(allocator: std.mem.Allocator) !?[]const u8 {
    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    if (exe_dir) |d| {
        defer allocator.free(d);
        if (try searchForZig(allocator, d)) |zig_path| return zig_path;
    }

    const exe_dir_from_args = getExeDirFromArgs(allocator);
    if (exe_dir_from_args) |d| {
        defer allocator.free(d);
        if (try searchForZig(allocator, d)) |zig_path| return zig_path;
    }

    if (try searchForZig(allocator, ".")) |zig_path| return zig_path;

    if (pathHasTool(allocator, "zig")) return allocator.dupe(u8, "zig") catch return null;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig", "--version" },
    }) catch return null;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return allocator.dupe(u8, "zig") catch return null;
}

fn pathHasTool(allocator: std.mem.Allocator, name: []const u8) bool {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return false;
    defer allocator.free(path_env);
    const delim: u8 = if (comptime builtin.os.tag == .windows) ';' else ':';
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path_env, delim);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (dir.len + 1 + name.len >= buf.len) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (isExecutable(full)) return true;
        if (comptime builtin.os.tag == .windows) {
            if (dir.len + 5 + name.len >= buf.len) continue;
            const full_exe = std.fmt.bufPrint(&buf, "{s}/{s}.exe", .{ dir, name }) catch continue;
            if (isExecutable(full_exe)) return true;
        }
    }
    return false;
}

const daemon_search_paths = [_][]const u8{
    "boblangd",
    "lib/boblang/boblangd",
    "../lib/boblang/boblangd",
    "../boblangd",
};

pub fn findBoblangd(allocator: std.mem.Allocator) ?[]const u8 {
    if (std.fs.selfExeDirPathAlloc(allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        for (daemon_search_paths) |rel| {
            const full = std.fs.path.resolve(allocator, &[_][]const u8{ exe_dir, rel }) catch continue;
            if (isExecutable(full)) {
                return full;
            }
            allocator.free(full);
        }
    } else |_| {}
    return null;
}

pub fn findPrebuiltPackage(allocator: std.mem.Allocator, pkg_name: []const u8) ?[]const u8 {
    const lib_name = std.fmt.allocPrint(allocator, "libboblang_package_{s}.a", .{pkg_name}) catch return null;
    defer allocator.free(lib_name);
    const path = std.fs.path.join(allocator, &[_][]const u8{
        ".boblang", "packages", pkg_name, "dist", lib_name,
    }) catch return null;
    if (std.fs.cwd().access(path, .{})) {
        return path;
    } else |_| allocator.free(path);
    return null;
}

pub fn findPackageManifest(allocator: std.mem.Allocator, pkg_name: []const u8) ?[]const u8 {
    const path = std.fs.path.join(allocator, &[_][]const u8{
        ".boblang", "packages", pkg_name, "dist", "package.json",
    }) catch return null;
    if (std.fs.cwd().access(path, .{})) {
        return path;
    } else |_| allocator.free(path);
    return null;
}

pub fn findPackageLlvmIr(allocator: std.mem.Allocator, pkg_name: []const u8) ?[]const u8 {
    const ir_name = std.fmt.allocPrint(allocator, "libboblang_package_{s}.ll", .{pkg_name}) catch return null;
    defer allocator.free(ir_name);
    const path = std.fs.path.join(allocator, &[_][]const u8{
        ".boblang", "packages", pkg_name, "dist", ir_name,
    }) catch return null;
    if (std.fs.cwd().access(path, .{})) {
        return path;
    } else |_| allocator.free(path);
    return null;
}
