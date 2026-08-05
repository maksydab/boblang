const std = @import("std");
const builtin = @import("builtin");
const Builder = @import("lib/builder.zig").Builder;
const parser = @import("lib/parser.zig");
const errors = @import("lib/errors.zig");
const c_parser = @import("lib/c_parser.zig");
const bundle = @import("bundle_config.zig");
const optimizer = @import("lib/optimizer.zig");
const pkg_builder = @import("lib/package_builder.zig");
const go_parser = @import("lib/go_parser.zig");
const boblang_conf = @import("boblang_conf.zig");
const dialect = @import("lib/dialect.zig");
const llir2c = @import("lib/llir2c.zig");
const progress = @import("lib/progress.zig");

const BOBLANG_LICENSE = @embedFile("_runtime/LICENSE");
const THIRD_PARTY_LICENSES = @embedFile("_runtime/THIRD_PARTY_NOTICES.md");

const Mode = enum { build, run };

const Config = struct {
    mode: Mode,
    input: []const u8,
    output: []const u8,
    optimize: []const u8 = "ReleaseFast",
    target: ?[]const u8 = null,
    emit_llvm: bool = false,
    dialect: []const u8 = "python-like",
    obfuscate: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();

    _ = args_it.skip();

    const cmd = args_it.next() orelse {
        if (boblang_conf.findBoblangConf(allocator)) |content| {
            defer allocator.free(content);
            var conf = try boblang_conf.parseBoblangConf(allocator, content);
            defer conf.deinit(allocator);
            return try buildFromConf(allocator, &conf, .build, null, null);
        }
        return usage();
    };

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return usage();
    }

    if (std.mem.eql(u8, cmd, "--licenses") or std.mem.eql(u8, cmd, "licenses")) {
        return printLicenses();
    }

    if (std.mem.eql(u8, cmd, "conf")) {
        const sub = args_it.next();
        if (sub != null and (std.mem.eql(u8, sub.?, "-h") or std.mem.eql(u8, sub.?, "--help"))) {
            return confUsage();
        }
        std.debug.print("error: unknown conf subcommand. Use 'boblang conf -h'\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, cmd, "init")) {
        return try initProject(allocator);
    }

    if (std.mem.eql(u8, cmd, "pack")) {
        const pkg_dir = args_it.next() orelse {
            std.debug.print("error: pack requires a package directory\n", .{});
            std.process.exit(1);
        };
        var pack_version: ?[]const u8 = null;
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                pack_version = args_it.next() orelse {
                    std.debug.print("error: -v requires a version string\n", .{});
                    std.process.exit(1);
                };
            }
        }
        return try bobpkgPack(allocator, pkg_dir, pack_version);
    }

    if (std.mem.eql(u8, cmd, "pkg")) {
        const subcmd = args_it.next() orelse {
            bobpkgUsage();
            return;
        };
        if (std.mem.eql(u8, subcmd, "install")) {
            const pkg_source = args_it.next() orelse {
                std.debug.print("error: pkg install requires a package path or URL\n", .{});
                std.process.exit(1);
            };
            var install_version: ?[]const u8 = null;
            var alias_override: ?[]const u8 = null;
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                    install_version = args_it.next() orelse {
                        std.debug.print("error: -v requires a version string\n", .{});
                        std.process.exit(1);
                    };
                } else {
                    alias_override = arg;
                }
            }
            return try bobpkgInstall(allocator, pkg_source, alias_override, install_version);
        } else if (std.mem.eql(u8, subcmd, "update")) {
            const pkg_name = args_it.next() orelse {
                std.debug.print("error: pkg update requires a package name\n", .{});
                std.process.exit(1);
            };
            return try bobpkgUpdate(allocator, pkg_name);
        } else if (std.mem.eql(u8, subcmd, "uninstall")) {
            const pkg_name = args_it.next() orelse {
                std.debug.print("error: pkg uninstall requires a package name\n", .{});
                std.process.exit(1);
            };
            return try bobpkgRemove(allocator, pkg_name);
        } else if (std.mem.eql(u8, subcmd, "remove")) {
            const pkg_name = args_it.next() orelse {
                std.debug.print("error: pkg remove requires a package name\n", .{});
                std.process.exit(1);
            };
            return try bobpkgRemove(allocator, pkg_name);
        } else if (std.mem.eql(u8, subcmd, "list")) {
            return try bobpkgList();
        } else if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help")) {
            bobpkgUsage();
            return;
        } else {
            std.debug.print("error: unknown pkg subcommand '{s}'\n", .{subcmd});
            bobpkgUsage();
            std.process.exit(1);
        }
    }

    if (!std.mem.eql(u8, cmd, "build") and !std.mem.eql(u8, cmd, "run")) {
        std.debug.print("error [C2]: CLI Error\n  -> unknown command: expected 'build' or 'run', got '{s}'\n", .{cmd});
        std.process.exit(1);
    }

    const maybe_input = args_it.next();
    if (maybe_input == null) {
        if (boblang_conf.findBoblangConf(allocator)) |content| {
            defer allocator.free(content);
            var conf = try boblang_conf.parseBoblangConf(allocator, content);
            defer conf.deinit(allocator);
            return try buildFromConf(allocator, &conf, if (std.mem.eql(u8, cmd, "run")) .run else .build, null, null);
        }
        return usage();
    }

    const input = maybe_input.?;
    if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "./")) {
        if (boblang_conf.findBoblangConf(allocator)) |content| {
            defer allocator.free(content);
            var conf = try boblang_conf.parseBoblangConf(allocator, content);
            defer conf.deinit(allocator);
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                    _ = args_it.next();
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    std.debug.print("error: unrecognized flag '{s}' for conf-based build\n  -> use target: in boblang.conf instead, or compile a single file\n", .{arg});
                    std.process.exit(1);
                } else if (std.mem.startsWith(u8, arg, "-")) {
                    std.debug.print("error: unrecognized flag '{s}'\n", .{arg});
                    std.process.exit(1);
                }
            }
            return try buildFromConf(allocator, &conf, if (std.mem.eql(u8, cmd, "run")) .run else .build, null, null);
        }
        std.debug.print("error: no boblang.conf found in current directory\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, input, "conf")) {
        if (boblang_conf.findBoblangConf(allocator)) |content| {
            defer allocator.free(content);
            var conf = try boblang_conf.parseBoblangConf(allocator, content);
            defer conf.deinit(allocator);
            const extra = args_it.next();
            return try buildFromConf(allocator, &conf, if (std.mem.eql(u8, cmd, "run")) .run else .build, extra, null);
        }
        std.debug.print("error: no boblang.conf found\n", .{});
        std.process.exit(1);
    }

    const out_stem: []const u8 = def: {
        var s: []const u8 = input;
        if (std.mem.lastIndexOfScalar(u8, s, '/')) |pos| s = s[pos + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, s, '\\')) |pos| s = s[pos + 1 ..];
        if (std.mem.lastIndexOf(u8, s, ".bob")) |pos| s = s[0..pos];
        break :def s;
    };

    var cfg = Config{
        .mode = if (std.mem.eql(u8, cmd, "run")) .run else .build,
        .input = input,
        .output = try allocator.dupeZ(u8, out_stem),
    };

    var target_arch: ?[]const u8 = null;
    var target_os: ?[]const u8 = null;
    var target_explicit = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            cfg.output = args_it.next() orelse {
                std.debug.print("error [C3]: CLI Error\n  -> --output requires a value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) {
            cfg.target = args_it.next() orelse {
                std.debug.print("error [C3]: CLI Error\n  -> --target requires a value\n", .{});
                std.process.exit(1);
            };
            target_explicit = true;
        } else if (std.mem.eql(u8, arg, "--arch")) {
            target_arch = args_it.next() orelse {
                std.debug.print("error [C3]: CLI Error\n  -> --arch requires a value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--os")) {
            target_os = args_it.next() orelse {
                std.debug.print("error [C3]: CLI Error\n  -> --os requires a value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-O")) {
            cfg.optimize = args_it.next() orelse {
                std.debug.print("error [C3]: CLI Error\n  -> -O requires a value (Debug, ReleaseFast, ReleaseSafe, ReleaseSmall)\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--emit-llvm")) {
            cfg.emit_llvm = true;
        } else if (std.mem.eql(u8, arg, "--wasm")) {
            target_arch = "wasm32";
            target_os = "wasi";
        } else if (std.mem.eql(u8, arg, "--wasm64")) {
            target_arch = "wasm64";
            target_os = "wasi";
        } else if (std.mem.eql(u8, arg, "--windows")) {
            target_arch = "x86_64";
            target_os = "windows";
        } else if (std.mem.eql(u8, arg, "--linux")) {
            target_arch = "x86_64";
            target_os = "linux";
        } else if (std.mem.eql(u8, arg, "--macos")) {
            target_arch = "x86_64";
            target_os = "macos";
        } else if (std.mem.eql(u8, arg, "--dialect")) {
            cfg.dialect = args_it.next() orelse {
                std.debug.print("error [C3]: CLI Error\n  -> --dialect requires a value (python-like, lua-like, c-like)\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--obfuscate")) {
            cfg.obfuscate = true;
        } else {
            std.debug.print("error [C4]: CLI Error\n  -> unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    if (!target_explicit and target_arch != null and target_os != null) {
        if (target_arch) |arch| {
            if (target_os) |os| {
                const abi = dabi(arch, os);
                cfg.target = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ arch, os, abi });
            }
        }
    } else if (!target_explicit and (target_arch != null or target_os != null)) {
        if (target_arch) |arch| {
            cfg.target = try std.fmt.allocPrint(allocator, "{s}-unknown-unknown", .{arch});
        } else {
            const os = target_os.?;
            cfg.target = try std.fmt.allocPrint(allocator, "unknown-{s}-unknown", .{os});
        }
    }

    return try compileAndLink(allocator, cfg);
}

fn bobpkgPack(allocator: std.mem.Allocator, pkg_dir_raw: []const u8, version_override: ?[]const u8) !void {
    return bobpkgPackEx(allocator, pkg_dir_raw, null, version_override);
}

fn bobpkgPackEx(allocator: std.mem.Allocator, pkg_dir_raw: []const u8, pkg_name_override: ?[]const u8, version_override: ?[]const u8) !void {
    const pkg_dir = try std.fs.realpathAlloc(allocator, pkg_dir_raw);
    defer allocator.free(pkg_dir);

    const conf_path = try std.fmt.allocPrint(allocator, "{s}/boblang.conf", .{pkg_dir});
    defer allocator.free(conf_path);

    const conf_content = std.fs.cwd().readFileAlloc(allocator, conf_path, 1024 * 1024) catch |err| {
        std.debug.print("error: could not read boblang.conf from '{s}': {s}\n", .{ pkg_dir, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(conf_content);

    var conf = try boblang_conf.parseBoblangConf(allocator, conf_content);
    defer conf.deinit(allocator);

    if (version_override) |v| {
        allocator.free(conf.version);
        conf.version = try allocator.dupe(u8, v);
    }

    const pkg_name = if (pkg_name_override) |override|
        try allocator.dupe(u8, override)
    else
        try allocator.dupe(u8, std.fs.path.basename(pkg_dir));
    defer allocator.free(pkg_name);

    const pkg_alias = pkg_name;

    const dist_dir = try std.fmt.allocPrint(allocator, "{s}/dist", .{pkg_dir});
    defer allocator.free(dist_dir);
    try std.fs.cwd().makePath(dist_dir);

    var all_functions = std.ArrayList(pkg_builder.PackageFunction).init(allocator);
    defer {
        for (all_functions.items) |f| {
            allocator.free(f.name);
            allocator.free(f.return_type);
            if (f.description) |d| allocator.free(d);
            for (f.params) |p| {
                allocator.free(p.name);
                allocator.free(p.type_name);
            }
            allocator.free(f.params);
        }
        all_functions.deinit();
    }

    var lib_bob_fn_names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (lib_bob_fn_names.items) |n| allocator.free(n);
        lib_bob_fn_names.deinit();
    }

    const cache = try bundle.ensureBoblangCache();
    try bundle.extractRuntimeToCache(allocator, cache);

    var pkg_bob_files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (pkg_bob_files.items) |f| allocator.free(f);
        pkg_bob_files.deinit();
    }

    for (conf.files) |file| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_dir, file });
        defer allocator.free(full_path);

        if (std.mem.endsWith(u8, file, ".bob")) {
            const source_code = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch |err| {
                std.debug.print("warning: could not read '{s}': {s}\n", .{ full_path, @errorName(err) });
                continue;
            };
            defer allocator.free(source_code);

            const cleaned_source = std.mem.trim(u8, source_code, " \n\r\t");
            if (cleaned_source.len == 0) continue;

            const ast_tree = dialect.parseToAst(allocator, cleaned_source, conf.dialect) catch |err| {
                std.debug.print("warning: parse error in '{s}': {s}\n", .{ full_path, @errorName(err) });
                continue;
            };
            defer dialect.freeAstTree(allocator, ast_tree);

            for (ast_tree.items) |node| {
                if (node.node_type == .func_def and !node.is_extern) {
                    var params = std.ArrayList(pkg_builder.Param).init(allocator);
                    const return_type: []const u8 = if (node.extra) |rt| rt else "void";
                    if (node.args) |args| {
                        for (args.items) |arg| {
                            try params.append(.{
                                .name = try allocator.dupe(u8, arg.name),
                                .type_name = try allocator.dupe(u8, arg.extra orelse "ptr"),
                            });
                        }
                    }
                    try all_functions.append(.{
                        .name = try allocator.dupe(u8, node.name),
                        .params = try params.toOwnedSlice(),
                        .return_type = try allocator.dupe(u8, return_type),
                        .description = if (node.doc_string) |ds| try allocator.dupe(u8, ds) else null,
                    });
                }
            }

            try pkg_bob_files.append(try allocator.dupe(u8, full_path));
        } else if (std.mem.endsWith(u8, file, ".c")) {
            const source_code = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch |err| {
                std.debug.print("warning: could not read '{s}': {s}\n", .{ full_path, @errorName(err) });
                continue;
            };
            defer allocator.free(source_code);

            var sigs = c_parser.pcsign(allocator, source_code) catch {
                std.debug.print("warning: could not parse C signatures in '{s}'\n", .{full_path});
                continue;
            };
            defer c_parser.dcfuns(allocator, &sigs);

            var sit = sigs.iterator();
            while (sit.next()) |entry| {
                var params = std.ArrayList(pkg_builder.Param).init(allocator);
                for (entry.value_ptr.params) |p| {
                    try params.append(.{
                        .name = try allocator.dupe(u8, p.name),
                        .type_name = try allocator.dupe(u8, @tagName(p.param_type)),
                    });
                }
                try all_functions.append(.{
                    .name = try allocator.dupe(u8, entry.value_ptr.name),
                    .params = try params.toOwnedSlice(),
                    .return_type = try allocator.dupe(u8, @tagName(entry.value_ptr.return_type)),
                });
            }
        } else if (std.mem.endsWith(u8, file, ".go")) {
            const source_code = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch |err| {
                std.debug.print("warning: could not read '{s}': {s}\n", .{ full_path, @errorName(err) });
                continue;
            };
            defer allocator.free(source_code);

            var go_funcs = go_parser.parseGoExports(allocator, source_code) catch {
                std.debug.print("warning: could not parse Go exports in '{s}'\n", .{full_path});
                continue;
            };
            defer go_parser.deinitGoFunctions(allocator, &go_funcs);

            for (go_funcs.items) |gf| {
                var params = std.ArrayList(pkg_builder.Param).init(allocator);
                for (0..gf.param_count) |_| {
                    try params.append(.{
                        .name = try allocator.dupe(u8, ""),
                        .type_name = try allocator.dupe(u8, "ptr"),
                    });
                }
                try all_functions.append(.{
                    .name = try allocator.dupe(u8, gf.name),
                    .params = try params.toOwnedSlice(),
                    .return_type = try allocator.dupe(u8, "ptr"),
                });
            }
        }
    }

    var has_lib_bob = false;
    var exports = std.ArrayList(pkg_builder.ExportInfo).init(allocator);
    defer {
        for (exports.items) |e| {
            allocator.free(e.source);
            allocator.free(e.alias);
            allocator.free(e.module);
            allocator.free(e.name);
        }
        exports.deinit();
    }
    {
        const lib_bob_path = try std.fmt.allocPrint(allocator, "{s}/lib.bob", .{pkg_dir});
        defer allocator.free(lib_bob_path);
        const lib_bob_src = std.fs.cwd().readFileAlloc(allocator, lib_bob_path, 1024 * 1024) catch null;
        if (lib_bob_src) |src| {
            defer allocator.free(src);
            exports = try pkg_builder.parseLibBobExports(allocator, src);
            has_lib_bob = true;

            var lib_bob_fns = pkg_builder.parseLibBob(allocator, src) catch std.ArrayList(pkg_builder.PackageFunction).init(allocator);
            defer {
                for (lib_bob_fns.items) |f| {
                    allocator.free(f.name);
                    allocator.free(f.return_type);
                    for (f.params) |p| {
                        allocator.free(p.name);
                        allocator.free(p.type_name);
                    }
                    allocator.free(f.params);
                }
                lib_bob_fns.deinit();
            }
            for (lib_bob_fns.items) |f| {
                var is_dup_name = false;
                for (lib_bob_fn_names.items) |n| {
                    if (std.mem.eql(u8, n, f.name)) {
                        is_dup_name = true;
                        break;
                    }
                }
                if (!is_dup_name) try lib_bob_fn_names.append(try allocator.dupe(u8, f.name));
            }
            for (lib_bob_fns.items) |f| {
                var already_exists = false;
                for (all_functions.items) |existing| {
                    if (std.mem.eql(u8, existing.name, f.name)) {
                        already_exists = true;
                        break;
                    }
                }
                if (!already_exists) {
                    var params = std.ArrayList(pkg_builder.Param).init(allocator);
                    for (f.params) |p| {
                        try params.append(.{
                            .name = try allocator.dupe(u8, p.name),
                            .type_name = try allocator.dupe(u8, p.type_name),
                        });
                    }
                    try all_functions.append(.{
                        .name = try allocator.dupe(u8, f.name),
                        .params = try params.toOwnedSlice(),
                        .return_type = try allocator.dupe(u8, f.return_type),
                    });
                }
            }
        }
    }

    if (!has_lib_bob) {
        for (all_functions.items) |f| {
            if (std.mem.eql(u8, f.name, "main")) continue;
            const is_c_func = for (f.params) |p| {
                if (!std.mem.eql(u8, p.type_name, "ptr")) break true;
            } else false;
            const is_c_return = !std.mem.eql(u8, f.return_type, "void") and !std.mem.eql(u8, f.return_type, "ptr");
            const use_mangled = !is_c_func and !is_c_return;
            const source_name = if (use_mangled)
                try std.fmt.allocPrint(allocator, "bob_mod_{s}_{s}", .{ pkg_alias, f.name })
            else
                try allocator.dupe(u8, f.name);
            try exports.append(.{
                .source = source_name,
                .alias = try allocator.dupe(u8, f.name),
                .module = try allocator.dupe(u8, ""),
                .name = try allocator.dupe(u8, f.name),
            });
        }
    } else {
        for (exports.items) |*e| {
            if (e.module.len == 0 and e.source.len > 0) {
                var is_lib_bob_fn = false;
                for (lib_bob_fn_names.items) |n| {
                    if (std.mem.eql(u8, n, e.name)) {
                        is_lib_bob_fn = true;
                        break;
                    }
                }
                if (is_lib_bob_fn) {
                    const mangled = try std.fmt.allocPrint(allocator, "bob_mod_{s}_{s}", .{ pkg_alias, e.name });
                    allocator.free(e.source);
                    e.source = mangled;
                }
            }
        }
    }

    {
        var bob_builder = Builder.initPackage(allocator, "lib.bob", pkg_name);
        defer bob_builder.deinit();

        const saved_prefix = bob_builder.current_module_prefix;
        bob_builder.current_module_prefix = pkg_alias;
        defer bob_builder.current_module_prefix = saved_prefix;

        const original_cwd = try std.fs.realpathAlloc(allocator, ".");
        defer allocator.free(original_cwd);

        std.posix.chdir(pkg_dir) catch {};

        for (pkg_bob_files.items) |bob_full_path| {
            const source_code = std.fs.cwd().readFileAlloc(allocator, bob_full_path, 1024 * 1024) catch |err| {
                std.debug.print("warning: could not read '{s}': {s}\n", .{ bob_full_path, @errorName(err) });
                continue;
            };
            defer allocator.free(source_code);

            const cleaned_source = std.mem.trim(u8, source_code, " \n\r\t");
            if (cleaned_source.len == 0) continue;

            const ast_tree = dialect.parseToAst(allocator, cleaned_source, conf.dialect) catch |err| {
                std.debug.print("warning: parse error in '{s}': {s}\n", .{ bob_full_path, @errorName(err) });
                continue;
            };
            defer dialect.freeAstTree(allocator, ast_tree);

            for (ast_tree.items) |node| {
                _ = bob_builder.walkAstAndEmit(node) catch continue;
            }
        }

        std.posix.chdir(original_cwd) catch {};

        {
            var cmod_it = bob_builder.c_modules.iterator();
            while (cmod_it.next()) |cmod_entry| {
                var cm_it = cmod_entry.value_ptr.iterator();
                while (cm_it.next()) |cm_entry| {
                    var c_params = std.ArrayList(pkg_builder.Param).init(allocator);
                    for (cm_entry.value_ptr.params) |p| {
                        try c_params.append(.{
                            .name = try allocator.dupe(u8, p.name),
                            .type_name = try allocator.dupe(u8, @tagName(p.param_type)),
                        });
                    }
                    try all_functions.append(.{
                        .name = try allocator.dupe(u8, cm_entry.value_ptr.name),
                        .params = try c_params.toOwnedSlice(),
                        .return_type = try allocator.dupe(u8, @tagName(cm_entry.value_ptr.return_type)),
                    });
                }
            }
        }

        {
            const isWrapperLike = struct {
                fn check(f: pkg_builder.PackageFunction) bool {
                    if (f.description != null) return true;
                    if (f.params.len == 0) return !std.mem.eql(u8, f.return_type, "boblang_ptr");
                    for (f.params) |p| {
                        if (!std.mem.eql(u8, p.type_name, "boblang_ptr")) return true;
                    }
                    return false;
                }
            }.check;
            var kept = std.ArrayList(pkg_builder.PackageFunction).init(allocator);
            var kept_pos = std.StringHashMap(usize).init(allocator);
            defer kept_pos.deinit();
            for (all_functions.items) |f| {
                if (kept_pos.get(f.name)) |pos| {
                    var is_lib_bob = false;
                    for (lib_bob_fn_names.items) |n| {
                        if (std.mem.eql(u8, n, f.name)) {
                            is_lib_bob = true;
                            break;
                        }
                    }
                    if (is_lib_bob and isWrapperLike(f) and !isWrapperLike(kept.items[pos])) {
                        kept.items[pos] = f;
                    }
                    continue;
                }
                try kept_pos.put(try allocator.dupe(u8, f.name), kept.items.len);
                try kept.append(f);
            }
            all_functions.deinit();
            all_functions = kept;
        }

        for (bob_builder.c_source_files.items) |c_path| {
            const base = std.fs.path.basename(c_path);
            const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dist_dir, base });
            defer allocator.free(dst);
            std.fs.cwd().copyFile(c_path, std.fs.cwd(), dst, .{}) catch {};
        }

        var bob_ll_parts = std.ArrayList(u8).init(allocator);
        defer bob_ll_parts.deinit();
        const lw = bob_ll_parts.writer();

        try lw.print("; Compiled boblang package '{s}'\n", .{pkg_name});
        {
            var gli = bob_builder.llvm.global_buffer.items;
            var gpos: usize = 0;
            while (gpos < gli.len) {
                if (gli[gpos] == '@') {
                    const start = gpos;
                    while (gpos < gli.len and gli[gpos] != '\n') gpos += 1;
                    const line = gli[start..gpos];
                    if (gpos < gli.len) gpos += 1;
                    if (std.mem.startsWith(u8, line, "@.str")) {
                        try lw.print("{s}\n", .{line});
                    }
                } else {
                    gpos += 1;
                }
            }
        }
        try lw.print("{s}", .{bob_builder.llvm.functions_buffer.items});

        var cmod_it = bob_builder.c_modules.iterator();
        while (cmod_it.next()) |cmod_entry| {
            var cm_it = cmod_entry.value_ptr.iterator();
            while (cm_it.next()) |cm_entry| {
                const cfunc = cm_entry.value_ptr.*;
                const needle = try std.fmt.allocPrint(allocator, "@{s}(", .{cfunc.name});
                defer allocator.free(needle);
                if (std.mem.indexOf(u8, bob_builder.llvm.functions_buffer.items, needle) == null) continue;
                const cret = c_parser.ctllvm(cfunc.return_type);
                try lw.print("declare {s} @{s}(", .{ cret, cfunc.name });
                for (cfunc.params, 0..) |cp, cpidx| {
                    if (cpidx > 0) try lw.writeAll(", ");
                    try lw.print("{s}", .{c_parser.ctllvm(cp.param_type)});
                }
                try lw.print(")\n", .{});
            }
        }

        const dst_ll_name = try std.fmt.allocPrint(allocator, "{s}/libboblang_package_{s}.ll", .{ dist_dir, pkg_name });
        defer allocator.free(dst_ll_name);
        var f = try std.fs.cwd().createFile(dst_ll_name, .{});
        defer f.close();
        try f.writer().print("{s}", .{bob_ll_parts.items});
    }

    {
        const pkg_json = pkg_builder.generatePackageJson(allocator, pkg_name, conf.version, all_functions.items, exports.items) catch |err| {
            std.debug.print("error: failed to generate package.json: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(pkg_json);
        const pkg_json_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{dist_dir});
        defer allocator.free(pkg_json_path);
        var f = try std.fs.cwd().createFile(pkg_json_path, .{});
        defer f.close();
        try f.writer().writeAll(pkg_json);
    }

    {
        const lib_bob_path = try std.fmt.allocPrint(allocator, "{s}/lib.bob", .{pkg_dir});
        defer allocator.free(lib_bob_path);
        const lib_bob_exists = if (std.fs.cwd().access(lib_bob_path, .{})) |_| true else |_| false;
        if (lib_bob_exists) {
            const dst_lib_bob = try std.fmt.allocPrint(allocator, "{s}/lib.bob", .{dist_dir});
            defer allocator.free(dst_lib_bob);
            std.fs.cwd().copyFile(lib_bob_path, std.fs.cwd(), dst_lib_bob, .{}) catch {};
        }
    }

    {
        const dst_conf = try std.fmt.allocPrint(allocator, "{s}/boblang.conf", .{dist_dir});
        defer allocator.free(dst_conf);
        try std.fs.cwd().copyFile(conf_path, std.fs.cwd(), dst_conf, .{});
    }

    {
        const src_mod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{pkg_dir});
        defer allocator.free(src_mod);
        if (std.fs.cwd().readFileAlloc(allocator, src_mod, 1024)) |mod_content| {
            defer allocator.free(mod_content);
            const dst_mod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{dist_dir});
            defer allocator.free(dst_mod);
            var f = try std.fs.cwd().createFile(dst_mod, .{});
            defer f.close();
            try f.writer().writeAll(mod_content);
            const src_sum = try std.fmt.allocPrint(allocator, "{s}/go.sum", .{pkg_dir});
            defer allocator.free(src_sum);
            if (std.fs.cwd().readFileAlloc(allocator, src_sum, 1024 * 1024)) |sum_content| {
                defer allocator.free(sum_content);
                const dst_sum = try std.fmt.allocPrint(allocator, "{s}/go.sum", .{dist_dir});
                defer allocator.free(dst_sum);
                var sf = try std.fs.cwd().createFile(dst_sum, .{});
                defer sf.close();
                try sf.writer().writeAll(sum_content);
            } else |_| {}
        } else |_| {}
    }

    bob_copy: {
        const dist_conf_content = std.fs.cwd().readFileAlloc(allocator, conf_path, 1024 * 1024) catch {
            break :bob_copy;
        };
        defer allocator.free(dist_conf_content);
        var dc = boblang_conf.parseBoblangConf(allocator, dist_conf_content) catch {
            break :bob_copy;
        };
        defer dc.deinit(allocator);
        for (dc.files) |f| {
            if (std.mem.endsWith(u8, f, ".bob") or std.mem.endsWith(u8, f, ".c") or std.mem.endsWith(u8, f, ".go")) {
                const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_dir, f });
                defer allocator.free(src);
                const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dist_dir, f });
                defer allocator.free(dst);
                const parent_dir = std.fs.path.dirname(dst) orelse "";
                if (parent_dir.len > 0) {
                    std.fs.cwd().makePath(parent_dir) catch {};
                }
                std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch {};
            }
        }
    }

    {
        const ver_dist = try std.fmt.allocPrint(allocator, "{s}/dist_v/{s}", .{ pkg_dir, conf.version });
        defer allocator.free(ver_dist);
        try std.fs.cwd().makePath(ver_dist);
        var iter_dir = std.fs.cwd().openDir(dist_dir, .{ .iterate = true }) catch return;
        defer iter_dir.close();
        var dit = iter_dir.iterate();
        while (try dit.next()) |entry| {
            if (entry.kind == .file) {
                const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dist_dir, entry.name });
                defer allocator.free(src);
                const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ver_dist, entry.name });
                defer allocator.free(dst);
                std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch {};
            }
        }
    }

    std.debug.print("Package '{s}' ({s}) built.\n", .{ pkg_name, conf.version });
    std.debug.print("  dist/\n", .{});
    std.debug.print("    package.json  - function signatures\n", .{});
    std.debug.print("    boblang.conf  - build config\n", .{});
    std.debug.print("    libboblang_package_{s}.ll - LLVM IR declarations\n", .{pkg_name});
    std.debug.print("    dist_v/{s}/\n", .{conf.version});
    std.debug.print("\nTo use: copy '{s}/dist/' to .boblang/packages/{s}/\n", .{ pkg_dir, pkg_name });
    std.debug.print("Then in your .bob file: import {s} as <alias>\n", .{pkg_name});
}

fn initProject(allocator: std.mem.Allocator) !void {
    if (std.fs.cwd().access("boblang.conf", .{})) {
        std.debug.print("boblang.conf already exists\n", .{});
        return;
    } else |_| {}

    const stdin = std.io.getStdIn().reader();
    const out = std.io.getStdOut().writer();

    try out.print("\n=== Boblang Project Setup ===\n\n", .{});

    try out.print("Dialect (syntax style):\n", .{});
    try out.print("  1) python-like  — indentation-based, Python-style (default)\n", .{});
    try out.print("  2) lua-like     — function/end blocks, -- comments, ~=, !=\n", .{});
    try out.print("  3) c-like       — braces, // comments, ; terminators\n", .{});
    try out.print("Enter choice [1-3] (default 1): ", .{});
    var dial: []const u8 = "python-like";
    {
        var buf: [32]u8 = undefined;
        const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n\t");
            if (std.mem.eql(u8, trimmed, "2")) {
                dial = "lua-like";
            }
            if (std.mem.eql(u8, trimmed, "3")) {
                dial = "c-like";
            }
            if (trimmed.len > 0 and trimmed[0] != '1' and !std.mem.eql(u8, trimmed, "2") and !std.mem.eql(u8, trimmed, "3")) {
                dial = trimmed;
            }
        }
    }

    try out.print("\nOutput binary name (default: myapp): ", .{});
    var output: []const u8 = "myapp";
    {
        var buf: [128]u8 = undefined;
        const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n\t");
            if (trimmed.len > 0) output = try allocator.dupe(u8, trimmed);
        }
    }

    try out.print("\nOptimization mode:\n", .{});
    try out.print("  1) ReleaseFast  — fast code, slower compile (default)\n", .{});
    try out.print("  2) ReleaseSafe  — safe code with runtime checks\n", .{});
    try out.print("  3) ReleaseSmall — smallest binary size\n", .{});
    try out.print("  4) Debug        — fast compile, no optimizations\n", .{});
    try out.print("Enter choice [1-4] (default 1): ", .{});
    var optimize: []const u8 = "ReleaseFast";
    {
        var buf: [32]u8 = undefined;
        const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n\t");
            if (std.mem.eql(u8, trimmed, "2")) {
                optimize = "ReleaseSafe";
            }
            if (std.mem.eql(u8, trimmed, "3")) {
                optimize = "ReleaseSmall";
            }
            if (std.mem.eql(u8, trimmed, "4")) {
                optimize = "Debug";
            }
            if (trimmed.len > 0 and trimmed[0] != '1' and !std.mem.eql(u8, trimmed, "2") and !std.mem.eql(u8, trimmed, "3") and !std.mem.eql(u8, trimmed, "4")) {
                optimize = trimmed;
            }
        }
    }

    try out.print("\nEntry source file (default: main.bob): ", .{});
    var entry: []const u8 = "main.bob";
    {
        var buf: [256]u8 = undefined;
        const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n\t");
            if (trimmed.len > 0) entry = try allocator.dupe(u8, trimmed);
        }
    }

    try out.print("\nLibraries to link (space-separated, e.g. GL glfw, or leave empty): ", .{});
    var libs: []const u8 = "";
    {
        var buf: [256]u8 = undefined;
        const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n\t");
            if (trimmed.len > 0) libs = trimmed;
        }
    }

    try out.print("\nTarget platform (leave empty for current OS): ", .{});
    var target: []const u8 = "";
    {
        var buf: [128]u8 = undefined;
        const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (line) |l| {
            const trimmed = std.mem.trim(u8, l, " \r\n\t");
            if (trimmed.len > 0) target = trimmed;
        }
    }

    var conf_buf = std.ArrayList(u8).init(allocator);
    defer conf_buf.deinit();
    const w = conf_buf.writer();
    try w.print("dialect: \"{s}\"\n", .{dial});
    try w.print("output: \"{s}\"\n", .{output});
    try w.print("optimize: \"{s}\"\n", .{optimize});
    try w.print("entry: \"{s}\"\n", .{entry});
    if (target.len > 0) try w.print("target: \"{s}\"\n", .{target});
    try w.print("packages: {{}}\n", .{});
    if (libs.len > 0) {
        try w.print("libs: {{\n", .{});
        var it = std.mem.splitSequence(u8, libs, " ");
        while (it.next()) |lib| {
            const trimmed = std.mem.trim(u8, lib, " ");
            if (trimmed.len > 0) try w.print("    {s}\n", .{trimmed});
        }
        try w.print("}}\n", .{});
    } else {
        try w.print("libs: {{}}\n", .{});
    }
    try w.print("files: {{}}\n", .{});

    var f = try std.fs.cwd().createFile("boblang.conf", .{});
    defer f.close();
    try f.writer().writeAll(conf_buf.items);

    std.debug.print("\nCreated boblang.conf with dialect={s}, output={s}\n", .{ dial, output });
    std.debug.print("Run 'boblang build .' to compile.\n", .{});
}

fn buildFromConf(allocator: std.mem.Allocator, conf: *const boblang_conf.BoblangConf, mode: Mode, extra_output: ?[]const u8, cli_target: ?[]const u8) !void {
    const cache = try bundle.ensureBoblangCache();
    try bundle.extractRuntimeToCache(allocator, cache);

    var pkg_ll_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (pkg_ll_paths.items) |f| allocator.free(f);
        pkg_ll_paths.deinit();
    }

    for (conf.packages) |pkg| {
        if (pkg.path.len > 0 and (pkg.path[0] == '.' or pkg.path[0] == '/')) {
            const cache_dist = try std.fmt.allocPrint(allocator, "{s}/{s}/dist", .{ cache.packages, pkg.alias });
            defer allocator.free(cache_dist);

            const pkg_real = std.fs.realpathAlloc(allocator, pkg.path) catch continue;
            defer allocator.free(pkg_real);

            const pkg_dist = try std.fmt.allocPrint(allocator, "{s}/dist", .{pkg_real});
            defer allocator.free(pkg_dist);
            try std.fs.cwd().makePath(cache_dist);

            const check_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{pkg_dist});
            const dist_exists = std.fs.cwd().openFile(check_path, .{}) catch null;
            allocator.free(check_path);
            if (dist_exists) |f| {
                f.close();
            } else {
                std.debug.print("error: '{s}' has no dist/ directory. Run 'boblang pack {s}' first.\n", .{ pkg.path, pkg.path });
                std.process.exit(1);
            }

            {
                const plain = [_][]const u8{ "package.json", "boblang.conf", "go.mod", "go.sum" };
                inline for (plain) |fname| {
                    const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_dist, fname });
                    defer allocator.free(src);
                    const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dist, fname });
                    defer allocator.free(dst);
                    std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch {};
                }
            }
            {
                const ll_name = try std.fmt.allocPrint(allocator, "libboblang_package_{s}.ll", .{pkg.alias});
                defer allocator.free(ll_name);
                const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_dist, ll_name });
                defer allocator.free(src);
                const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dist, ll_name });
                defer allocator.free(dst);
                std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch {};
                try pkg_ll_paths.append(try allocator.dupe(u8, dst));
            }
            bob_copy_to_cache: {
                const conf_in_dist = try std.fmt.allocPrint(allocator, "{s}/boblang.conf", .{pkg_dist});
                defer allocator.free(conf_in_dist);
                const cache_conf_content = std.fs.cwd().readFileAlloc(allocator, conf_in_dist, 1024 * 1024) catch break :bob_copy_to_cache;
                defer allocator.free(cache_conf_content);
                var dc = boblang_conf.parseBoblangConf(allocator, cache_conf_content) catch break :bob_copy_to_cache;
                defer dc.deinit(allocator);
                for (dc.files) |f| {
                    if (std.mem.endsWith(u8, f, ".bob") or std.mem.endsWith(u8, f, ".c") or std.mem.endsWith(u8, f, ".go")) {
                        const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_dist, f });
                        defer allocator.free(src);
                        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dist, f });
                        defer allocator.free(dst);
                        const parent = std.fs.path.dirname(dst) orelse "";
                        if (parent.len > 0) std.fs.cwd().makePath(parent) catch {};
                        std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch {};
                    }
                }
            }
        }
    }

    const files = if (conf.entry) |e|
        &[_][]const u8{e}
    else if (conf.files.len > 0)
        conf.files
    else
        &[_][]const u8{"main.bob"};
    const out_name = extra_output orelse conf.output;

    var b = Builder.initWithObfuscation(allocator, if (files.len > 0) files[0] else "main.bob", conf.obfuscate);
    defer b.deinit();
    try b.setConf(conf);

    const ParseResult = struct { tree: std.ArrayList(*dialect.AstNode), file: []const u8, source: []const u8, cleaned: []const u8 };
    var results = try allocator.alloc(ParseResult, files.len);

    const ThreadContext = struct {
        alloc: std.mem.Allocator,
        source: []const u8,
        dialect_name: []const u8,
        file: []const u8,
        result: *ParseResult,
    };

    var threads: std.ArrayList(std.Thread) = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    for (files, 0..) |file, i| {
        results[i] = .{ .tree = std.ArrayList(*dialect.AstNode).init(allocator), .file = file, .source = "", .cleaned = "" };
    }

    for (files, 0..) |file, i| {
        const source_code = std.fs.cwd().readFileAlloc(allocator, file, 1024 * 1024) catch |err| {
            std.debug.print("error [C5]: File Error\n  -> cannot read '{s}': {s}\n", .{ file, @errorName(err) });
            std.process.exit(1);
        };
        const ctx = try allocator.create(ThreadContext);
        ctx.* = .{
            .alloc = allocator,
            .source = source_code,
            .dialect_name = conf.dialect,
            .file = file,
            .result = &results[i],
        };
        const thread = try std.Thread.spawn(.{}, struct {
            fn parseFile(tc: *ThreadContext) void {
                const cleaned = std.mem.trim(u8, tc.source, " \n\r\t");
                var tree = dialect.parseToAst(tc.alloc, cleaned, tc.dialect_name) catch |err| {
                    errors.printCompileError(cleaned, @errorName(err));
                    std.process.exit(1);
                };
                optimizer.optimize(&tree, tc.alloc);
                tc.result.tree = tree;
                tc.result.source = tc.source;
                tc.result.cleaned = cleaned;
            }
        }.parseFile, .{ctx});
        try threads.append(thread);
    }

    for (threads.items) |*t| t.join();
    for (results) |r| {
        errors.setCurrentFile(r.file);
        errors.setCurrentSource(r.cleaned);
        for (r.tree.items) |node| {
            _ = try b.walkAstAndEmit(node);
        }
        dialect.freeAstTree(allocator, r.tree);
    }
    for (results) |r| allocator.free(r.source);

    try b.finalize();

    const raw_target = cli_target orelse conf.target;
    const effective_target = if (raw_target) |t| try xtgt(allocator, t) else null;
    try finalizeLnk(allocator, &b, cache, out_name, conf.optimize, effective_target, mode, false);
}

fn compileAndLink(allocator: std.mem.Allocator, cfg: Config) !void {
    const cache = try bundle.ensureBoblangCache();
    try bundle.extractRuntimeToCache(allocator, cache);

    errors.setCurrentFile(cfg.input);

    var dialect_name: []const u8 = cfg.dialect;
    if (std.mem.eql(u8, dialect_name, "python-like")) {
        if (boblang_conf.findBoblangConf(allocator)) |conf_src| {
            defer allocator.free(conf_src);
            var conf = boblang_conf.parseBoblangConf(allocator, conf_src) catch unreachable;
            dialect_name = try allocator.dupe(u8, conf.dialect);
            defer allocator.free(dialect_name);
            conf.deinit(allocator);
        }
    }

    const source_code = std.fs.cwd().readFileAlloc(allocator, cfg.input, 1024 * 1024) catch |err| {
        std.debug.print("error [C5]: File Error\n  -> cannot read '{s}': {s}\n", .{ cfg.input, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(source_code);
    const cleaned_source = std.mem.trim(u8, source_code, " \n\r\t");
    errors.setCurrentSource(cleaned_source);

    const out_basename = std.fs.path.basename(cfg.output);
    const marker_path = try std.fmt.allocPrint(allocator, "{s}/bobhash_{s}", .{ cache.cache, out_basename });
    defer allocator.free(marker_path);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(cleaned_source);
    hasher.update(dialect_name);
    hasher.update(cfg.optimize);
    if (cfg.target) |t| hasher.update(t);
    if (cfg.obfuscate) hasher.update("obf");
    const source_hash = hasher.final();

    if (!cfg.emit_llvm and try outputUpToDate(allocator, marker_path, source_hash, cfg.output)) {
        if (cfg.mode == .run) {
            const run_path = try std.fmt.allocPrint(allocator, "./{s}", .{cfg.output});
            var run_child = std.process.Child.init(&[_][]const u8{run_path}, allocator);
            _ = try run_child.spawnAndWait();
        }
        return;
    }

    const ir_file = try std.fmt.allocPrint(allocator, "{s}.ll", .{cfg.output});
    defer allocator.free(ir_file);

    progress.begin(4, std.fs.path.basename(cfg.input));

    progress.advance(1, "parsing");
    var ast_tree = dialect.parseToAst(allocator, cleaned_source, dialect_name) catch |err| {
        progress.clear();
        errors.printCompileError(cleaned_source, @errorName(err));
        std.process.exit(1);
    };
    defer dialect.freeAstTree(allocator, ast_tree);

    progress.advance(2, "optimizing");
    optimizer.optimize(&ast_tree, allocator);

    progress.advance(3, "compiling");
    var b = Builder.initWithObfuscation(allocator, cfg.input, cfg.obfuscate);
    defer b.deinit();

    if (boblang_conf.findBoblangConf(allocator)) |conf_src| {
        defer allocator.free(conf_src);
        var conf = boblang_conf.parseBoblangConf(allocator, conf_src) catch unreachable;
        b.setConf(&conf) catch {};
        conf.deinit(allocator);
    }

    for (ast_tree.items) |node| {
        _ = try b.walkAstAndEmit(node);
    }
    try b.finalize();

    if (cfg.emit_llvm) {
        const file = try std.fs.cwd().createFile(ir_file, .{});
        defer file.close();
        try file.writer().writeAll(b.llvm.global_buffer.items);
        for (b.package_ll_files.items) |pkg_ir| {
            try file.writer().writeAll(pkg_ir);
            try file.writer().writeByte('\n');
        }
        try file.writer().writeAll(b.llvm.functions_buffer.items);
        try file.writer().writeAll(b.llvm.closures_buffer.items);
        try file.writer().writeAll(b.llvm.code_buffer.items);
    }

    progress.advance(4, "linking");
    const raw_target = cfg.target;
    const effective_target = if (raw_target) |t| try xtgt(allocator, t) else null;
    try finalizeLnk(allocator, &b, cache, cfg.output, cfg.optimize, effective_target, cfg.mode, cfg.emit_llvm);
    progress.clear();
    if (!cfg.emit_llvm) try writeBuildMarker(allocator, marker_path, source_hash);
}

fn finalizeLnk(allocator: std.mem.Allocator, b: *Builder, cache: bundle.CacheDirs, output: []const u8, optimize: []const u8, target: ?[]const u8, mode: Mode, emit_llvm: bool) !void {
    if (emit_llvm) return;
    const ir_file = try std.fmt.allocPrint(allocator, "{s}.ll", .{output});
    defer allocator.free(ir_file);
    {
        const file = try std.fs.cwd().createFile(ir_file, .{});
        defer file.close();
        try file.writer().writeAll(b.llvm.global_buffer.items);
        for (b.package_ll_files.items) |pkg_ir| {
            try file.writer().writeAll(pkg_ir);
            try file.writer().writeByte('\n');
        }
        try file.writer().writeAll(b.llvm.functions_buffer.items);
        try file.writer().writeAll(b.llvm.closures_buffer.items);
        try file.writer().writeAll(b.llvm.code_buffer.items);
    }
    var link_args = std.ArrayList([]const u8).init(allocator);
    defer link_args.deinit();
    var linked_by_daemon = false;
    var native_ir_obj: ?[]const u8 = null;
    defer if (native_ir_obj) |o| allocator.free(o);
    const zig_path = try bundle.findBundledZig(allocator);
    const clang_avail = try hasCompiler(allocator, "clang");
    const lld_avail = try hasCompiler(allocator, "ld.lld");
    // IR gets translated into c which in turn recives better optmization than other stuff
    const use_native_clang = target == null and
        (zig_path != null or clang_avail or lld_avail) and
        @import("builtin").os.tag == .linux;
    const opt_flag = if (std.mem.eql(u8, optimize, "ReleaseFast") or std.mem.eql(u8, optimize, "ReleaseSmall")) "-O2" else if (std.mem.eql(u8, optimize, "ReleaseSafe")) "-O1" else "-O0";
    const is_wasm_target = target != null and (std.mem.indexOf(u8, target.?, "wasm") != null or std.mem.indexOf(u8, target.?, "wasi") != null);
    if (is_wasm_target) {
        const rt_c = try std.fmt.allocPrint(allocator, "{s}/runtime.c", .{cache.runtime});
        const gc_c = try std.fmt.allocPrint(allocator, "{s}/gc.c", .{cache.runtime});
        const final_output = output;
        if (zig_path) |zp| {
            try link_args.append(zp);
            try link_args.append("cc");
            try link_args.append("-target");
            try link_args.append(target.?);
            try link_args.append("-O1");
            try link_args.append(ir_file);
            try link_args.append(rt_c);
            try link_args.append(gc_c);
            for (b.c_source_files.items) |c_file| try link_args.append(c_file);
            for (b.go_object_files.items) |obj_file| try link_args.append(obj_file);
            try link_args.append("-lc");
            try link_args.append("-Wl,--no-entry");
            try link_args.append("-Wl,--export=__wasm_call_ctors");
            try link_args.append("-Wl,--export=boblang_js_alloc");
            try link_args.append("-Wl,--export=boblang_str_from_js");
            try link_args.append("-Wl,--export=boblang_js_str_len");
            try link_args.append("-Wl,--export=boblang_js_str_data");
            try link_args.append("-Wl,--export=boblang_int_new");
            try link_args.append("-Wl,--export=boblang_unbox_int");
            for (b.wasm_exports.items) |ex| {
                try link_args.append(try std.fmt.allocPrint(allocator, "-Wl,--export={s}", .{ex}));
            }
            try link_args.append("-o");
            try link_args.append(final_output);
        } else if (clang_avail) {
            try link_args.append("clang");
            try link_args.append("-target");
            try link_args.append(target.?);
            try link_args.append(opt_flag);
            try link_args.append(ir_file);
            try link_args.append(rt_c);
            try link_args.append(gc_c);
            for (b.c_source_files.items) |c_file| try link_args.append(c_file);
            for (b.go_object_files.items) |obj_file| try link_args.append(obj_file);
            try link_args.append("-lc");
            try link_args.append("-Wl,--no-entry");
            try link_args.append("-Wl,--export=__wasm_call_ctors");
            for (b.wasm_exports.items) |ex| {
                try link_args.append(try std.fmt.allocPrint(allocator, "-Wl,--export={s}", .{ex}));
            }
            try link_args.append("-o");
            try link_args.append(final_output);
        } else {
            std.debug.print("error [C6]: Compiler Error\n  -> no compiler found.\n", .{});
            std.process.exit(1);
        }
    } else if (use_native_clang) {
        // if clang is rpesent the use it cuz it optimizes stuff better
        const obj_dir = cache.cache;
        const base = std.fs.path.basename(output);
        const ir_obj = try std.fmt.allocPrint(allocator, "{s}/{s}.o", .{ obj_dir, base });
        native_ir_obj = ir_obj;
        std.fs.cwd().deleteFile(ir_obj) catch {};

        const pure_native = b.c_source_files.items.len == 0 and
            b.go_object_files.items.len == 0 and
            b.link_libs.items.len == 0 and
            !b.llvm.obfuscate;
        const use_fast_link = clang_avail and lld_avail and pure_native;

        if (use_fast_link) {
            _ = try ensureRuntimeObjects(allocator, cache, &[_][]const u8{"clang"});
            const rt_o = try std.fmt.allocPrint(allocator, "{s}/runtime.o", .{obj_dir});
            const gc_o = try std.fmt.allocPrint(allocator, "{s}/gc.o", .{obj_dir});
            const link_env = (try discoverLinkEnv(allocator)) orelse {
                std.debug.print("error [C7]: Compilation Failed\n  -> could not locate system crt/libc files for linking\n", .{});
                std.process.exit(1);
            };

            const opt_level: u32 = if (std.mem.eql(u8, optimize, "Debug")) 0 else if (std.mem.eql(u8, optimize, "ReleaseSafe")) 1 else 2;

            var daemon_link_args = std.ArrayList([]const u8).init(allocator);
            defer daemon_link_args.deinit();
            try daemon_link_args.append("-O0");
            try daemon_link_args.append(link_env.crt1);
            try daemon_link_args.append(link_env.crti);
            try daemon_link_args.append(ir_obj);
            try daemon_link_args.append(rt_o);
            try daemon_link_args.append(gc_o);
            try daemon_link_args.append("-L");
            try daemon_link_args.append(link_env.libdir);
            try daemon_link_args.append("-lc");
            try daemon_link_args.append("-lm");
            try daemon_link_args.append("-dynamic-linker");
            try daemon_link_args.append(link_env.ldso);
            try daemon_link_args.append(link_env.crtn);
            try daemon_link_args.append("-z");
            try daemon_link_args.append("stack-size=4294967296");
            try daemon_link_args.append("-o");
            try daemon_link_args.append(output);

            var used_daemon = false;
            if (bundle.findBoblangd(allocator)) |daemon_path| {
                defer allocator.free(daemon_path);
                const sock_path = try std.fmt.allocPrint(allocator, "{s}/boblangd.sock", .{cache.cache});
                defer allocator.free(sock_path);
                const ir_src = try buildIrString(allocator, b);
                defer allocator.free(ir_src);
                used_daemon = try tryDaemonCompile(allocator, daemon_path, sock_path, daemon_link_args.items, opt_level, ir_obj, ir_src);
            }

            if (used_daemon) {
                linked_by_daemon = true;
            } else {
                if (!try rok(allocator, &[_][]const u8{ "clang", opt_flag, "-c", ir_file, "-o", ir_obj })) {
                    std.debug.print("error [C7]: Compilation Failed\n  -> clang could not compile the generated IR\n", .{});
                    std.process.exit(1);
                }
                try link_args.append("ld.lld");
                try link_args.appendSlice(daemon_link_args.items);
            }
        } else if (clang_avail) {
            // fast path
            if (!try rok(allocator, &[_][]const u8{ "clang", opt_flag, "-c", ir_file, "-o", ir_obj })) {
                std.debug.print("error [C7]: Compilation Failed\n  -> clang could not compile the generated IR\n", .{});
                std.process.exit(1);
            }
            _ = try ensureRuntimeObjects(allocator, cache, &[_][]const u8{"clang"});
            try link_args.append("clang");
            try link_args.append(opt_flag);
            if (b.llvm.obfuscate) try link_args.append("-s");
            try link_args.append(ir_obj);
        } else {
            // do standalone
            var driver = std.ArrayList([]const u8).init(allocator);
            defer driver.deinit();
            if (zig_path) |zp| {
                try driver.append(zp);
                try driver.append("cc");
            } else {
                try driver.append("clang");
            }

            const c_file = try std.fmt.allocPrint(allocator, "{s}/{s}.c", .{ obj_dir, base });
            defer allocator.free(c_file);
            const ir_src = try std.fs.cwd().readFileAlloc(allocator, ir_file, 16 * 1024 * 1024);
            defer allocator.free(ir_src);
            var c_buf = std.ArrayList(u8).init(allocator);
            defer c_buf.deinit();
            const translated = llir2c.translate(allocator, ir_src, c_buf.writer()) catch null;
            if (translated == null) {
                std.debug.print("error [C7]: Compilation Failed\n  -> could not translate IR to C (no clang available)\n", .{});
                std.process.exit(1);
            }
            {
                const f = try std.fs.cwd().createFile(c_file, .{});
                defer f.close();
                try f.writer().writeAll(c_buf.items);
            }
            var compile_argv = std.ArrayList([]const u8).init(allocator);
            defer compile_argv.deinit();
            try compile_argv.appendSlice(driver.items);
            try compile_argv.append(opt_flag);
            try compile_argv.append("-c");
            try compile_argv.append(c_file);
            try compile_argv.append("-o");
            try compile_argv.append(ir_obj);
            if (!try rok(allocator, compile_argv.items)) {
                std.debug.print("error [C7]: Compilation Failed\n  -> {s} could not compile the generated C\n", .{driver.items[0]});
                std.process.exit(1);
            }
            if (!try ensureRuntimeObjects(allocator, cache, driver.items)) {
                std.debug.print("error [C7]: Compilation Failed\n  -> could not build the runtime objects\n", .{});
                std.process.exit(1);
            }
            try link_args.appendSlice(driver.items);
            try link_args.append(opt_flag);
            if (b.llvm.obfuscate) try link_args.append("-s");
            try link_args.append(ir_obj);
        }
        if (!use_fast_link) {
            const rt_o = try std.fmt.allocPrint(allocator, "{s}/runtime.o", .{obj_dir});
            const gc_o = try std.fmt.allocPrint(allocator, "{s}/gc.o", .{obj_dir});
            try link_args.append(rt_o);
            try link_args.append(gc_o);
            for (b.c_source_files.items) |csrc| try link_args.append(csrc);
            for (b.go_object_files.items) |obj_file| try link_args.append(obj_file);
            try link_args.append("-Wl,-z,stack-size=4294967296");
            try link_args.append("-o");
            try link_args.append(output);
            try link_args.append("-lm");
            for (b.link_libs.items) |lib| {
                const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib});
                try link_args.append(flag);
            }
        }
    } else if (zig_path) |zp| {
        const rt_c = try std.fmt.allocPrint(allocator, "{s}/runtime.c", .{cache.runtime});
        const gc_c = try std.fmt.allocPrint(allocator, "{s}/gc.c", .{cache.runtime});
        try link_args.append(zp);
        try link_args.append("build-exe");
        try link_args.append("-O");
        try link_args.append(optimize);
        if (b.llvm.obfuscate) try link_args.append("-strip");
        if (target) |t| {
            try link_args.append("-target");
            try link_args.append(t);
        }
        const is_wasm_link_target = target != null and (std.mem.indexOf(u8, target.?, "wasm") != null or std.mem.indexOf(u8, target.?, "wasi") != null);
        if (!is_wasm_link_target) {
            try link_args.append("--stack");
            try link_args.append("4294967296");
        }
        try link_args.append(ir_file);
        try link_args.append(rt_c);
        try link_args.append(gc_c);
        for (b.c_source_files.items) |c_file| try link_args.append(c_file);
        for (b.go_object_files.items) |obj_file| try link_args.append(obj_file);
        if (target == null or std.mem.indexOf(u8, target.?, "freestanding") == null) try link_args.append("-lc");
        for (b.link_libs.items) |lib| {
            const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib});
            try link_args.append(flag);
        }
        const base_name = std.fs.path.basename(output);
        try link_args.append("--name");
        try link_args.append(base_name);
        const needs_exe = target != null and std.mem.indexOf(u8, target.?, "windows") != null;
        const final_output = if (needs_exe) blk: {
            const name = try std.fmt.allocPrint(allocator, "{s}.exe", .{output});
            break :blk name;
        } else output;
        try link_args.append(try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{final_output}));
    } else if (clang_avail) {
        const rt_c = try std.fmt.allocPrint(allocator, "{s}/runtime.c", .{cache.runtime});
        const gc_c = try std.fmt.allocPrint(allocator, "{s}/gc.c", .{cache.runtime});
        try link_args.append("clang");
        if (target) |t| {
            try link_args.append("-target");
            try link_args.append(t);
        }
        try link_args.append(opt_flag);
        if (b.llvm.obfuscate) try link_args.append("-s");
        const is_wasm_clang_target = target != null and (std.mem.indexOf(u8, target.?, "wasm") != null or std.mem.indexOf(u8, target.?, "wasi") != null);
        if (!is_wasm_clang_target)
            try link_args.append("-Wl,-z,stack-size=4294967296");
        try link_args.append(ir_file);
        try link_args.append(rt_c);
        try link_args.append(gc_c);
        for (b.c_source_files.items) |c_file| try link_args.append(c_file);
        for (b.go_object_files.items) |obj_file| try link_args.append(obj_file);
        try link_args.append("-o");
        const needs_wasm_ext = target != null and std.mem.indexOf(u8, target.?, "wasi") != null;
        const needs_exe2 = target != null and std.mem.indexOf(u8, target.?, "windows") != null;
        const out_name = if (needs_wasm_ext) blk: {
            const name = try std.fmt.allocPrint(allocator, "{s}.wasm", .{output});
            break :blk name;
        } else if (needs_exe2) blk: {
            const name = try std.fmt.allocPrint(allocator, "{s}.exe", .{output});
            break :blk name;
        } else output;
        try link_args.append(out_name);
        if (target == null or (std.mem.indexOf(u8, target.?, "freestanding") == null and std.mem.indexOf(u8, target.?, "wasi") == null)) try link_args.append("-lm");
        for (b.link_libs.items) |lib| {
            const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib});
            try link_args.append(flag);
        }
    } else {
        std.debug.print("error [C6]: Compiler Error\n  -> no compiler found.\n", .{});
        std.process.exit(1);
    }
    if (!linked_by_daemon) {
        var child = std.process.Child.init(link_args.items, allocator);
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            switch (term) {
                .Exited => |c| std.debug.print("error [C7]: Compilation Failed\n  -> linker exited with code {d}\n", .{c}),
                .Signal => |s| std.debug.print("error [C7]: Compilation Failed\n  -> linker terminated by signal {d}\n", .{s}),
                else => std.debug.print("error [C7]: Compilation Failed\n  -> linker could not be run\n", .{}),
            }
            std.process.exit(1);
        }
    }
    if (!emit_llvm) {
        std.fs.cwd().deleteFile(ir_file) catch {};
        if (native_ir_obj) |o| std.fs.cwd().deleteFile(o) catch {};
        const pdb_file = try std.fmt.allocPrint(allocator, "{s}.pdb", .{output});
        defer allocator.free(pdb_file);
        std.fs.cwd().deleteFile(pdb_file) catch {};
    }
    if (mode == .run) {
        progress.clear();
        const run_path = try std.fmt.allocPrint(allocator, "./{s}", .{output});
        var run_child = std.process.Child.init(&[_][]const u8{run_path}, allocator);
        _ = try run_child.spawnAndWait();
        std.fs.cwd().deleteFile(output) catch {};
        const pdb_file2 = try std.fmt.allocPrint(allocator, "{s}.pdb", .{output});
        defer allocator.free(pdb_file2);
        std.fs.cwd().deleteFile(pdb_file2) catch {};
    }
}

var cached_clang: ?bool = null;
var cached_lld: ?bool = null;

fn hasCompiler(allocator: std.mem.Allocator, name: []const u8) !bool {
    if (std.mem.eql(u8, name, "clang")) {
        if (cached_clang) |v| return v;
    } else if (std.mem.eql(u8, name, "ld.lld")) {
        if (cached_lld) |v| return v;
    }
    const found = findOnPath(allocator, name) != null;
    if (std.mem.eql(u8, name, "clang")) {
        cached_clang = found;
    } else if (std.mem.eql(u8, name, "ld.lld")) {
        cached_lld = found;
    }
    return found;
}

fn isExecutable(full: []const u8) bool {
    if (builtin.os.tag == .windows) {
        std.fs.accessAbsolute(full, .{}) catch return false;
        return true;
    }
    std.posix.access(full, std.posix.X_OK) catch return false;
    return true;
}

fn findOnPath(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_env);
    const delim: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path_env, delim);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (dir.len + 1 + name.len >= buf.len) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (isExecutable(full)) return full;
        if (builtin.os.tag == .windows) {
            if (dir.len + 5 + name.len >= buf.len) continue;
            const full_exe = std.fmt.bufPrint(&buf, "{s}/{s}.exe", .{ dir, name }) catch continue;
            if (isExecutable(full_exe)) return full_exe;
        }
    }
    return null;
}

fn rok(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    var child = std.process.Child.init(argv, allocator);
    const term = try child.spawnAndWait();
    return term == .Exited and term.Exited == 0;
}

fn appendU32(buf: *std.ArrayList(u8), v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try buf.appendSlice(&tmp);
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = std.posix.write(fd, bytes[sent..]) catch return false;
        if (n == 0) return false;
        sent += n;
    }
    return true;
}

fn readFullFd(fd: std.posix.fd_t, buf: []u8) !bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.posix.read(fd, buf[got..]) catch return false;
        if (n == 0) return false;
        got += n;
    }
    return true;
}

fn readU32Fd(fd: std.posix.fd_t, v: *u32) !bool {
    var tmp: [4]u8 = undefined;
    if (!try readFullFd(fd, &tmp)) return false;
    v.* = std.mem.readInt(u32, &tmp, .little);
    return true;
}

fn spawnDaemon(daemon_path: []const u8, sock_path: []const u8) void {
    var child = std.process.Child.init(&[_][]const u8{ daemon_path, sock_path }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {};
}

fn connectDaemon(daemon_path: []const u8, sock_path: []const u8) ?std.posix.socket_t {
    var spawned = false;
    var attempts: usize = 0;
    while (attempts < 80) : (attempts += 1) {
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return null;
        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = [_]u8{0} ** 108 };
        if (sock_path.len >= addr.path.len) {
            std.posix.close(fd);
            return null;
        }
        @memcpy(addr.path[0..sock_path.len], sock_path);
        if (std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un))) |_| {
            return fd;
        } else |_| {
            std.posix.close(fd);
            if (!spawned) {
                spawned = true;
                spawnDaemon(daemon_path, sock_path);
            }
            std.time.sleep(25 * std.time.ns_per_ms);
        }
    }
    return null;
}

fn tryDaemonCompile(allocator: std.mem.Allocator, daemon_path: []const u8, sock_path: []const u8, link_args: []const []const u8, opt_level: u32, obj_path: []const u8, ir: []const u8) !bool {
    const fd = connectDaemon(daemon_path, sock_path) orelse return false;
    defer std.posix.close(fd);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try appendU32(&buf, @intCast(link_args.len));
    for (link_args) |a| {
        try appendU32(&buf, @intCast(a.len));
        try buf.appendSlice(a);
    }
    try appendU32(&buf, opt_level);
    try appendU32(&buf, @intCast(obj_path.len));
    try buf.appendSlice(obj_path);
    try appendU32(&buf, @intCast(ir.len));
    try buf.appendSlice(ir);

    if (!try writeAllFd(fd, buf.items)) return false;

    var status: u32 = 0;
    if (!try readU32Fd(fd, &status)) return false;
    var dlen: u32 = 0;
    if (!try readU32Fd(fd, &dlen)) return false;
    var remaining: usize = dlen;
    var tmp: [4096]u8 = undefined;
    while (remaining > 0) {
        const n = std.posix.read(fd, tmp[0..@min(remaining, tmp.len)]) catch break;
        if (n == 0) break;
        remaining -= n;
    }
    return status == 0;
}

fn buildIrString(allocator: std.mem.Allocator, b: *Builder) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try out.appendSlice(b.llvm.global_buffer.items);
    for (b.package_ll_files.items) |pkg_ir| {
        try out.appendSlice(pkg_ir);
        try out.append('\n');
    }
    try out.appendSlice(b.llvm.functions_buffer.items);
    try out.appendSlice(b.llvm.closures_buffer.items);
    try out.appendSlice(b.llvm.code_buffer.items);
    return try out.toOwnedSlice();
}

fn outputUpToDate(allocator: std.mem.Allocator, marker_path: []const u8, source_hash: u64, output: []const u8) !bool {
    if (std.fs.cwd().access(output, .{})) |_| {} else |_| return false;
    const m = std.fs.cwd().readFileAlloc(allocator, marker_path, 128) catch return false;
    defer allocator.free(m);
    const expected = try std.fmt.allocPrint(allocator, "{d}", .{source_hash});
    defer allocator.free(expected);
    return std.mem.eql(u8, std.mem.trim(u8, m, " \n\r\t"), expected);
}

fn writeBuildMarker(allocator: std.mem.Allocator, marker_path: []const u8, source_hash: u64) !void {
    _ = allocator;
    const f = try std.fs.cwd().createFile(marker_path, .{});
    defer f.close();
    try f.writer().print("{d}", .{source_hash});
}

fn ensureRuntimeObjects(allocator: std.mem.Allocator, cache: bundle.CacheDirs, driver: []const []const u8) !bool {
    const rt_dir = cache.runtime;
    const obj_dir = cache.cache;

    const rt_c = try std.fmt.allocPrint(allocator, "{s}/runtime.c", .{rt_dir});
    defer allocator.free(rt_c);
    const gc_c = try std.fmt.allocPrint(allocator, "{s}/gc.c", .{rt_dir});
    defer allocator.free(gc_c);
    const runtime_o = try std.fmt.allocPrint(allocator, "{s}/runtime.o", .{obj_dir});
    defer allocator.free(runtime_o);
    const gc_o = try std.fmt.allocPrint(allocator, "{s}/gc.o", .{obj_dir});
    defer allocator.free(gc_o);
    const marker = try std.fmt.allocPrint(allocator, "{s}/runtime_obj_hash", .{obj_dir});
    defer allocator.free(marker);

    const hash: u64 = blk: {
        var h = std.hash.Wyhash.init(0);
        const rt_src = std.fs.cwd().readFileAlloc(allocator, rt_c, 1024 * 1024) catch break :blk 0;
        defer allocator.free(rt_src);
        const gc_src = std.fs.cwd().readFileAlloc(allocator, gc_c, 1024 * 1024) catch break :blk 0;
        defer allocator.free(gc_src);
        h.update(rt_src);
        h.update(gc_src);
        break :blk h.final();
    };

    const expected = try std.fmt.allocPrint(allocator, "{d}", .{hash});
    defer allocator.free(expected);

    if (std.fs.cwd().readFileAlloc(allocator, marker, 64)) |m| {
        defer allocator.free(m);
        if (std.mem.eql(u8, std.mem.trim(u8, m, " \n\r\t"), expected)) {
            if (std.fs.cwd().access(runtime_o, .{})) |_| {
                if (std.fs.cwd().access(gc_o, .{})) |_| return true else |_| {}
            } else |_| {}
        }
    } else |_| {}

    std.fs.cwd().deleteFile(runtime_o) catch {};
    std.fs.cwd().deleteFile(gc_o) catch {};

    var rt_argv = std.ArrayList([]const u8).init(allocator);
    defer rt_argv.deinit();
    try rt_argv.appendSlice(driver);
    try rt_argv.append("-O2");
    try rt_argv.append("-c");
    try rt_argv.append(rt_c);
    try rt_argv.append("-o");
    try rt_argv.append(runtime_o);
    try rt_argv.append("-I");
    try rt_argv.append(rt_dir);

    var gc_argv = std.ArrayList([]const u8).init(allocator);
    defer gc_argv.deinit();
    try gc_argv.appendSlice(driver);
    try gc_argv.append("-O2");
    try gc_argv.append("-c");
    try gc_argv.append(gc_c);
    try gc_argv.append("-o");
    try gc_argv.append(gc_o);
    try gc_argv.append("-I");
    try gc_argv.append(rt_dir);

    if (!try rok(allocator, rt_argv.items)) return false;
    if (!try rok(allocator, gc_argv.items)) return false;

    const marker_f = std.fs.cwd().createFile(marker, .{}) catch return false;
    defer marker_f.close();
    marker_f.writer().print("{d}", .{hash}) catch {};
    return true;
}

const LinkEnv = struct {
    crt1: []const u8,
    crti: []const u8,
    crtn: []const u8,
    libdir: []const u8,
    ldso: []const u8,
};

fn checkFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !?[]const u8 {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    errdefer allocator.free(full);
    if (std.fs.cwd().access(full, .{})) |_| {
        return full;
    } else |_| {
        allocator.free(full);
        return null;
    }
}

fn findLdSo(allocator: std.mem.Allocator, dir: []const u8) !?[]const u8 {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return null;
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "ld-linux") and std.mem.indexOf(u8, entry.name, ".so") != null) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
        }
    }
    return null;
}

fn discoverLinkEnv(allocator: std.mem.Allocator) !?LinkEnv {
    const candidates = [_][]const u8{
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/usr/lib64",
        "/usr/lib",
        "/lib/x86_64-linux-gnu",
        "/lib64",
        "/lib",
    };
    var crt_dir: ?[]const u8 = null;
    var lib_dir: ?[]const u8 = null;
    var ldso: ?[]const u8 = null;
    for (candidates) |dir| {
        if (std.fs.cwd().access(dir, .{})) |_| {} else |_| continue;
        if (crt_dir == null and
            (try checkFile(allocator, dir, "crt1.o")) != null and
            (try checkFile(allocator, dir, "crti.o")) != null and
            (try checkFile(allocator, dir, "crtn.o")) != null)
        {
            crt_dir = try allocator.dupe(u8, dir);
        }
        if (lib_dir == null and (try checkFile(allocator, dir, "libc.so")) != null) {
            lib_dir = try allocator.dupe(u8, dir);
        }
        if (ldso == null) {
            ldso = try findLdSo(allocator, dir);
        }
        if (crt_dir != null and lib_dir != null and ldso != null) break;
    }
    if (crt_dir == null or lib_dir == null or ldso == null) return null;
    const crt1 = try std.fmt.allocPrint(allocator, "{s}/crt1.o", .{crt_dir.?});
    const crti = try std.fmt.allocPrint(allocator, "{s}/crti.o", .{crt_dir.?});
    const crtn = try std.fmt.allocPrint(allocator, "{s}/crtn.o", .{crt_dir.?});
    return LinkEnv{
        .crt1 = crt1,
        .crti = crti,
        .crtn = crtn,
        .libdir = lib_dir.?,
        .ldso = ldso.?,
    };
}

//expand target
fn xtgt(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (std.mem.count(u8, target, "-") >= 2) return try allocator.dupe(u8, target);
    if (std.mem.eql(u8, target, "linux") or std.mem.eql(u8, target, "x86_64-linux") or std.mem.eql(u8, target, "linux-gnu"))
        return try allocator.dupe(u8, "x86_64-linux-gnu");
    if (std.mem.eql(u8, target, "windows") or std.mem.eql(u8, target, "x86_64-windows"))
        return try allocator.dupe(u8, "x86_64-windows-gnu");
    if (std.mem.eql(u8, target, "macos") or std.mem.eql(u8, target, "x86_64-macos") or std.mem.eql(u8, target, "macos-none"))
        return try allocator.dupe(u8, "x86_64-macos-none");
    if (std.mem.eql(u8, target, "wasm32") or std.mem.eql(u8, target, "wasm32-wasi"))
        return try allocator.dupe(u8, "wasm32-wasi-musl");
    if (std.mem.eql(u8, target, "wasm64") or std.mem.eql(u8, target, "wasm64-wasi"))
        return try allocator.dupe(u8, "wasm64-wasi-musl");
    if (std.mem.eql(u8, target, "aarch64-linux") or std.mem.eql(u8, target, "arm64-linux"))
        return try allocator.dupe(u8, "aarch64-linux-gnu");
    return try allocator.dupe(u8, target);
}

fn dabi(arch: []const u8, os: []const u8) []const u8 {
    if (std.mem.eql(u8, os, "freestanding")) return "none";
    if (std.mem.eql(u8, os, "wasi")) return "musl";
    if (std.mem.eql(u8, os, "windows")) return "gnu";
    if (std.mem.eql(u8, os, "macos")) return "none";
    if (std.mem.eql(u8, os, "linux")) {
        if (std.mem.eql(u8, arch, "arm")) return "gnueabihf";
        return "gnu";
    }
    return "gnu";
}

fn bobpkgUsage() void {
    const help =
        \\bobpkg - boblang package manager
        \\
        \\Usage:
        \\  boblang pkg install <path-or-url> [alias] [-v <ver>]
        \\  boblang pkg update <package>
        \\  boblang pkg uninstall <package>
        \\  boblang pkg remove <package>
        \\  boblang pkg list
        \\
        \\Examples:
        \\  boblang pkg install ./my-package
        \\  boblang pkg install ./my-package myalias
        \\  boblang pkg install https:
        \\  boblang pkg install https://github.com/user/repo -v 0.1.0
        \\  boblang pkg update mypackage
        \\  boblang pkg uninstall mypackage
        \\  boblang pkg list
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn extractBasename(path: []const u8) []const u8 {
    var s = path;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |pos| s = s[pos + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, s, '\\')) |pos| s = s[pos + 1 ..];
    return s;
}

fn stripDotGit(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".git")) return name[0 .. name.len - 4];
    return name;
}

fn confHasPackage(conf_content: []const u8, pkg_name: []const u8) bool {
    var in_packages = false;
    var lines = std.mem.splitScalar(u8, conf_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "packages:")) {
            if (std.mem.endsWith(u8, line, "{}")) {
                return false;
            }
            in_packages = true;
            if (std.mem.indexOf(u8, line, "{")) |_| {} else continue;
        }
        if (in_packages) {
            if (line.len == 0 or std.mem.eql(u8, line, "}")) {
                in_packages = false;
                continue;
            }
            var path_part = line;
            var alias_part = line;
            if (std.mem.indexOf(u8, line, " as ")) |as_pos| {
                path_part = line[0..as_pos];
                alias_part = std.mem.trim(u8, line[as_pos + 4 ..], " \t");
            } else if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                path_part = line[0..colon_pos];
                alias_part = path_part;
            }
            path_part = std.mem.trim(u8, path_part, " \t");
            const entry_name = extractBasename(path_part);
            if (std.mem.eql(u8, entry_name, pkg_name)) return true;
            if (std.mem.eql(u8, alias_part, pkg_name)) return true;
        }
    }
    return false;
}

fn confAddPackage(allocator: std.mem.Allocator, conf_content: []const u8, pkg_path: []const u8, pkg_alias: []const u8) ![]const u8 {
    var entry_buf = std.ArrayList(u8).init(allocator);
    defer entry_buf.deinit();
    if (std.mem.eql(u8, pkg_path, pkg_alias)) {
        try entry_buf.writer().print("    {s}", .{pkg_path});
    } else {
        try entry_buf.writer().print("    {s} as {s}", .{ pkg_path, pkg_alias });
    }
    const entry = try entry_buf.toOwnedSlice();
    defer allocator.free(entry);

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, conf_content, '\n');
    var found_packages = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "packages:") and std.mem.endsWith(u8, line, "{}")) {
            found_packages = true;
            try result.writer().print("packages: {{\n{s}\n}}\n", .{entry});
            while (lines.next()) |skip| {
                const sl = std.mem.trim(u8, skip, " \t\r");
                if (sl.len > 0 and !std.mem.eql(u8, sl, "}")) {
                    try result.writer().print("{s}\n", .{skip});
                }
            }
            return try result.toOwnedSlice();
        }
        if (std.mem.startsWith(u8, line, "packages:") and std.mem.endsWith(u8, line, "{")) {
            found_packages = true;
            try result.writer().print("{s}\n", .{raw_line});
            var added = false;
            while (lines.next()) |inner| {
                const il = std.mem.trim(u8, inner, " \t\r");
                if (!added and (il.len == 0 or std.mem.eql(u8, il, "}"))) {
                    try result.writer().print("{s}\n", .{entry});
                    added = true;
                }
                try result.writer().print("{s}\n", .{inner});
                if (std.mem.eql(u8, il, "}")) break;
            }
            return try result.toOwnedSlice();
        }
        try result.writer().print("{s}\n", .{raw_line});
    }
    if (!found_packages) {
        try result.writer().print("packages: {{\n{s}\n}}\n", .{entry});
    }
    return try result.toOwnedSlice();
}

fn confRemovePackage(allocator: std.mem.Allocator, conf_content: []const u8, pkg_name: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var in_packages = false;
    var lines = std.mem.splitScalar(u8, conf_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "packages:")) {
            in_packages = true;
            try result.writer().print("{s}\n", .{raw_line});
            continue;
        }
        if (in_packages) {
            if (line.len == 0 or std.mem.eql(u8, line, "}")) {
                try result.writer().print("{s}\n", .{raw_line});
                in_packages = false;
                continue;
            }
            var path_part = line;
            if (std.mem.indexOf(u8, line, " as ")) |as_pos| {
                path_part = line[0..as_pos];
            } else if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                path_part = line[0..colon_pos];
            }
            path_part = std.mem.trim(u8, path_part, " \t");
            const entry_name = extractBasename(path_part);
            if (std.mem.eql(u8, entry_name, pkg_name)) continue;
        }
        try result.writer().print("{s}\n", .{raw_line});
    }
    return try result.toOwnedSlice();
}

fn copyDirContents(allocator: std.mem.Allocator, src_dir_path: []const u8, dst_dir_path: []const u8) !void {
    var src_dir = try std.fs.cwd().openDir(src_dir_path, .{ .iterate = true });
    defer src_dir.close();
    try std.fs.cwd().makePath(dst_dir_path);
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            const src_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir_path, entry.name });
            defer allocator.free(src_file_path);
            const dst_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_dir_path, entry.name });
            defer allocator.free(dst_file_path);
            try std.fs.cwd().copyFile(src_file_path, std.fs.cwd(), dst_file_path, .{});
        } else if (entry.kind == .directory) {
            const sub_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir_path, entry.name });
            defer allocator.free(sub_src);
            const sub_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_dir_path, entry.name });
            defer allocator.free(sub_dst);
            try copyDirContents(allocator, sub_src, sub_dst);
        }
    }
}

fn isLocalPath(source: []const u8) bool {
    return source.len > 0 and (source[0] == '.' or source[0] == '/');
}

fn isGitUrl(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "http") or std.mem.startsWith(u8, source, "git@") or std.mem.startsWith(u8, source, "file://");
}

fn findConfPath() ?[]const u8 {
    const candidates = [_][]const u8{ "boblang.conf", "Boblang.conf" };
    for (candidates) |name| {
        if (std.fs.cwd().access(name, .{})) {
            return name;
        } else |_| {}
    }
    return null;
}

fn bobpkgInstall(allocator: std.mem.Allocator, source: []const u8, alias_override: ?[]const u8, version: ?[]const u8) !void {
    const conf_path = findConfPath() orelse {
        std.debug.print("error: no boblang.conf found in current directory\n", .{});
        std.process.exit(1);
    };

    const alias = alias_override orelse blk: {
        if (isLocalPath(source)) {
            const base = extractBasename(source);
            break :blk stripDotGit(base);
        } else if (isGitUrl(source)) {
            const base = extractBasename(source);
            break :blk stripDotGit(base);
        } else {
            break :blk source;
        }
    };

    if (isLocalPath(source)) {
        const real_path = std.fs.realpathAlloc(allocator, source) catch |err| {
            std.debug.print("error: cannot resolve path '{s}': {s}\n", .{ source, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(real_path);

        const dist_path = try std.fmt.allocPrint(allocator, "{s}/dist", .{real_path});
        defer allocator.free(dist_path);

        if (std.fs.cwd().access(dist_path, .{})) {} else |_| {
            std.debug.print("error: '{s}' has no dist/ directory. Run 'boblang pack {s}' first.\n", .{ source, source });
            std.process.exit(1);
        }

        const cache_dist = try std.fmt.allocPrint(allocator, ".boblang/packages/{s}/dist", .{alias});
        defer allocator.free(cache_dist);

        try std.fs.cwd().makePath(".boblang/packages");
        try copyDirContents(allocator, dist_path, cache_dist);

        const conf_content = try std.fs.cwd().readFileAlloc(allocator, conf_path, 1024 * 1024);
        defer allocator.free(conf_content);

        if (confHasPackage(conf_content, alias)) {
            std.debug.print("Package '{s}' is already installed.\n", .{alias});
            return;
        }

        const new_conf = try confAddPackage(allocator, conf_content, source, alias);
        defer allocator.free(new_conf);

        {
            const f = try std.fs.cwd().createFile(conf_path, .{});
            defer f.close();
            try f.writer().writeAll(new_conf);
        }

        std.debug.print("Installed package '{s}' from '{s}'\n", .{ alias, source });
    } else if (isGitUrl(source)) {
        const tmp_dir = try std.fmt.allocPrint(allocator, ".boblang/_tmp_{s}", .{alias});
        defer allocator.free(tmp_dir);

        try std.fs.cwd().makePath(".boblang");

        var clone_args = std.ArrayList([]const u8).init(allocator);
        defer clone_args.deinit();
        try clone_args.append("git");
        try clone_args.append("clone");
        try clone_args.append("--depth");
        try clone_args.append("1");
        if (version) |v| {
            try clone_args.append("--branch");
            try clone_args.append(v);
        }
        try clone_args.append(source);
        try clone_args.append(tmp_dir);
        std.debug.print("Cloning {s}...\n", .{source});
        var clone_child = std.process.Child.init(clone_args.items, allocator);
        clone_child.stdout_behavior = .Inherit;
        clone_child.stderr_behavior = .Inherit;
        const clone_term = try clone_child.spawnAndWait();
        if (clone_term != .Exited or clone_term.Exited != 0) {
            std.debug.print("error: git clone failed\n", .{});
            std.process.exit(1);
        }

        try bobpkgPackEx(allocator, tmp_dir, alias, null);

        const real_tmp = std.fs.realpathAlloc(allocator, tmp_dir) catch |err| {
            std.debug.print("error: cannot resolve temp dir: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(real_tmp);

        const dist_path = try std.fmt.allocPrint(allocator, "{s}/dist", .{real_tmp});
        defer allocator.free(dist_path);
        const cache_dist = try std.fmt.allocPrint(allocator, ".boblang/packages/{s}/dist", .{alias});
        defer allocator.free(cache_dist);

        try std.fs.cwd().makePath(".boblang/packages");
        try copyDirContents(allocator, dist_path, cache_dist);

        const conf_content = try std.fs.cwd().readFileAlloc(allocator, conf_path, 1024 * 1024);
        defer allocator.free(conf_content);

        if (!confHasPackage(conf_content, alias)) {
            const new_conf = try confAddPackage(allocator, conf_content, source, alias);
            defer allocator.free(new_conf);
            {
                const f = try std.fs.cwd().createFile(conf_path, .{});
                defer f.close();
                try f.writer().writeAll(new_conf);
            }
        }

        var rm_args = [_][]const u8{ "rm", "-rf", tmp_dir };
        var rm_child = std.process.Child.init(&rm_args, allocator);
        _ = try rm_child.spawnAndWait();

        std.debug.print("Installed package '{s}' from '{s}'\n", .{ alias, source });
    } else {
        std.debug.print("error: '{s}' is not a valid local path or git URL\n", .{source});
        std.process.exit(1);
    }
}

fn bobpkgList() !void {
    const packages_dir = ".boblang/packages";
    var dir = std.fs.cwd().openDir(packages_dir, .{ .iterate = true }) catch {
        std.debug.print("No packages installed.\n", .{});
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            std.debug.print("  {s}\n", .{entry.name});
            count += 1;
        }
    }
    if (count == 0) {
        std.debug.print("No packages installed.\n", .{});
    }
}

fn bobpkgRemove(allocator: std.mem.Allocator, pkg_name: []const u8) !void {
    const cache_dir = try std.fmt.allocPrint(allocator, ".boblang/packages/{s}", .{pkg_name});
    defer allocator.free(cache_dir);

    var rm_args = [_][]const u8{ "rm", "-rf", cache_dir };
    var rm_child = std.process.Child.init(&rm_args, allocator);
    _ = try rm_child.spawnAndWait();

    const conf_path = findConfPath() orelse {
        std.debug.print("Removed cached package '{s}'. No boblang.conf found.\n", .{pkg_name});
        return;
    };

    const conf_content = try std.fs.cwd().readFileAlloc(allocator, conf_path, 1024 * 1024);
    defer allocator.free(conf_content);

    const new_conf = try confRemovePackage(allocator, conf_content, pkg_name);
    defer allocator.free(new_conf);

    {
        const f = try std.fs.cwd().createFile(conf_path, .{});
        defer f.close();
        try f.writer().writeAll(new_conf);
    }

    std.debug.print("Removed package '{s}'\n", .{pkg_name});
}

fn confUsage() void {
    const help =
        \\boblang.conf reference
        \\
        \\The boblang.conf file configures your project. Uses simple "key: value" format.
        \\Strings may be quoted ("value") or bare (value). Lists use { ... } braces.
        \\
        \\Fields:
        \\  dialect       Language dialect (default: "python-like")
        \\  output        Output binary name (default: "output")
        \\  optimize      Optimization mode: Debug, ReleaseFast, ReleaseSafe, ReleaseSmall
        \\                  (default: "ReleaseFast")
        \\  version       Package version string (default: "0.1.0")
        \\  entry         Main source file (replaces "files" list)
        \\  files         List of source files (.bob, .c, .go)
        \\  target        Cross-compilation target triple or shorthand:
        \\                  Full triple: "arch-vendor-os"  e.g. "x86_64-windows-gnu"
        \\                  Shorthands:
        \\                    "linux"      -> x86_64-linux-gnu
        \\                    "windows"    -> x86_64-windows-gnu
        \\                    "macos"      -> x86_64-macos-none
        \\                    "wasm32"     -> wasm32-wasi-musl
        \\                    "wasm64"     -> wasm64-wasi-musl
        \\                  Cross-compiling requires system libraries for the target.
        \\                  For example, --target windows needs mingw-w64 versions of
        \\                  any -l libraries (like GL, glfw).
        \\                  Leave unset to build for your current system.
        \\  libs          System libraries to link: { GL glfw }
        \\                  These must be available for the target platform.
        \\  packages      Package dependencies: { path as alias }
        \\  (any custom key is accessible at compile time via conf.key)
        \\
        \\Examples:
        \\  # Build for current system (no target set)
        \\  output: "myapp"
        \\  entry: "main.bob"
        \\  libs: { GL glfw }
        \\
        \\  # Cross-compile for Windows (needs mingw-w64 GL and glfw)
        \\  output: "myapp"
        \\  target: "windows"
        \\  libs: { GL glfw }
        \\
        \\  # WebAssembly (no external libs needed)
        \\  output: "myapp"
        \\  target: "wasm32"
        \\  libs: {}
        \\
    ;
    std.debug.print("{s}", .{help});
    std.process.exit(0);
}

fn bobpkgUpdate(allocator: std.mem.Allocator, pkg_name: []const u8) !void {
    const conf_path = findConfPath() orelse {
        std.debug.print("error: no boblang.conf found in current directory\n", .{});
        std.process.exit(1);
    };
    const conf_content = try std.fs.cwd().readFileAlloc(allocator, conf_path, 1024 * 1024);
    defer allocator.free(conf_content);
    var conf = try boblang_conf.parseBoblangConf(allocator, conf_content);
    defer conf.deinit(allocator);

    for (conf.packages) |pkg| {
        if (std.mem.eql(u8, pkg.alias, pkg_name)) {
            _ = try bobpkgRemove(allocator, pkg_name);
            return try bobpkgInstall(allocator, pkg.path, pkg_name, null);
        }
    }
    std.debug.print("error: package '{s}' not found in boblang.conf\n", .{pkg_name});
}

fn printLicenses() !void {
    const out = std.io.getStdOut().writer();
    try out.writeAll(BOBLANG_LICENSE);
    try out.writeAll("\n\n---\n\n");
    try out.writeAll(THIRD_PARTY_LICENSES);
}

fn usage() void {
    const help =
        \\boblang compiler  v0.4.0
        \\
        \\Usage:
        \\  boblang <command> [file|conf] [options]
        \\
        \\Commands:
        \\  build [file] [opts]   Compile to a native binary
        \\  run   [file] [opts]   Compile and run immediately
        \\  init                  Interactive project setup (creates boblang.conf)
        \\  pack <dir> [-v <ver>] Build a distributable package from a directory
        \\  pkg install <path|url> [alias] [-v <ver>]
        \\                        Install a package (local dir or git URL)
        \\  pkg update <pkg>      Reinstall a package to the latest version
        \\  pkg remove <pkg>      Remove an installed package
        \\  pkg uninstall <pkg>   Alias for remove
        \\  pkg list              List all installed packages
        \\  conf                  Show boblang.conf field reference
        \\  --licenses            Show Boblang and third-party licenses
        \\  help | -h | --help    Show this help screen
        \\
        \\When file is '.' or 'conf', or when omitted and boblang.conf exists,
        \\settings are read from boblang.conf instead of CLI flags.
        \\
        \\Build & Run Options:
        \\  -o, --output <f>      Output filename (default: from boblang.conf or "output")
        \\  -t, --target <triple> LLVM target triple, e.g.:
        \\                           x86_64-linux-gnu      (Linux)
        \\                           x86_64-windows-gnu    (Windows)
        \\                           x86_64-macos-none     (macOS Intel)
        \\                           aarch64-macos-none    (macOS Apple Silicon)
        \\                           wasm32-wasi-musl      (WebAssembly)
        \\  -O <mode>             Optimization: Debug, ReleaseFast, ReleaseSafe,
        \\                           ReleaseSmall  (default: ReleaseFast)
        \\      --emit-llvm       Keep the intermediate .ll file after building
        \\      --dialect <d>     Syntax dialect: python-like (default), lua-like, c-like
        \\      --obfuscate       Obfuscate the output: encrypt string literals,
        \\                          junk function symbols, strip the symbol table,
        \\                          and replace source paths with hash tokens
        \\
        \\Target Shorthands:
        \\      --linux           --arch x86_64 --os linux
        \\      --windows         --arch x86_64 --os windows  (adds .exe)
        \\      --macos           --arch x86_64 --os macos
        \\      --wasm            --arch wasm32 --os wasi
        \\      --wasm64          --arch wasm64 --os wasi
        \\      --arch <arch>     x86_64, aarch64, arm, wasm32, wasm64
        \\      --os <os>         linux, windows, macos, freestanding, wasi
        \\
        \\Dialects:
        \\  python-like  Indentation-based (Python-style), default
        \\  lua-like     func/end blocks, -- comments, ~=, !=, not, elseif
        \\  c-like       Braces, // comments, ; terminators, &&, ||, !
        \\
        \\Package Manager:
        \\  pkg install <path|url> [alias] [-v <ver>]
        \\    Install a package from a local path or git URL.
        \\    Use -v to specify a Git tag/branch.
        \\  pkg update <pkg>      Re-download and rebuild a package
        \\  pkg remove <pkg>      Uninstall a package
        \\  pkg list              Show installed packages
        \\
        \\Examples:
        \\  boblang run hello.bob
        \\  boblang build hello.bob --windows -o hello.exe
        \\  boblang build .                     (uses boblang.conf)
        \\  boblang run .                       (uses boblang.conf)
        \\  boblang build app.bob --wasm -o app.wasm
        \\  boblang build app.bob --dialect lua-like
        \\  boblang pack ./mylib -v 1.0.0
        \\  boblang pkg install ./mylib myalias
        \\  boblang pkg install https://github.com/user/repo -v 0.1.0
        \\
    ;
    std.debug.print("{s}", .{help});
    std.process.exit(0);
}
