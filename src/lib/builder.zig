const std = @import("std");
const LlvmBuilder = @import("llvm_builder.zig").LlvmBuilder;
const AstNode = @import("parser.zig").AstNode;
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const c_parser = @import("c_parser.zig");
const bundle = @import("../bundle_config.zig");
const boblang_conf = @import("../boblang_conf.zig");
const package_builder = @import("package_builder.zig");
const go_parser = @import("go_parser.zig");
const progress = @import("progress.zig");

const RECURSION_LIMIT: i64 = 10_000_000;

const BobModule = struct {
    exports: std.StringHashMap([]const u8),
    arities: std.StringHashMap(ModuleArity),
};

const ModuleArity = struct {
    declared: u32,
    required: u32,
};

pub const Builder = struct {
    llvm: LlvmBuilder,
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(std.StringHashMap([]const u8)),
    is_inside_func: bool,
    func_ended: bool,
    current_func_recursion_checked: bool,
    current_func_loop_head: ?[]const u8 = null,
    current_func_name: ?[]const u8 = null,
    current_func_arg_slots: std.ArrayList([]const u8) = undefined,
    current_class_name: []const u8,
    current_class_has_base: bool = false,
    is_inside_closure: bool = false,
    loop_end_stack: std.ArrayList(u32),
    filename: []const u8,
    current_file: []const u8,
    c_modules: std.StringHashMap(std.StringHashMap(c_parser.CFunction)),
    c_source_files: std.ArrayList([]const u8),
    go_object_files: std.ArrayList([]const u8),
    wasm_exports: std.ArrayList([]const u8),
    int_list_vars: std.StringHashMap([]const u8),
    float_list_vars: std.StringHashMap([]const u8),
    bool_list_vars: std.StringHashMap([]const u8),
    raw_int_vars: std.StringHashMap([]const u8),
    raw_float_vars: std.StringHashMap([]const u8),
    raw_bool_vars: std.StringHashMap([]const u8),
    raw_warned: bool = false,
    link_libs: std.ArrayList([]const u8),
    bob_modules: std.StringHashMap(BobModule),
    package_ll_files: std.ArrayList([]const u8),
    current_module_prefix: ?[]const u8 = null,
    int_scopes: std.ArrayList(std.StringHashMap([]const u8)),
    float_scopes: std.ArrayList(std.StringHashMap([]const u8)),
    known_funcs: std.StringHashMap([]const u8),
    known_funcs_arity: std.StringHashMap(u32),
    known_funcs_required_arity: std.StringHashMap(u32),
    emitted_funcs: std.StringHashMap(usize),
    importing_files: std.StringHashMap(void),
    last_line: usize = 0,
    declared_types: std.ArrayList(std.StringHashMap([]const u8)),
    conf_values: std.StringHashMap([]const u8),
    builtin_thunks: std.StringHashMap([]const u8),
    nullable_vars: std.StringHashMap(void),
    enum_types: std.StringHashMap(void),
    generic_list_elem_types: std.StringHashMap([]const u8),
    current_func_ret_type: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, filename: []const u8) Builder {
        var self = initCommon(allocator, filename);
        self.llvm.emitHeader(filename) catch {};
        return self;
    }

    pub fn initWithObfuscation(allocator: std.mem.Allocator, filename: []const u8, obfuscate: bool) Builder {
        var self = initCommon(allocator, filename);
        self.llvm.obfuscate = obfuscate;
        self.llvm.emitHeader(filename) catch {};
        return self;
    }

    pub fn setConf(self: *Builder, conf: *const boblang_conf.BoblangConf) !void {
        var cit = conf.custom.iterator();
        while (cit.next()) |entry| {
            try self.conf_values.put(try self.allocator.dupe(u8, entry.key_ptr.*), try self.allocator.dupe(u8, entry.value_ptr.*));
        }
    }

    pub fn initPackage(allocator: std.mem.Allocator, filename: []const u8, pkg_prefix: []const u8) Builder {
        var self = initCommon(allocator, filename);
        self.llvm.str_prefix = pkg_prefix;
        self.llvm.emitPackageHeader() catch {};
        return self;
    }

    fn initCommon(allocator: std.mem.Allocator, filename: []const u8) Builder {
        var self = Builder{
            .llvm = LlvmBuilder.init(allocator),
            .allocator = allocator,
            .scopes = std.ArrayList(std.StringHashMap([]const u8)).init(allocator),
            .is_inside_func = false,
            .func_ended = false,
            .current_func_recursion_checked = false,
            .current_func_arg_slots = std.ArrayList([]const u8).init(allocator),
            .current_class_name = "",
            .loop_end_stack = std.ArrayList(u32).init(allocator),
            .filename = filename,
            .current_file = filename,
            .c_modules = std.StringHashMap(std.StringHashMap(c_parser.CFunction)).init(allocator),
            .c_source_files = std.ArrayList([]const u8).init(allocator),
            .go_object_files = std.ArrayList([]const u8).init(allocator),
            .wasm_exports = std.ArrayList([]const u8).init(allocator),
            .int_list_vars = std.StringHashMap([]const u8).init(allocator),
            .float_list_vars = std.StringHashMap([]const u8).init(allocator),
            .bool_list_vars = std.StringHashMap([]const u8).init(allocator),
            .raw_int_vars = std.StringHashMap([]const u8).init(allocator),
            .raw_float_vars = std.StringHashMap([]const u8).init(allocator),
            .raw_bool_vars = std.StringHashMap([]const u8).init(allocator),
            .link_libs = std.ArrayList([]const u8).init(allocator),
            .bob_modules = std.StringHashMap(BobModule).init(allocator),
            .package_ll_files = std.ArrayList([]const u8).init(allocator),
            .int_scopes = std.ArrayList(std.StringHashMap([]const u8)).init(allocator),
            .float_scopes = std.ArrayList(std.StringHashMap([]const u8)).init(allocator),
            .known_funcs = std.StringHashMap([]const u8).init(allocator),
            .known_funcs_arity = std.StringHashMap(u32).init(allocator),
            .known_funcs_required_arity = std.StringHashMap(u32).init(allocator),
            .emitted_funcs = std.StringHashMap(usize).init(allocator),
            .importing_files = std.StringHashMap(void).init(allocator),
            .declared_types = std.ArrayList(std.StringHashMap([]const u8)).init(allocator),
            .conf_values = std.StringHashMap([]const u8).init(allocator),
            .nullable_vars = std.StringHashMap(void).init(allocator),
            .enum_types = std.StringHashMap(void).init(allocator),
            .generic_list_elem_types = std.StringHashMap([]const u8).init(allocator),
            .builtin_thunks = builtinThunks: {
                var m = std.StringHashMap([]const u8).init(allocator);
                _ = m.put("print", "FUNC_PRINT") catch {};
                _ = m.put("input", "FUNC_INPUT") catch {};
                _ = m.put("int", "FUNC_INT") catch {};
                _ = m.put("float", "FUNC_FLOAT") catch {};
                _ = m.put("str", "FUNC_STR") catch {};
                _ = m.put("bool", "FUNC_BOOL") catch {};
                _ = m.put("type", "FUNC_TYPE") catch {};
                _ = m.put("len", "FUNC_LEN") catch {};
                _ = m.put("range", "FUNC_RANGE") catch {};
                _ = m.put("min", "FUNC_MIN") catch {};
                _ = m.put("max", "FUNC_MAX") catch {};
                _ = m.put("clamp", "FUNC_CLAMP") catch {};
                _ = m.put("ascii", "FUNC_ASCII") catch {};
                _ = m.put("chr", "FUNC_CHR") catch {};
                _ = m.put("get_args", "FUNC_GET_ARGS") catch {};
                break :builtinThunks m;
            },
        };
        const global_scope = std.StringHashMap([]const u8).init(allocator);
        self.scopes.append(global_scope) catch {};
        const global_int_scope = std.StringHashMap([]const u8).init(allocator);
        self.int_scopes.append(global_int_scope) catch {};
        const global_float_scope = std.StringHashMap([]const u8).init(allocator);
        self.float_scopes.append(global_float_scope) catch {};
        const global_decl_type = std.StringHashMap([]const u8).init(allocator);
        self.declared_types.append(global_decl_type) catch {};
        return self;
    }

    pub fn deinit(self: *Builder) void {
        for (self.scopes.items) |*scope|
            scope.deinit();
        self.scopes.deinit();
        self.loop_end_stack.deinit();
        for (self.int_scopes.items) |*scope|
            scope.deinit();
        self.int_scopes.deinit();
        for (self.float_scopes.items) |*scope|
            scope.deinit();
        self.float_scopes.deinit();
        {
            var it = self.conf_values.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.conf_values.deinit();
            self.builtin_thunks.deinit();
        }
        {
            var it = self.nullable_vars.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.nullable_vars.deinit();
        }
        {
            var it = self.enum_types.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.enum_types.deinit();
        }
        {
            var it = self.generic_list_elem_types.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.generic_list_elem_types.deinit();
        }
        var cmod_it = self.c_modules.iterator();
        while (cmod_it.next()) |entry| {
            c_parser.dcfuns(self.allocator, entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.c_modules.deinit();
        for (self.c_source_files.items) |f| self.allocator.free(f);
        self.c_source_files.deinit();
        for (self.go_object_files.items) |f| self.allocator.free(f);
        self.go_object_files.deinit();
        for (self.link_libs.items) |l| self.allocator.free(l);
        self.link_libs.deinit();
        for (self.package_ll_files.items) |f| self.allocator.free(f);
        self.package_ll_files.deinit();
        var bmod_it = self.bob_modules.iterator();
        while (bmod_it.next()) |entry| {
            var mod = entry.value_ptr;
            var ex_it = mod.exports.iterator();
            while (ex_it.next()) |ex_entry| {
                self.allocator.free(ex_entry.key_ptr.*);
                self.allocator.free(ex_entry.value_ptr.*);
            }
            mod.exports.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.bob_modules.deinit();
        {
            var it = self.known_funcs.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.known_funcs.deinit();
        }
        self.known_funcs_arity.deinit();
        self.known_funcs_required_arity.deinit();
        self.current_func_arg_slots.deinit();
        {
            var it = self.emitted_funcs.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.emitted_funcs.deinit();
        }
        self.importing_files.deinit();
        for (self.declared_types.items) |*dt| dt.deinit();
        self.declared_types.deinit();
        self.llvm.deinit();
    }

    pub fn pushScope(self: *Builder) !void {
        try self.scopes.append(std.StringHashMap([]const u8).init(self.allocator));
        try self.int_scopes.append(std.StringHashMap([]const u8).init(self.allocator));
        try self.float_scopes.append(std.StringHashMap([]const u8).init(self.allocator));
        try self.declared_types.append(std.StringHashMap([]const u8).init(self.allocator));
    }

    fn emitScopeRelease(_: *Builder) !void {}

    pub fn popScope(self: *Builder) void {
        if (self.scopes.items.len > 1) {
            var scope = self.scopes.pop();
            scope.deinit();
        }
        if (self.int_scopes.items.len > 1) {
            var iscope = self.int_scopes.pop();
            iscope.deinit();
        }
        if (self.float_scopes.items.len > 1) {
            var fscope = self.float_scopes.pop();
            fscope.deinit();
        }
        if (self.declared_types.items.len > 1) {
            var dscope = self.declared_types.pop();
            dscope.deinit();
        }
    }

    pub fn execAssign(self: *Builder, name: []const u8, val_reg: []const u8) !void {
        var current_scope = &self.scopes.items[self.scopes.items.len - 1];
        try current_scope.put(name, val_reg);
    }

    pub fn execLookup(self: *Builder, name: []const u8) ?[]const u8 {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |stack_ptr| return stack_ptr;
        }
        return null;
    }

    fn execDeclType(self: *Builder, name: []const u8, type_name: []const u8) !void {
        const current = &self.declared_types.items[self.declared_types.items.len - 1];
        try current.put(name, type_name);
    }

    fn lookupDeclType(self: *Builder, name: []const u8) ?[]const u8 {
        var i: usize = self.declared_types.items.len;
        while (i > 0) {
            i -= 1;
            if (self.declared_types.items[i].get(name)) |t| return t;
        }
        return null;
    }

    fn execAssignInt(self: *Builder, name: []const u8, alloca_reg: []const u8) !void {
        const current = &self.int_scopes.items[self.int_scopes.items.len - 1];
        try current.put(name, alloca_reg);
    }

    fn execLookupInt(self: *Builder, name: []const u8) ?[]const u8 {
        var i: usize = self.int_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.int_scopes.items[i].get(name)) |stack_ptr| return stack_ptr;
        }
        return null;
    }

    fn execAssignIntList(self: *Builder, name: []const u8, slot: []const u8) !void {
        try self.int_list_vars.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, slot));
    }

    fn execLookupIntList(self: *Builder, name: []const u8) ?[]const u8 {
        return self.int_list_vars.get(name);
    }

    fn execLookupFloatList(self: *Builder, name: []const u8) ?[]const u8 {
        return self.float_list_vars.get(name);
    }

    fn execLookupBoolList(self: *Builder, name: []const u8) ?[]const u8 {
        return self.bool_list_vars.get(name);
    }

    fn execAssignRaw(self: *Builder, which: u8, name: []const u8, slot: []const u8) !void {
        if (which == 'i') {
            try self.raw_int_vars.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, slot));
        } else if (which == 'f') {
            try self.raw_float_vars.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, slot));
        } else {
            try self.raw_bool_vars.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, slot));
        }
    }

    fn execLookupRaw(self: *Builder, which: u8, name: []const u8) ?[]const u8 {
        if (which == 'i') {
            return self.raw_int_vars.get(name);
        } else if (which == 'f') {
            return self.raw_float_vars.get(name);
        }
        return self.raw_bool_vars.get(name);
    }

    fn warnRawType(self: *Builder) void {
        if (!self.raw_warned) {
            progress.clear();
            std.debug.print("warning: raw arrays are unguarded (no bounds checking) and error-prone\n", .{});
            self.raw_warned = true;
        }
    }

    fn emitIntListLoadRaw(self: *Builder, list_reg: []const u8, idx_int: []const u8) ![]const u8 {
        const lbl_id = self.llvm.reg_count;
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".il_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        const oob_lbl = try std.fmt.allocPrint(self.allocator, ".il_oob_{d}", .{lbl_id});
        defer self.allocator.free(oob_lbl);
        const end_lbl = try std.fmt.allocPrint(self.allocator, ".il_end_{d}", .{lbl_id});
        defer self.allocator.free(end_lbl);
        const lst = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load {{ i32, i32, i32, i32, ptr }}, ptr {s}, align 8\n", .{ lst, list_reg });
        const size = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 2\n", .{ size, lst });
        const size_se = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ size_se, size });
        const oob1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp sge i64 {s}, {s}\n", .{ oob1, idx_int, size_se });
        const neg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp slt i64 {s}, 0\n", .{ neg, idx_int });
        const bad = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i1 {s}, {s}\n", .{ bad, oob1, neg });
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ bad, oob_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        const items = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 4\n", .{ items, lst });
        const gep = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = getelementptr i64, ptr {s}, i64 {s}\n", .{ gep, items, idx_int });
        const val = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ val, gep });
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{oob_lbl});
        const zero = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i64 0, 0\n", .{zero});
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{end_lbl});
        const res = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = phi i64 [{s}, %{s}], [{s}, %{s}]\n", .{ res, zero, oob_lbl, val, ok_lbl });
        return res;
    }

    fn emitIntListStoreRaw(self: *Builder, list_reg: []const u8, idx_int: []const u8, val_int: []const u8) !void {
        const lbl_id = self.llvm.reg_count;
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".ils_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        const end_lbl = try std.fmt.allocPrint(self.allocator, ".ils_end_{d}", .{lbl_id});
        defer self.allocator.free(end_lbl);
        const lst = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load {{ i32, i32, i32, i32, ptr }}, ptr {s}, align 8\n", .{ lst, list_reg });
        const size = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 2\n", .{ size, lst });
        const size_se = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ size_se, size });
        const oob1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp sge i64 {s}, {s}\n", .{ oob1, idx_int, size_se });
        const neg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp slt i64 {s}, 0\n", .{ neg, idx_int });
        const bad = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i1 {s}, {s}\n", .{ bad, oob1, neg });
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ bad, end_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        const items = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 4\n", .{ items, lst });
        const gep = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = getelementptr i64, ptr {s}, i64 {s}\n", .{ gep, items, idx_int });
        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ val_int, gep });
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{end_lbl});
    }

    fn emitFloatListLoadRaw(self: *Builder, list_reg: []const u8, idx_int: []const u8) ![]const u8 {
        const lbl_id = self.llvm.reg_count;
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".fl_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        const oob_lbl = try std.fmt.allocPrint(self.allocator, ".fl_oob_{d}", .{lbl_id});
        defer self.allocator.free(oob_lbl);
        const end_lbl = try std.fmt.allocPrint(self.allocator, ".fl_end_{d}", .{lbl_id});
        defer self.allocator.free(end_lbl);
        const lst = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load {{ i32, i32, i32, i32, ptr }}, ptr {s}, align 8\n", .{ lst, list_reg });
        const size = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 2\n", .{ size, lst });
        const size_se = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ size_se, size });
        const oob1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp sge i64 {s}, {s}\n", .{ oob1, idx_int, size_se });
        const neg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp slt i64 {s}, 0\n", .{ neg, idx_int });
        const bad = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i1 {s}, {s}\n", .{ bad, oob1, neg });
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ bad, oob_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        const items = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 4\n", .{ items, lst });
        const gep = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = getelementptr double, ptr {s}, i64 {s}\n", .{ gep, items, idx_int });
        const val = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load double, ptr {s}, align 8\n", .{ val, gep });
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{oob_lbl});
        const zero = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = fadd double 0.0, 0.0\n", .{zero});
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{end_lbl});
        const res = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = phi double [{s}, %{s}], [{s}, %{s}]\n", .{ res, zero, oob_lbl, val, ok_lbl });
        return res;
    }

    fn emitFloatListStoreRaw(self: *Builder, list_reg: []const u8, idx_int: []const u8, val_float: []const u8) !void {
        const lbl_id = self.llvm.reg_count;
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".fls_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        const end_lbl = try std.fmt.allocPrint(self.allocator, ".fls_end_{d}", .{lbl_id});
        defer self.allocator.free(end_lbl);
        const lst = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load {{ i32, i32, i32, i32, ptr }}, ptr {s}, align 8\n", .{ lst, list_reg });
        const size = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 2\n", .{ size, lst });
        const size_se = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ size_se, size });
        const oob1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp sge i64 {s}, {s}\n", .{ oob1, idx_int, size_se });
        const neg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp slt i64 {s}, 0\n", .{ neg, idx_int });
        const bad = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i1 {s}, {s}\n", .{ bad, oob1, neg });
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ bad, end_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        const items = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 4\n", .{ items, lst });
        const gep = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = getelementptr double, ptr {s}, i64 {s}\n", .{ gep, items, idx_int });
        try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ val_float, gep });
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{end_lbl});
    }

    fn emitBoolListLoadRaw(self: *Builder, list_reg: []const u8, idx_int: []const u8) ![]const u8 {
        const lbl_id = self.llvm.reg_count;
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".bl_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        const oob_lbl = try std.fmt.allocPrint(self.allocator, ".bl_oob_{d}", .{lbl_id});
        defer self.allocator.free(oob_lbl);
        const end_lbl = try std.fmt.allocPrint(self.allocator, ".bl_end_{d}", .{lbl_id});
        defer self.allocator.free(end_lbl);
        const lst = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load {{ i32, i32, i32, i32, ptr }}, ptr {s}, align 8\n", .{ lst, list_reg });
        const size = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 2\n", .{ size, lst });
        const size_se = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ size_se, size });
        const oob1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp sge i64 {s}, {s}\n", .{ oob1, idx_int, size_se });
        const neg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp slt i64 {s}, 0\n", .{ neg, idx_int });
        const bad = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i1 {s}, {s}\n", .{ bad, oob1, neg });
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ bad, oob_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        const items = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 4\n", .{ items, lst });
        const gep = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ gep, items, idx_int });
        const raw = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load i8, ptr {s}, align 1\n", .{ raw, gep });
        const ext = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = zext i8 {s} to i64\n", .{ ext, raw });
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{oob_lbl});
        const zero = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i64 0, 0\n", .{zero});
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{end_lbl});
        const res = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = phi i64 [{s}, %{s}], [{s}, %{s}]\n", .{ res, zero, oob_lbl, ext, ok_lbl });
        return res;
    }

    fn emitBoolListStoreRaw(self: *Builder, list_reg: []const u8, idx_int: []const u8, val_int: []const u8) !void {
        const lbl_id = self.llvm.reg_count;
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".bls_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        const end_lbl = try std.fmt.allocPrint(self.allocator, ".bls_end_{d}", .{lbl_id});
        defer self.allocator.free(end_lbl);
        const lst = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load {{ i32, i32, i32, i32, ptr }}, ptr {s}, align 8\n", .{ lst, list_reg });
        const size = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 2\n", .{ size, lst });
        const size_se = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ size_se, size });
        const oob1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp sge i64 {s}, {s}\n", .{ oob1, idx_int, size_se });
        const neg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp slt i64 {s}, 0\n", .{ neg, idx_int });
        const bad = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = or i1 {s}, {s}\n", .{ bad, oob1, neg });
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ bad, end_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        const items = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = extractvalue {{ i32, i32, i32, i32, ptr }} {s}, 4\n", .{ items, lst });
        const gep = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ gep, items, idx_int });
        const trunc = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = trunc i64 {s} to i8\n", .{ trunc, val_int });
        try self.getWriter().print("  store i8 {s}, ptr {s}, align 1\n", .{ trunc, gep });
        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
        try self.getWriter().print("\n{s}:\n", .{end_lbl});
    }

    fn execAssignFloat(self: *Builder, name: []const u8, alloca_reg: []const u8) !void {
        const current = &self.float_scopes.items[self.float_scopes.items.len - 1];
        try current.put(name, alloca_reg);
    }

    fn execLookupFloat(self: *Builder, name: []const u8) ?[]const u8 {
        var i: usize = self.float_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.float_scopes.items[i].get(name)) |stack_ptr| return stack_ptr;
        }
        return null;
    }

    fn makeTint(self: *Builder, val: i64) ![]const u8 {
        const reg = try self.llvm.nextRegister();
        const tagged = (@as(i64, @intCast(val)) << 1) | 1;
        try self.getWriter().print("  {s} = inttoptr i64 {d} to ptr\n", .{ reg, tagged });
        return reg;
    }

    fn boxIntToPtr(self: *Builder, int_reg: []const u8) ![]const u8 {
        const shifted = try self.llvm.nextRegister();
        const tmp = try self.llvm.nextRegister();
        const reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ shifted, int_reg });
        try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ tmp, shifted });
        try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, tmp });
        return reg;
    }

    fn tryEmitAsInt(self: *Builder, node: *AstNode) anyerror!?[]const u8 {
        switch (node.node_type) {
            .val_int => {
                if (node.val_int == 0 and node.val_string.len > 1) return null;
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = or i64 0, {d}\n", .{ reg, node.val_int });
                return reg;
            },
            .var_ref => {
                if (node.target != null or node.name.len == 0 or std.mem.containsAtLeast(u8, node.name, 1, ".")) return null;
                if (std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    const lb = std.mem.indexOfScalar(u8, node.name, '[') orelse return null;
                    if (!std.mem.endsWith(u8, node.name, "]")) return null;
                    if (std.mem.indexOfPos(u8, node.name, lb + 1, "[") != null) return null;
                    const root = node.name[0..lb];
                    const idx_expr = node.name[lb + 1 .. node.name.len - 1];
                    if (self.execLookupRaw('i', root)) |rslot| {
                        self.warnRawType();
                        const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                        defer parser.freeAstNode(self.allocator, idx_node);
                        const idx_i64 = (try self.tryEmitAsInt(idx_node)) orelse return null;
                        const rreg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                        const gp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = getelementptr i64, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                        const raw = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ raw, gp });
                        return raw;
                    }
                    if (self.execLookupRaw('b', root)) |rslot| {
                        self.warnRawType();
                        const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                        defer parser.freeAstNode(self.allocator, idx_node);
                        const idx_i64 = (try self.tryEmitAsInt(idx_node)) orelse return null;
                        const rreg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                        const gp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                        const raw = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load i8, ptr {s}, align 1\n", .{ raw, gp });
                        const ext = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = zext i8 {s} to i64\n", .{ ext, raw });
                        return ext;
                    }
                    return null;
                }
                if (self.execLookupInt(node.name)) |stack_ptr| {
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ reg, stack_ptr });
                    return reg;
                }
                return null;
            },
            .int_div, .add, .sub, .mul, .mod => {
                const lhs = try self.tryEmitAsInt(node.args.?.items[0]) orelse return null;
                const rhs = try self.tryEmitAsInt(node.args.?.items[1]) orelse return null;
                if (node.node_type == .mod or node.node_type == .int_div) {
                    const rhs_node = node.args.?.items[1];
                    if (rhs_node.node_type == .val_int and rhs_node.val_int == 0) {
                        return try self.makeTint(0);
                    }
                    if (rhs_node.node_type == .val_int) {
                        const op = if (node.node_type == .int_div) "sdiv" else "srem";
                        const div_res = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ div_res, op, lhs, rhs });
                        return div_res;
                    }
                    const id = self.llvm.reg_count;
                    const zero_lbl = try std.fmt.allocPrint(self.allocator, "tei_zero_{d}", .{id});
                    const ok_lbl = try std.fmt.allocPrint(self.allocator, "tei_ok_{d}", .{id});
                    const end_lbl = try std.fmt.allocPrint(self.allocator, "tei_end_{d}", .{id});
                    defer self.allocator.free(zero_lbl);
                    defer self.allocator.free(ok_lbl);
                    defer self.allocator.free(end_lbl);
                    const zero = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = icmp eq i64 {s}, 0\n", .{ zero, rhs });
                    const op = if (node.node_type == .int_div) "sdiv" else "srem";
                    const div_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ zero, zero_lbl, ok_lbl });
                    try self.getWriter().print("\n{s}:\n", .{zero_lbl});
                    try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                    try self.getWriter().print("\n{s}:\n", .{ok_lbl});
                    try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ div_res, op, lhs, rhs });
                    try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                    try self.getWriter().print("\n{s}:\n", .{end_lbl});
                    const phi_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = phi i64 [0, %{s}], [{s}, %{s}]\n", .{ phi_res, zero_lbl, div_res, ok_lbl });
                    return phi_res;
                }
                const op = switch (node.node_type) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    else => unreachable,
                };
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ reg, op, lhs, rhs });
                return reg;
            },
            .call => {
                if (std.mem.eql(u8, node.name, "__getitem__")) {
                    if (node.target) |t| {
                        if (t.node_type == .var_ref and t.target == null) {
                            if (node.args) |args| {
                                if (try self.tryEmitAsInt(args.items[0])) |idx_int| {
                                    if (self.execLookupRaw('i', t.name)) |rslot| {
                                        self.warnRawType();
                                        const rreg = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                                        const gp = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = getelementptr i64, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_int });
                                        const raw = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ raw, gp });
                                        return raw;
                                    }
                                    if (self.execLookupRaw('b', t.name)) |rslot| {
                                        self.warnRawType();
                                        const rreg = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                                        const gp = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_int });
                                        const raw = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = load i8, ptr {s}, align 1\n", .{ raw, gp });
                                        const ext = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = zext i8 {s} to i64\n", .{ ext, raw });
                                        return ext;
                                    }
                                    if (self.execLookupIntList(t.name)) |slot| {
                                        const list_reg = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ list_reg, slot });
                                        return try self.emitIntListLoadRaw(list_reg, idx_int);
                                    }
                                    if (self.execLookupBoolList(t.name)) |slot| {
                                        const list_reg = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ list_reg, slot });
                                        return try self.emitBoolListLoadRaw(list_reg, idx_int);
                                    }
                                }
                            }
                        }
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    fn boxFloatToPtr(self: *Builder, float_reg: []const u8) ![]const u8 {
        const fbits = try self.llvm.nextRegister();
        const fclear = try self.llvm.nextRegister();
        const ftag = try self.llvm.nextRegister();
        const reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = bitcast double {s} to i64\n", .{ fbits, float_reg });
        try self.getWriter().print("  {s} = and i64 {s}, -8\n", .{ fclear, fbits });
        try self.getWriter().print("  {s} = or i64 {s}, 4\n", .{ ftag, fclear });
        try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, ftag });
        return reg;
    }

    fn tryEmitAsFloat(self: *Builder, node: *AstNode) anyerror!?[]const u8 {
        switch (node.node_type) {
            .val_float => {
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = fadd double 0.0, {d:.17}\n", .{ reg, node.val_float });
                return reg;
            },
            .val_int => {
                if (node.val_int == 0 and node.val_string.len > 1) return null;
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = sitofp i64 {d} to double\n", .{ reg, node.val_int });
                return reg;
            },
            .var_ref => {
                if (node.target != null or node.name.len == 0 or std.mem.containsAtLeast(u8, node.name, 1, ".")) return null;
                if (std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    const lb = std.mem.indexOfScalar(u8, node.name, '[') orelse return null;
                    if (!std.mem.endsWith(u8, node.name, "]")) return null;
                    if (std.mem.indexOfPos(u8, node.name, lb + 1, "[") != null) return null;
                    const root = node.name[0..lb];
                    const idx_expr = node.name[lb + 1 .. node.name.len - 1];
                    if (self.execLookupRaw('f', root)) |rslot| {
                        self.warnRawType();
                        const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                        defer parser.freeAstNode(self.allocator, idx_node);
                        const idx_i64 = (try self.tryEmitAsInt(idx_node)) orelse return null;
                        const rreg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                        const gp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = getelementptr double, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                        const raw = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load double, ptr {s}, align 8\n", .{ raw, gp });
                        return raw;
                    }
                    return null;
                }
                if (self.execLookupFloat(node.name)) |stack_ptr| {
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load double, ptr {s}, align 8\n", .{ reg, stack_ptr });
                    return reg;
                }
                if (self.execLookupInt(node.name)) |stack_ptr| {
                    const ireg = try self.llvm.nextRegister();
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ ireg, stack_ptr });
                    try self.getWriter().print("  {s} = sitofp i64 {s} to double\n", .{ reg, ireg });
                    return reg;
                }
                return null;
            },
            .add, .sub, .mul, .div => {
                const lhs = try self.tryEmitAsFloat(node.args.?.items[0]) orelse return null;
                const rhs = try self.tryEmitAsFloat(node.args.?.items[1]) orelse return null;
                const op = switch (node.node_type) {
                    .add => "fadd",
                    .sub => "fsub",
                    .mul => "fmul",
                    .div => "fdiv",
                    else => unreachable,
                };
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = {s} double {s}, {s}\n", .{ reg, op, lhs, rhs });
                return reg;
            },
            .int_div => {
                return null;
            },
            else => return null,
        }
    }

    fn emitZero(self: *Builder) ![]const u8 {
        return try self.makeTint(0);
    }

    fn emitLoadGlobal(self: *Builder, global_name: []const u8) ![]const u8 {
        const reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load ptr, ptr @{s}, align 8\n", .{ reg, global_name });
        return reg;
    }

    fn emitOptionalGet(self: *Builder, obj_reg: []const u8, prop: []const u8) ![]const u8 {
        const is_null = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp eq ptr {s}, null\n", .{ is_null, obj_reg });
        const lbl_id = self.llvm.reg_count;
        const skip = try std.fmt.allocPrint(self.allocator, ".opt_skip_{d}", .{lbl_id});
        const cont = try std.fmt.allocPrint(self.allocator, ".opt_cont_{d}", .{lbl_id});
        const end = try std.fmt.allocPrint(self.allocator, ".opt_end_{d}", .{lbl_id});
        defer self.allocator.free(skip);
        defer self.allocator.free(cont);
        defer self.allocator.free(end);
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_null, skip, cont });
        try self.getWriter().print("\n{s}:\n", .{skip});
        const null_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{null_reg});
        try self.getWriter().print("  br label %{s}\n", .{end});
        try self.getWriter().print("\n{s}:\n", .{cont});
        const prop_str_reg = try self.emitPropString(prop);
        const prop_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_get_property(ptr {s}, ptr {s})\n", .{ prop_reg, obj_reg, prop_str_reg });
        try self.getWriter().print("  br label %{s}\n", .{end});
        try self.getWriter().print("\n{s}:\n", .{end});
        const result = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = phi ptr [%s_null, %{s}], [%s_prop, %{s}]\n", .{ result, skip, cont });
        return result;
    }

    fn emitOptionalCall(self: *Builder, obj_reg: []const u8, method: []const u8, arg_regs: *std.ArrayList([]const u8)) ![]const u8 {
        const is_null = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp eq ptr {s}, null\n", .{ is_null, obj_reg });
        const lbl_id = self.llvm.reg_count;
        const skip = try std.fmt.allocPrint(self.allocator, ".opt_skip_{d}", .{lbl_id});
        const cont = try std.fmt.allocPrint(self.allocator, ".opt_cont_{d}", .{lbl_id});
        const end = try std.fmt.allocPrint(self.allocator, ".opt_end_{d}", .{lbl_id});
        defer self.allocator.free(skip);
        defer self.allocator.free(cont);
        defer self.allocator.free(end);
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_null, skip, cont });
        try self.getWriter().print("\n{s}:\n", .{skip});
        const null_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{null_reg});
        try self.getWriter().print("  br label %{s}\n", .{end});
        try self.getWriter().print("\n{s}:\n", .{cont});
        const method_str_reg = try self.emitPropString(method);
        const call_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_method_va(ptr {s}, ptr {s}, i32 {d}", .{ call_reg, obj_reg, method_str_reg, arg_regs.items.len });
        for (arg_regs.items) |arg_reg| {
            try self.getWriter().print(", ptr {s}", .{arg_reg});
        }
        try self.getWriter().print(")\n", .{});
        try self.getWriter().print("  br label %{s}\n", .{end});
        try self.getWriter().print("\n{s}:\n", .{end});
        const result = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = phi ptr [%s_null, %{s}], [%s_call, %{s}]\n", .{ result, skip, cont });
        return result;
    }

    fn estr(self: *Builder, val: []const u8) ![]const u8 {
        if (self.llvm.obfuscate) {
            const key = LlvmBuilder.obfuscatedKey(val);
            const str_addr = try self.llvm.buildObfuscatedString(val, key);
            const reg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = call ptr @boblang_str_new_x(ptr {s}, i32 {d}, i32 {d})\n", .{ reg, str_addr, val.len, key });
            return reg;
        }
        const str_addr = try self.llvm.buildGlobalString(val);
        const reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_str_new(ptr {s})\n", .{ reg, str_addr });
        return reg;
    }

    fn emitStrConstant(self: *Builder, val: []const u8) ![]const u8 {
        return try self.estr(val);
    }

    fn junkName(self: *Builder, name: []const u8) ![]const u8 {
        if (!self.llvm.obfuscate) return name;
        var h: u64 = 1469598103934665603;
        for (name) |c| {
            h ^= c;
            h = h *% 1099511628211;
        }
        return try std.fmt.allocPrint(self.allocator, "b{x}", .{h & 0xffffffffffff});
    }

    fn fileToken(self: *Builder) ![]const u8 {
        if (!self.llvm.obfuscate) return self.current_file;
        const tok = LlvmBuilder.obfuscatedFileToken(self.current_file);
        return try self.allocator.dupe(u8, tok[0..16]);
    }

    fn emitPropString(self: *Builder, prop: []const u8) ![]const u8 {
        if (std.mem.eql(u8, prop, "length")) return try self.emitLoadGlobal("STR_LENGTH");
        if (std.mem.eql(u8, prop, "__class__")) return try self.emitLoadGlobal("STR_CLASS");
        if (std.mem.eql(u8, prop, "__bases__")) return try self.emitLoadGlobal("STR_BASES");
        if (std.mem.eql(u8, prop, "__name__")) return try self.emitLoadGlobal("STR_NAME");
        if (std.mem.eql(u8, prop, "_init_")) return try self.emitLoadGlobal("STR_INIT");
        if (std.mem.eql(u8, prop, "__call__")) return try self.emitLoadGlobal("STR_CALL");
        if (std.mem.eql(u8, prop, " ")) return try self.emitLoadGlobal("STR_SPACE");
        if (std.mem.eql(u8, prop, "\n")) return try self.emitLoadGlobal("STR_NEWLINE");
        return try self.estr(prop);
    }

    fn tryEmitCondAsI1(self: *Builder, node: *AstNode) anyerror!?[]const u8 {
        switch (node.node_type) {
            .eq, .ne, .lt, .gt, .le, .ge => {
                const lhs = try self.tryEmitAsInt(node.args.?.items[0]) orelse return null;
                const rhs = try self.tryEmitAsInt(node.args.?.items[1]) orelse return null;
                const cmp = switch (node.node_type) {
                    .eq => "icmp eq",
                    .ne => "icmp ne",
                    .lt => "icmp slt",
                    .gt => "icmp sgt",
                    .le => "icmp sle",
                    .ge => "icmp sge",
                    else => unreachable,
                };
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ reg, cmp, lhs, rhs });
                return reg;
            },
            else => return null,
        }
    }

    fn emitTruthyCheck(self: *Builder, cond_reg: []const u8) ![]const u8 {
        const tok = try self.llvm.nextRegister();
        const result = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call i32 @boblang_is_truthy(ptr {s})\n", .{ tok, cond_reg });
        try self.getWriter().print("  {s} = icmp ne i32 {s}, 0\n", .{ result, tok });
        return result;
    }

    pub fn getWriter(self: *Builder) std.ArrayList(u8).Writer {
        if (self.is_inside_closure) {
            return self.llvm.closures_buffer.writer();
        }
        if (self.is_inside_func) {
            return self.llvm.functions_buffer.writer();
        }
        return self.llvm.code_buffer.writer();
    }

    fn elookuperr(self: *Builder, line: usize) !void {
        const msg = errors.getErrorMessage(1);
        const addr = try self.llvm.buildGlobalString(msg);
        const str_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_str_new(ptr {s})\n", .{ str_reg, addr });
        try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{str_reg});

        const nl_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load ptr, ptr @STR_NEWLINE, align 8\n", .{nl_reg});
        try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{nl_reg});

        const file_addr = try self.llvm.buildGlobalString(try self.fileToken());
        try self.getWriter().print("  call void @boblang_runtime_error(i32 1, ptr {s}, i32 {d})\n", .{ file_addr, line });
    }

    fn emitNullCheckAssign(self: *Builder, val_reg: []const u8, name: []const u8, line: usize) !void {
        const is_null = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call i32 @boblang_is_null(ptr {s})\n", .{ is_null, val_reg });
        const is_null_i1 = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = icmp ne i32 {s}, 0\n", .{ is_null_i1, is_null });
        const lbl_id = self.llvm.reg_count;
        const err_lbl = try std.fmt.allocPrint(self.allocator, ".null_err_{d}", .{lbl_id});
        defer self.allocator.free(err_lbl);
        const ok_lbl = try std.fmt.allocPrint(self.allocator, ".null_ok_{d}", .{lbl_id});
        defer self.allocator.free(ok_lbl);
        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_null_i1, err_lbl, ok_lbl });
        try self.getWriter().print("\n{s}:\n", .{err_lbl});
        const msg = try std.fmt.allocPrint(self.allocator, "cannot assign nil to non-nullable variable '{s}'", .{name});
        defer self.allocator.free(msg);
        if (self.llvm.obfuscate) {
            const key = LlvmBuilder.obfuscatedKey(msg);
            const enc = try self.llvm.buildObfuscatedString(msg, key);
            const sreg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = call ptr @boblang_str_new_x(ptr {s}, i32 {d}, i32 {d})\n", .{ sreg, enc, msg.len, key });
            const dreg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = call ptr @boblang_unbox_str(ptr {s})\n", .{ dreg, sreg });
            try self.getWriter().print("  call void @boblang_raise_error(i32 31, ptr {s}, i32 {d})\n", .{ dreg, line });
        } else {
            const msg_addr = try self.llvm.buildGlobalString(msg);
            try self.getWriter().print("  call void @boblang_raise_error(i32 31, ptr {s}, i32 {d})\n", .{ msg_addr, line });
        }
        try self.getWriter().print("  br label %{s}\n", .{ok_lbl});
        try self.getWriter().print("\n{s}:\n", .{ok_lbl});
    }

    pub fn emitChainedExpression(self: *Builder, path: []const u8) ![]const u8 {
        {
            var ci: usize = 0;
            while (ci < path.len and path[ci] != '.' and path[ci] != '[') : (ci += 1) {}
            if (ci < path.len and path[ci] == '.' and std.mem.eql(u8, path[0..ci], "conf")) {
                ci += 1;
                const ps = ci;
                while (ci < path.len and path[ci] != '.' and path[ci] != '[') : (ci += 1) {}
                if (self.conf_values.get(path[ps..ci])) |val| {
                    return try self.emitStrConstant(val);
                }
            }
        }
        var current_reg: []const u8 = "";
        var i: usize = 0;
        while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
        const root_name = path[0..i];
        if (self.execLookup(root_name)) |stack_ptr| {
            current_reg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !alias.scope !0\n", .{ current_reg, stack_ptr });
        } else {
            current_reg = try self.llvm.nextRegister();
            try self.elookuperr(0);
            try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{current_reg});
        }
        if (self.execLookupRaw('i', root_name)) |rslot| {
            if (i < path.len and path[i] == '[') {
                self.warnRawType();
                var j = i + 1;
                var cdepth: usize = 0;
                while (j < path.len) {
                    if (path[j] == '[') {
                        cdepth += 1;
                    } else if (path[j] == ']') {
                        if (cdepth == 0) break;
                        cdepth -= 1;
                    }
                    j += 1;
                }
                if (j == path.len - 1) {
                    const idx_expr = path[i + 1 .. j];
                    const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                    defer parser.freeAstNode(self.allocator, idx_node);
                    if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                        const rreg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                        const gp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = getelementptr i64, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                        const raw = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ raw, gp });
                        return try self.boxIntToPtr(raw);
                    }
                }
            }
        }
        if (self.execLookupRaw('f', root_name)) |rslot| {
            if (i < path.len and path[i] == '[') {
                self.warnRawType();
                var j = i + 1;
                var cdepth: usize = 0;
                while (j < path.len) {
                    if (path[j] == '[') {
                        cdepth += 1;
                    } else if (path[j] == ']') {
                        if (cdepth == 0) break;
                        cdepth -= 1;
                    }
                    j += 1;
                }
                if (j == path.len - 1) {
                    const idx_expr = path[i + 1 .. j];
                    const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                    defer parser.freeAstNode(self.allocator, idx_node);
                    if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                        const rreg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                        const gp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = getelementptr double, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                        const raw = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load double, ptr {s}, align 8\n", .{ raw, gp });
                        return try self.boxFloatToPtr(raw);
                    }
                }
            }
        }
        if (self.execLookupRaw('b', root_name)) |rslot| {
            if (i < path.len and path[i] == '[') {
                self.warnRawType();
                var j = i + 1;
                var cdepth: usize = 0;
                while (j < path.len) {
                    if (path[j] == '[') {
                        cdepth += 1;
                    } else if (path[j] == ']') {
                        if (cdepth == 0) break;
                        cdepth -= 1;
                    }
                    j += 1;
                }
                if (j == path.len - 1) {
                    const idx_expr = path[i + 1 .. j];
                    const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                    defer parser.freeAstNode(self.allocator, idx_node);
                    if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                        const rreg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                        const gp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                        const raw = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load i8, ptr {s}, align 1\n", .{ raw, gp });
                        const ext = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = zext i8 {s} to i64\n", .{ ext, raw });
                        return try self.boxIntToPtr(ext);
                    }
                }
            }
        }
        if (self.execLookupIntList(root_name) != null and i < path.len and path[i] == '[') {
            var j = i + 1;
            var cdepth: usize = 0;
            while (j < path.len) {
                if (path[j] == '[') {
                    cdepth += 1;
                } else if (path[j] == ']') {
                    if (cdepth == 0) break;
                    cdepth -= 1;
                }
                j += 1;
            }
            if (j == path.len - 1) {
                const idx_expr = path[i + 1 .. j];
                const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                defer parser.freeAstNode(self.allocator, idx_node);
                if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                    const raw = try self.emitIntListLoadRaw(current_reg, idx_i64);
                    return try self.boxIntToPtr(raw);
                }
            }
        }
        if (self.execLookupFloatList(root_name) != null and i < path.len and path[i] == '[') {
            var j = i + 1;
            var cdepth: usize = 0;
            while (j < path.len) {
                if (path[j] == '[') {
                    cdepth += 1;
                } else if (path[j] == ']') {
                    if (cdepth == 0) break;
                    cdepth -= 1;
                }
                j += 1;
            }
            if (j == path.len - 1) {
                const idx_expr = path[i + 1 .. j];
                const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                defer parser.freeAstNode(self.allocator, idx_node);
                if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                    const raw_double = try self.emitFloatListLoadRaw(current_reg, idx_i64);
                    return try self.boxFloatToPtr(raw_double);
                }
            }
        }
        if (self.execLookupBoolList(root_name) != null and i < path.len and path[i] == '[') {
            var j = i + 1;
            var cdepth: usize = 0;
            while (j < path.len) {
                if (path[j] == '[') {
                    cdepth += 1;
                } else if (path[j] == ']') {
                    if (cdepth == 0) break;
                    cdepth -= 1;
                }
                j += 1;
            }
            if (j == path.len - 1) {
                const idx_expr = path[i + 1 .. j];
                const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                defer parser.freeAstNode(self.allocator, idx_node);
                if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                    const ext = try self.emitBoolListLoadRaw(current_reg, idx_i64);
                    return try self.boxIntToPtr(ext);
                }
            }
        }
        while (i < path.len) {
            if (path[i] == '.') {
                i += 1;
                const start = i;
                while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
                const prop = path[start..i];
                const next_reg = try self.llvm.nextRegister();
                if (std.mem.eql(u8, prop, "length") and i >= path.len) {
                    try self.getWriter().print("  {s} = call ptr @boblang_get_length(ptr {s})\n", .{ next_reg, current_reg });
                } else {
                    const prop_str_reg = try self.emitPropString(prop);
                    try self.getWriter().print("  {s} = call ptr @boblang_get_property(ptr {s}, ptr {s})\n", .{ next_reg, current_reg, prop_str_reg });
                }
                current_reg = next_reg;
            } else if (path[i] == '[') {
                i += 1;
                const start = i;
                var depth: usize = 0;
                while (i < path.len) {
                    if (path[i] == '[') {
                        depth += 1;
                    } else if (path[i] == ']') {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    i += 1;
                }
                const index_expr = path[start..i];
                i += 1;
                const colon_pos = std.mem.indexOfScalar(u8, index_expr, ':');
                if (colon_pos != null) {
                    const start_str = index_expr[0..colon_pos.?];
                    const end_str = index_expr[colon_pos.? + 1 ..];
                    const start_reg = if (start_str.len > 0) try self.walkAstFromString(start_str) else try self.emitNull();
                    const end_reg = if (end_str.len > 0) try self.walkAstFromString(end_str) else try self.emitNull();
                    const next_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_slice(ptr {s}, ptr {s}, ptr {s})\n", .{ next_reg, current_reg, start_reg, end_reg });
                    current_reg = next_reg;
                } else {
                    const idx_reg = try self.walkAstFromString(index_expr);
                    const next_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_get_index(ptr {s}, ptr {s})\n", .{ next_reg, current_reg, idx_reg });
                    current_reg = next_reg;
                }
            } else {
                i += 1;
            }
        }
        return current_reg;
    }

    fn walkAstFromString(self: *Builder, expr: []const u8) ![]const u8 {
        const node = try parser.pltn(self.allocator, expr, expr, 0);
        defer parser.freeAstNode(self.allocator, node);
        return try self.walkAstAndEmit(node);
    }

    fn shouldEmitLine(node_type: parser.AstNodeType) bool {
        return switch (node_type) {
            .call, .return_stmt, .if_stmt, .while_loop, .for_loop, .break_stmt, .pass_stmt, .import_stmt, .export_stmt, .class_def, .func_def => true,
            else => false,
        };
    }

    pub fn walkAstAndEmit(self: *Builder, node: *AstNode) anyerror![]const u8 {
        @setEvalBranchQuota(100000);
        if (node.line > 0 and shouldEmitLine(node.node_type) and node.line != self.last_line) {
            try self.getWriter().print("  store i32 {d}, ptr @current_line\n", .{node.line});
            self.last_line = node.line;
        }
        switch (node.node_type) {
            .comment => return "",
            .val_int => {
                if (node.val_int == 0 and node.val_string.len > 1) {
                    const text_addr = try self.llvm.buildGlobalString(node.val_string);
                    const bigi_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_bigi_new(ptr {s})\n", .{ bigi_reg, text_addr });
                    return bigi_reg;
                }
                return try self.makeTint(node.val_int);
            },
            .val_float => {
                const reg = try self.llvm.nextRegister();
                const fbits = try self.llvm.nextRegister();
                const fclear = try self.llvm.nextRegister();
                const ftag = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = bitcast double {d:.17} to i64\n", .{ fbits, node.val_float });
                try self.getWriter().print("  {s} = and i64 {s}, -8\n", .{ fclear, fbits });
                try self.getWriter().print("  {s} = or i64 {s}, 4\n", .{ ftag, fclear });
                try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, ftag });
                return reg;
            },
            .val_nil => {
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = inttoptr i64 0 to ptr\n", .{reg});
                return reg;
            },
            .val_bool => {
                const reg = try self.llvm.nextRegister();
                const bool_val: i64 = if (node.val_int != 0) 1 else 0;
                const tagged_bool = (bool_val << 2) | 2;
                try self.getWriter().print("  {s} = inttoptr i64 {d} to ptr\n", .{ reg, tagged_bool });
                return reg;
            },
            .val_string => {
                return try self.estr(node.val_string);
            },
            .val_list => {
                const list_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_lister_new()\n", .{list_reg});
                if (node.args) |args| {
                    for (args.items) |item| {
                        const val = try self.walkAstAndEmit(item);
                        if (val.len > 0) {
                            try self.getWriter().print("  call void @boblang_lister_append(ptr {s}, ptr {s})\n", .{ list_reg, val });
                        }
                    }
                }
                return list_reg;
            },
            .val_dict => {
                const dict_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_dict_new()\n", .{dict_reg});
                if (node.args) |args| {
                    var i: usize = 0;
                    while (i < args.items.len) : (i += 2) {
                        const k = try self.walkAstAndEmit(args.items[i]);
                        const v = try self.walkAstAndEmit(args.items[i + 1]);
                        try self.getWriter().print("  call void @boblang_dict_set(ptr {s}, ptr {s}, ptr {s})\n", .{ dict_reg, k, v });
                    }
                }
                return dict_reg;
            },
            .class_def => {
                const old_class = self.current_class_name;
                const old_has_base = self.current_class_has_base;
                self.current_class_name = node.name;
                self.current_class_has_base = node.extra != null;
                const methods_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_dict_new()\n", .{methods_reg});
                const bases_reg = if (node.extra) |base_str| blk: {
                    const base_val = try self.walkAstFromString(base_str);
                    const list_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_lister_new()\n", .{list_reg});
                    try self.getWriter().print("  call void @boblang_lister_append(ptr {s}, ptr {s})\n", .{ list_reg, base_val });
                    break :blk list_reg;
                } else try self.emitNull();
                if (node.subtree) |sub| {
                    for (sub.items) |child| {
                        if (child.node_type == .func_def) {
                            _ = try self.walkAstAndEmit(child);
                            if (!child.is_private) {
                                const func_name = try std.fmt.allocPrint(self.allocator, "bob_class_{s}_{s}", .{ try self.junkName(self.current_class_name), try self.junkName(child.name) });
                                defer self.allocator.free(func_name);
                                const arity = if (child.args) |args| args.items.len + 1 else 1;
                                const func_obj_reg = try self.llvm.nextRegister();
                                const func_name_str = try self.emitPropString(child.name);
                                try self.getWriter().print("  {s} = call ptr @boblang_func_new(ptr @{s}, i32 {d}, i32 {d}, ptr {s}, ptr null, ptr null, ptr null, i32 0)\n", .{ func_obj_reg, func_name, arity, arity, func_name_str });
                                const method_val_reg = if (child.decorators) |decorators| blk: {
                                    const temp_slot = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{temp_slot});
                                    try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{temp_slot});
                                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ func_obj_reg, temp_slot });
                                    try self.applyDecorators(decorators, temp_slot);
                                    const loaded = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ loaded, temp_slot });
                                    break :blk loaded;
                                } else func_obj_reg;
                                const name_reg = try self.emitPropString(child.name);
                                try self.getWriter().print("  call void @boblang_dict_set(ptr {s}, ptr {s}, ptr {s})\n", .{ methods_reg, name_reg, method_val_reg });
                            }
                        }
                    }
                }
                const name_reg = try self.emitPropString(node.name);
                const class_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_class_new(ptr {s}, ptr {s}, ptr {s})\n", .{ class_reg, name_reg, bases_reg, methods_reg });
                const class_var = if (self.current_module_prefix != null and !self.is_inside_func) blk: {
                    const global_name = try std.fmt.allocPrint(self.allocator, "@bob_mod_{s}_{s}", .{ self.current_module_prefix.?, try self.junkName(node.name) });
                    try self.llvm.global_buffer.writer().print("{s} = global ptr null\n", .{global_name});
                    try self.execAssign(node.name, global_name);
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ class_reg, global_name });
                    break :blk global_name;
                } else if (!self.is_inside_func) blk: {
                    break :blk try self.emitTopLevelObject(node.name, class_reg);
                } else blk: {
                    var stack_ptr = self.execLookup(node.name);
                    if (stack_ptr == null) {
                        stack_ptr = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr.?});
                        try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr.?});
                        try self.execAssign(node.name, stack_ptr.?);
                    }
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ class_reg, stack_ptr.? });
                    break :blk stack_ptr.?;
                };
                if (node.decorators) |decorators| {
                    try self.applyDecorators(decorators, class_var);
                }
                self.current_class_name = old_class;
                self.current_class_has_base = old_has_base;
                return "";
            },
            .var_ref => {
                if (node.target) |target| {
                    if (target.target == null and std.mem.eql(u8, target.name, "conf")) {
                        if (self.conf_values.get(node.name)) |val| {
                            return try self.emitStrConstant(val);
                        }
                    }
                    const obj_reg = try self.walkAstAndEmit(target);
                    if (node.is_optional) {
                        return try self.emitOptionalGet(obj_reg, node.name);
                    }
                    if (std.mem.eql(u8, node.name, "length")) {
                        const reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @boblang_get_length(ptr {s})\n", .{ reg, obj_reg });
                        return reg;
                    }
                    const prop_str_reg = try self.emitPropString(node.name);
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_get_property(ptr {s}, ptr {s})\n", .{ reg, obj_reg, prop_str_reg });
                    return reg;
                }
                if (std.mem.containsAtLeast(u8, node.name, 1, ".") or std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    return try self.emitChainedExpression(node.name);
                }
                if (self.execLookupFloat(node.name)) |float_stack| {
                    const load_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load double, ptr {s}, align 8\n", .{ load_reg, float_stack });
                    return try self.boxFloatToPtr(load_reg);
                }
                if (self.execLookupInt(node.name)) |int_stack| {
                    const load_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ load_reg, int_stack });
                    return try self.boxIntToPtr(load_reg);
                }
                if (self.execLookup(node.name)) |stack_ptr| {
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ reg, stack_ptr });
                    return reg;
                }
                const callee = node.name;
                if (self.builtin_thunks.get(callee)) |global_name| {
                    return try self.emitLoadGlobal(global_name);
                }
                const reg = try self.llvm.nextRegister();
                if (!node.is_optional) {
                    try self.elookuperr(node.line);
                }
                try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{reg});
                return reg;
            },
            .assign => {
                const rhs_node = node.args.?.items[0];

                if (node.extra != null and std.mem.eql(u8, node.extra.?, "enum")) {
                    try self.enum_types.put(try self.allocator.dupe(u8, node.name), {});
                    const dict_reg = try self.walkAstAndEmit(node.args.?.items[0]);
                    if (!self.is_inside_func) {
                        _ = try self.emitTopLevelObject(node.name, dict_reg);
                    } else {
                        var stack_ptr = self.execLookup(node.name);
                        if (stack_ptr == null) {
                            stack_ptr = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr.?});
                            try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr.?});
                            try self.execAssign(node.name, stack_ptr.?);
                        }
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ dict_reg, stack_ptr.? });
                    }
                    return "";
                }

                const is_explicit_int = node.extra != null and std.mem.eql(u8, node.extra.?, "int");
                const is_plain_var = node.target == null and !std.mem.containsAtLeast(u8, node.name, 1, ".") and !std.mem.containsAtLeast(u8, node.name, 1, "[");
                if (node.is_optional and is_plain_var) {
                    try self.nullable_vars.put(try self.allocator.dupe(u8, node.name), {});
                }
                if (is_plain_var and rhs_node.node_type == .val_nil and !node.is_optional and !self.nullable_vars.contains(node.name)) {
                    const msg = try std.fmt.allocPrint(self.allocator, "cannot assign nil to non-nullable variable '{s}' (use '?=' to make it nullable)", .{node.name});
                    defer self.allocator.free(msg);
                    errors.printCompileError("", msg);
                    std.process.exit(1);
                }
                if (node.extra) |annot| {
                    try self.execDeclType(node.name, annot);
                    if (std.mem.eql(u8, annot, "list[int]")) {
                        const slot = try self.llvm.allocScratchPtr(self.getWriter());
                        try self.execAssignIntList(node.name, slot);
                        try self.execAssign(node.name, slot);
                        const new_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @boblang_int_list_new()\n", .{new_reg});
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                        if (rhs_node.node_type == .val_list) {
                            if (rhs_node.args) |items| {
                                for (items.items) |item| {
                                    if (try self.tryEmitAsInt(item)) |item_int| {
                                        try self.getWriter().print("  call void @boblang_int_list_append(ptr {s}, i64 {s})\n", .{ new_reg, item_int });
                                    } else {
                                        const item_val = try self.walkAstAndEmit(item);
                                        const type_str = try self.llvm.buildGlobalString("int");
                                        const name_str = try self.llvm.buildGlobalString(node.name);
                                        try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ item_val, type_str, name_str, node.line });
                                        const unboxed = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, item_val });
                                        try self.getWriter().print("  call void @boblang_int_list_append(ptr {s}, i64 {s})\n", .{ new_reg, unboxed });
                                    }
                                }
                            }
                        }
                        return "";
                    } else if (std.mem.eql(u8, annot, "list[float]")) {
                        const slot = try self.llvm.allocScratchPtr(self.getWriter());
                        try self.float_list_vars.put(try self.allocator.dupe(u8, node.name), try self.allocator.dupe(u8, slot));
                        try self.execAssign(node.name, slot);
                        const new_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @boblang_float_list_new()\n", .{new_reg});
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                        if (rhs_node.node_type == .val_list) {
                            if (rhs_node.args) |items| {
                                for (items.items) |item| {
                                    if (try self.tryEmitAsFloat(item)) |freg| {
                                        try self.getWriter().print("  call void @boblang_float_list_append(ptr {s}, double {s})\n", .{ new_reg, freg });
                                    } else {
                                        const item_val = try self.walkAstAndEmit(item);
                                        const type_str = try self.llvm.buildGlobalString("float");
                                        const name_str = try self.llvm.buildGlobalString(node.name);
                                        try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ item_val, type_str, name_str, node.line });
                                        const unboxed = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unboxed, item_val });
                                        try self.getWriter().print("  call void @boblang_float_list_append(ptr {s}, double {s})\n", .{ new_reg, unboxed });
                                    }
                                }
                            }
                        }
                        return "";
                    } else if (std.mem.eql(u8, annot, "list[bool]")) {
                        const slot = try self.llvm.allocScratchPtr(self.getWriter());
                        try self.bool_list_vars.put(try self.allocator.dupe(u8, node.name), try self.allocator.dupe(u8, slot));
                        try self.execAssign(node.name, slot);
                        const new_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @boblang_bool_list_new()\n", .{new_reg});
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                        if (rhs_node.node_type == .val_list) {
                            if (rhs_node.args) |items| {
                                for (items.items) |item| {
                                    if (item.node_type == .val_bool) {
                                        const bool_int = if (item.val_int != 0) "1" else "0";
                                        try self.getWriter().print("  call void @boblang_bool_list_append(ptr {s}, i64 {s})\n", .{ new_reg, bool_int });
                                    } else if (try self.tryEmitAsInt(item)) |item_int| {
                                        try self.getWriter().print("  call void @boblang_bool_list_append(ptr {s}, i64 {s})\n", .{ new_reg, item_int });
                                    } else {
                                        const item_val = try self.walkAstAndEmit(item);
                                        const type_str = try self.llvm.buildGlobalString("bool");
                                        const name_str = try self.llvm.buildGlobalString(node.name);
                                        try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ item_val, type_str, name_str, node.line });
                                        const unboxed = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, item_val });
                                        try self.getWriter().print("  call void @boblang_bool_list_append(ptr {s}, i64 {s})\n", .{ new_reg, unboxed });
                                    }
                                }
                            }
                        }
                        return "";
                    } else if (std.mem.eql(u8, annot, "raw_int")) {
                        self.warnRawType();
                        const slot = try self.llvm.allocScratchPtr(self.getWriter());
                        try self.execAssignRaw('i', node.name, slot);
                        try self.execAssign(node.name, slot);
                        const new_reg = try self.llvm.nextRegister();
                        const size_int = if (rhs_node.node_type == .call and rhs_node.args != null and rhs_node.args.?.items.len >= 1) try self.tryEmitAsInt(rhs_node.args.?.items[0]) else null;
                        if (size_int) |si| {
                            try self.getWriter().print("  {s} = call ptr @boblang_raw_int_new(i64 {s})\n", .{ new_reg, si });
                        } else {
                            try self.getWriter().print("  {s} = call ptr @boblang_raw_int_new(i64 0)\n", .{new_reg});
                        }
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                        return "";
                    } else if (std.mem.eql(u8, annot, "raw_float")) {
                        self.warnRawType();
                        const slot = try self.llvm.allocScratchPtr(self.getWriter());
                        try self.execAssignRaw('f', node.name, slot);
                        try self.execAssign(node.name, slot);
                        const new_reg = try self.llvm.nextRegister();
                        const size_int = if (rhs_node.node_type == .call and rhs_node.args != null and rhs_node.args.?.items.len >= 1) try self.tryEmitAsInt(rhs_node.args.?.items[0]) else null;
                        if (size_int) |si| {
                            try self.getWriter().print("  {s} = call ptr @boblang_raw_float_new(i64 {s})\n", .{ new_reg, si });
                        } else {
                            try self.getWriter().print("  {s} = call ptr @boblang_raw_float_new(i64 0)\n", .{new_reg});
                        }
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                        return "";
                    } else if (std.mem.eql(u8, annot, "raw_bool")) {
                        self.warnRawType();
                        const slot = try self.llvm.allocScratchPtr(self.getWriter());
                        try self.execAssignRaw('b', node.name, slot);
                        try self.execAssign(node.name, slot);
                        const new_reg = try self.llvm.nextRegister();
                        const size_int = if (rhs_node.node_type == .call and rhs_node.args != null and rhs_node.args.?.items.len >= 1) try self.tryEmitAsInt(rhs_node.args.?.items[0]) else null;
                        if (size_int) |si| {
                            try self.getWriter().print("  {s} = call ptr @boblang_raw_bool_new(i64 {s})\n", .{ new_reg, si });
                        } else {
                            try self.getWriter().print("  {s} = call ptr @boblang_raw_bool_new(i64 0)\n", .{new_reg});
                        }
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                        return "";
                    } else if (std.mem.startsWith(u8, annot, "list[") and !std.mem.eql(u8, annot, "list[int]") and !std.mem.eql(u8, annot, "list[float]") and !std.mem.eql(u8, annot, "list[bool]")) {
                        const elem_type = annot[5 .. annot.len - 1];
                        try self.generic_list_elem_types.put(try self.allocator.dupe(u8, node.name), try self.allocator.dupe(u8, elem_type));
                        if (rhs_node.node_type == .val_list) {
                            const slot = try self.llvm.allocScratchPtr(self.getWriter());
                            try self.execAssign(node.name, slot);
                            const new_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call ptr @boblang_lister_new()\n", .{new_reg});
                            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ new_reg, slot });
                            if (rhs_node.args) |items| {
                                const check = !self.enum_types.contains(elem_type) and !std.mem.startsWith(u8, elem_type, "list[");
                                for (items.items) |item| {
                                    const item_val = try self.walkAstAndEmit(item);
                                    if (check) {
                                        const type_str = try self.llvm.buildGlobalString(elem_type);
                                        const name_str = try self.llvm.buildGlobalString(node.name);
                                        try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ item_val, type_str, name_str, node.line });
                                    }
                                    try self.getWriter().print("  call void @boblang_lister_append(ptr {s}, ptr {s})\n", .{ new_reg, item_val });
                                }
                            }
                            return "";
                        }
                    }
                } else if (node.target == null) {
                    const decl_type = self.lookupDeclType(node.name);
                    if (decl_type) |dt| {
                        const rhs_type = switch (rhs_node.node_type) {
                            .val_int => "int",
                            .val_float => "float",
                            .val_string => "str",
                            .val_bool => "bool",
                            else => null,
                        };
                        if (rhs_type) |rt| {
                            if (!std.mem.eql(u8, dt, rt)) {
                                errors.printCompileError("", "Type mismatch: variable '");
                                progress.clear();
                                std.debug.print("{s}", .{node.name});
                                progress.clear();
                                std.debug.print("' was annotated as '{s}' but assigned a '{s}' value\n", .{ dt, rt });
                                std.process.exit(1);
                            }
                        }
                    }
                }
                if (node.target == null and !std.mem.containsAtLeast(u8, node.name, 1, ".") and !std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    if (self.execLookupInt(node.name)) |int_stack| {
                        if (try self.tryEmitAsInt(rhs_node)) |int_reg| {
                            try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ int_reg, int_stack });
                            return "";
                        }
                        if (try self.tryEmitAsFloat(rhs_node)) |float_reg| {
                            const as_int = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = fptosi double {s} to i64\n", .{ as_int, float_reg });
                            try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ as_int, int_stack });
                            return "";
                        }
                    }
                    if (self.execLookupFloat(node.name)) |float_stack| {
                        if (try self.tryEmitAsFloat(rhs_node)) |float_reg| {
                            try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ float_reg, float_stack });
                            return "";
                        }
                        if (try self.tryEmitAsInt(rhs_node)) |int_reg| {
                            const as_float = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = sitofp i64 {s} to double\n", .{ as_float, int_reg });
                            try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ as_float, float_stack });
                            return "";
                        }
                    }
                    if (is_explicit_int) {
                        const int_ptr = if (self.execLookupInt(node.name)) |existing|
                            existing
                        else
                            try self.llvm.allocIntSlot(self.getWriter());
                        try self.execAssignInt(node.name, int_ptr);
                        if (try self.tryEmitAsInt(rhs_node)) |int_reg| {
                            try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ int_reg, int_ptr });
                            return "";
                        }
                        const big_val = try self.walkAstAndEmit(rhs_node);
                        const type_str = try self.llvm.buildGlobalString("int");
                        const name_str = try self.llvm.buildGlobalString(node.name);
                        try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ big_val, type_str, name_str, node.line });
                        const unboxed = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, big_val });
                        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ unboxed, int_ptr });
                        return "";
                    }
                    if (node.extra != null) {
                        const annot = node.extra.?;
                        if (std.mem.eql(u8, annot, "bigf") and rhs_node.node_type == .val_float and rhs_node.val_string.len > 0) {
                            const text_addr = try self.llvm.buildGlobalString(rhs_node.val_string);
                            const bigf_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call ptr @boblang_bigf_new(ptr {s})\n", .{ bigf_reg, text_addr });
                            const stack_ptr = try self.llvm.allocScratchPtr(self.getWriter());
                            try self.execAssign(node.name, stack_ptr);
                            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ bigf_reg, stack_ptr });
                            return "";
                        }
                        if (std.mem.eql(u8, annot, "bigi") and rhs_node.node_type == .val_int and rhs_node.val_string.len > 0) {
                            const text_addr = try self.llvm.buildGlobalString(rhs_node.val_string);
                            const bigi_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call ptr @boblang_bigi_new(ptr {s})\n", .{ bigi_reg, text_addr });
                            const stack_ptr = try self.llvm.allocScratchPtr(self.getWriter());
                            try self.execAssign(node.name, stack_ptr);
                            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ bigi_reg, stack_ptr });
                            return "";
                        }
                        if (std.mem.eql(u8, annot, "bigi")) {
                            const bigi_reg = try self.llvm.nextRegister();
                            const val = try self.walkAstAndEmit(rhs_node);
                            try self.getWriter().print("  {s} = call ptr @boblang_to_bigi(ptr {s})\n", .{ bigi_reg, val });
                            const stack_ptr = try self.llvm.allocScratchPtr(self.getWriter());
                            try self.execAssign(node.name, stack_ptr);
                            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ bigi_reg, stack_ptr });
                            return "";
                        }
                        if (std.mem.eql(u8, annot, "bigf")) {
                            const bigf_reg = try self.llvm.nextRegister();
                            const val = try self.walkAstAndEmit(rhs_node);
                            try self.getWriter().print("  {s} = call ptr @boblang_to_bigf(ptr {s})\n", .{ bigf_reg, val });
                            const stack_ptr = try self.llvm.allocScratchPtr(self.getWriter());
                            try self.execAssign(node.name, stack_ptr);
                            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ bigf_reg, stack_ptr });
                            return "";
                        }
                    }
                    if (try self.tryEmitAsInt(rhs_node)) |int_reg| {
                        const int_ptr = try self.llvm.allocIntSlot(self.getWriter());
                        try self.execAssignInt(node.name, int_ptr);
                        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ int_reg, int_ptr });
                        return "";
                    }
                    if (try self.tryEmitAsFloat(rhs_node)) |float_reg| {
                        const float_ptr = try self.llvm.allocFloatSlot(self.getWriter());
                        try self.execAssignFloat(node.name, float_ptr);
                        try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ float_reg, float_ptr });
                        return "";
                    }
                }

                const val_reg = try self.walkAstAndEmit(rhs_node);

                if (is_plain_var and !node.is_optional and !self.nullable_vars.contains(node.name)) {
                    try self.emitNullCheckAssign(val_reg, node.name, node.line);
                }

                if (node.target == null and !std.mem.containsAtLeast(u8, node.name, 1, ".") and !std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    if (self.lookupDeclType(node.name)) |decl_type| {
                        const is_generic_list = std.mem.startsWith(u8, decl_type, "list[") and !std.mem.eql(u8, decl_type, "list[int]") and !std.mem.eql(u8, decl_type, "list[float]") and !std.mem.eql(u8, decl_type, "list[bool]");
                        const is_enum_type = self.enum_types.contains(decl_type);
                        const is_composite = std.mem.indexOfAny(u8, decl_type, "[,") != null;
                        if (!std.mem.eql(u8, decl_type, "any") and !is_generic_list and !is_enum_type and !is_composite) {
                            const type_str = try self.llvm.buildGlobalString(decl_type);
                            const name_str = try self.llvm.buildGlobalString(node.name);
                            try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ val_reg, type_str, name_str, node.line });
                        }
                        if (std.mem.eql(u8, decl_type, "int") and self.execLookupInt(node.name) == null) {
                            const int_ptr = try self.llvm.allocIntSlot(self.getWriter());
                            try self.execAssignInt(node.name, int_ptr);
                            const unboxed = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, val_reg });
                            try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ unboxed, int_ptr });
                            return "";
                        }
                        if (std.mem.eql(u8, decl_type, "float") and self.execLookupFloat(node.name) == null) {
                            const float_ptr = try self.llvm.allocFloatSlot(self.getWriter());
                            try self.execAssignFloat(node.name, float_ptr);
                            const unboxed = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unboxed, val_reg });
                            try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ unboxed, float_ptr });
                            return "";
                        }
                    }
                }

                if (node.target) |target| {
                    const obj_reg = try self.walkAstAndEmit(target);
                    const prop_str_reg = try self.emitPropString(node.name);
                    try self.getWriter().print("  call void @boblang_set_property(ptr {s}, ptr {s}, ptr {s})\n", .{ obj_reg, prop_str_reg, val_reg });
                    return "";
                }

                if (std.mem.containsAtLeast(u8, node.name, 1, ".") or std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    var i: usize = 0;
                    while (i < node.name.len and node.name[i] != '.' and node.name[i] != '[') : (i += 1) {}
                    const root_name = node.name[0..i];
                    var current_reg: []const u8 = "";
                    if (self.execLookup(root_name)) |stack_ptr| {
                        current_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ current_reg, stack_ptr });
                    } else {
                        current_reg = try self.llvm.nextRegister();
                        try self.elookuperr(node.line);
                        try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{current_reg});
                    }
                    if (self.execLookupIntList(root_name) != null and i < node.name.len and node.name[i] == '[') {
                        var j = i + 1;
                        var wdepth: usize = 0;
                        while (j < node.name.len) {
                            if (node.name[j] == '[') {
                                wdepth += 1;
                            } else if (node.name[j] == ']') {
                                if (wdepth == 0) break;
                                wdepth -= 1;
                            }
                            j += 1;
                        }
                        if (j == node.name.len - 1) {
                            const idx_expr = node.name[i + 1 .. j];
                            const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                            defer parser.freeAstNode(self.allocator, idx_node);
                            if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                                if (try self.tryEmitAsInt(rhs_node)) |rhs_int| {
                                    try self.emitIntListStoreRaw(current_reg, idx_i64, rhs_int);
                                } else {
                                    const type_str = try self.llvm.buildGlobalString("int");
                                    const name_str = try self.llvm.buildGlobalString(root_name);
                                    try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ val_reg, type_str, name_str, node.line });
                                    const unboxed = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, val_reg });
                                    try self.emitIntListStoreRaw(current_reg, idx_i64, unboxed);
                                }
                                return "";
                            }
                        }
                    }
                    if (self.execLookupBoolList(root_name) != null and i < node.name.len and node.name[i] == '[') {
                        var j = i + 1;
                        var wdepth: usize = 0;
                        while (j < node.name.len) {
                            if (node.name[j] == '[') {
                                wdepth += 1;
                            } else if (node.name[j] == ']') {
                                if (wdepth == 0) break;
                                wdepth -= 1;
                            }
                            j += 1;
                        }
                        if (j == node.name.len - 1) {
                            const idx_expr = node.name[i + 1 .. j];
                            const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                            defer parser.freeAstNode(self.allocator, idx_node);
                            if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                                if (try self.tryEmitAsInt(rhs_node)) |rhs_int| {
                                    try self.emitBoolListStoreRaw(current_reg, idx_i64, rhs_int);
                                } else {
                                    const type_str = try self.llvm.buildGlobalString("bool");
                                    const name_str = try self.llvm.buildGlobalString(root_name);
                                    try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ val_reg, type_str, name_str, node.line });
                                    const unboxed = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, val_reg });
                                    try self.emitBoolListStoreRaw(current_reg, idx_i64, unboxed);
                                }
                                return "";
                            }
                        }
                    }
                    if (self.execLookupFloatList(root_name) != null and i < node.name.len and node.name[i] == '[') {
                        var j = i + 1;
                        var wdepth: usize = 0;
                        while (j < node.name.len) {
                            if (node.name[j] == '[') {
                                wdepth += 1;
                            } else if (node.name[j] == ']') {
                                if (wdepth == 0) break;
                                wdepth -= 1;
                            }
                            j += 1;
                        }
                        if (j == node.name.len - 1) {
                            const idx_expr = node.name[i + 1 .. j];
                            const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                            defer parser.freeAstNode(self.allocator, idx_node);
                            if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                                if (try self.tryEmitAsFloat(rhs_node)) |rhs_f| {
                                    try self.emitFloatListStoreRaw(current_reg, idx_i64, rhs_f);
                                } else {
                                    const type_str = try self.llvm.buildGlobalString("float");
                                    const name_str = try self.llvm.buildGlobalString(root_name);
                                    try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ val_reg, type_str, name_str, node.line });
                                    const unboxed = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unboxed, val_reg });
                                    try self.emitFloatListStoreRaw(current_reg, idx_i64, unboxed);
                                }
                                return "";
                            }
                        }
                    }
                    if (self.execLookupRaw('i', root_name)) |rslot| {
                        if (i < node.name.len and node.name[i] == '[') {
                            self.warnRawType();
                            var j = i + 1;
                            var wdepth: usize = 0;
                            while (j < node.name.len) {
                                if (node.name[j] == '[') {
                                    wdepth += 1;
                                } else if (node.name[j] == ']') {
                                    if (wdepth == 0) break;
                                    wdepth -= 1;
                                }
                                j += 1;
                            }
                            if (j == node.name.len - 1) {
                                const idx_expr = node.name[i + 1 .. j];
                                const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                                defer parser.freeAstNode(self.allocator, idx_node);
                                if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                                    const rhs_int = if (try self.tryEmitAsInt(rhs_node)) |ri| ri else blk: {
                                        const unboxed = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, val_reg });
                                        break :blk unboxed;
                                    };
                                    const rreg = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                                    const gp = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = getelementptr i64, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                                    try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ rhs_int, gp });
                                    return "";
                                }
                            }
                        }
                    }
                    if (self.execLookupRaw('f', root_name)) |rslot| {
                        if (i < node.name.len and node.name[i] == '[') {
                            self.warnRawType();
                            var j = i + 1;
                            var wdepth: usize = 0;
                            while (j < node.name.len) {
                                if (node.name[j] == '[') {
                                    wdepth += 1;
                                } else if (node.name[j] == ']') {
                                    if (wdepth == 0) break;
                                    wdepth -= 1;
                                }
                                j += 1;
                            }
                            if (j == node.name.len - 1) {
                                const idx_expr = node.name[i + 1 .. j];
                                const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                                defer parser.freeAstNode(self.allocator, idx_node);
                                if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                                    const rhs_f = if (try self.tryEmitAsFloat(rhs_node)) |rf| rf else blk: {
                                        const unboxed = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unboxed, val_reg });
                                        break :blk unboxed;
                                    };
                                    const rreg = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                                    const gp = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = getelementptr double, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                                    try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ rhs_f, gp });
                                    return "";
                                }
                            }
                        }
                    }
                    if (self.execLookupRaw('b', root_name)) |rslot| {
                        if (i < node.name.len and node.name[i] == '[') {
                            self.warnRawType();
                            var j = i + 1;
                            var wdepth: usize = 0;
                            while (j < node.name.len) {
                                if (node.name[j] == '[') {
                                    wdepth += 1;
                                } else if (node.name[j] == ']') {
                                    if (wdepth == 0) break;
                                    wdepth -= 1;
                                }
                                j += 1;
                            }
                            if (j == node.name.len - 1) {
                                const idx_expr = node.name[i + 1 .. j];
                                const idx_node = try parser.pltn(self.allocator, idx_expr, idx_expr, 0);
                                defer parser.freeAstNode(self.allocator, idx_node);
                                if (try self.tryEmitAsInt(idx_node)) |idx_i64| {
                                    const rhs_int = if (try self.tryEmitAsInt(rhs_node)) |ri| ri else blk: {
                                        const unboxed = try self.llvm.nextRegister();
                                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, val_reg });
                                        break :blk unboxed;
                                    };
                                    const rreg = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8, !invariant.load !3\n", .{ rreg, rslot });
                                    const gp = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ gp, rreg, idx_i64 });
                                    const trunc = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = trunc i64 {s} to i8\n", .{ trunc, rhs_int });
                                    try self.getWriter().print("  store i8 {s}, ptr {s}, align 1\n", .{ trunc, gp });
                                    return "";
                                }
                            }
                        }
                    }
                    while (i < node.name.len) {
                        if (node.name[i] == '.') {
                            i += 1;
                            const start = i;
                            while (i < node.name.len and node.name[i] != '.' and node.name[i] != '[') : (i += 1) {}
                            const prop = node.name[start..i];
                            if (i >= node.name.len) {
                                const prop_str_reg = try self.emitPropString(prop);
                                try self.getWriter().print("  call void @boblang_set_property(ptr {s}, ptr {s}, ptr {s})\n", .{ current_reg, prop_str_reg, val_reg });
                                break;
                            } else {
                                const prop_str_reg = try self.emitPropString(prop);
                                const next_reg = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = call ptr @boblang_get_property(ptr {s}, ptr {s})\n", .{ next_reg, current_reg, prop_str_reg });
                                current_reg = next_reg;
                            }
                        } else if (node.name[i] == '[') {
                            i += 1;
                            const start = i;
                            var depth: usize = 0;
                            while (i < node.name.len) {
                                if (node.name[i] == '[') {
                                    depth += 1;
                                } else if (node.name[i] == ']') {
                                    if (depth == 0) break;
                                    depth -= 1;
                                }
                                i += 1;
                            }
                            const index_expr = node.name[start..i];
                            i += 1;
                            const colon_pos = std.mem.indexOfScalar(u8, index_expr, ':');
                            if (colon_pos != null) {
                                const start_str = index_expr[0..colon_pos.?];
                                const end_str = index_expr[colon_pos.? + 1 ..];
                                const start_reg = if (start_str.len > 0) try self.walkAstFromString(start_str) else try self.emitNull();
                                const end_reg = if (end_str.len > 0) try self.walkAstFromString(end_str) else try self.emitNull();
                                if (i >= node.name.len) {
                                    try self.getWriter().print("  call void @boblang_set_slice(ptr {s}, ptr {s}, ptr {s}, ptr {s})\n", .{ current_reg, start_reg, end_reg, val_reg });
                                } else {
                                    const next_reg = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = call ptr @boblang_slice(ptr {s}, ptr {s}, ptr {s})\n", .{ next_reg, current_reg, start_reg, end_reg });
                                    current_reg = next_reg;
                                }
                            } else {
                                const idx_reg = try self.walkAstFromString(index_expr);
                                if (i >= node.name.len) {
                                    try self.getWriter().print("  call void @boblang_set_index(ptr {s}, ptr {s}, ptr {s})\n", .{ current_reg, idx_reg, val_reg });
                                    break;
                                } else {
                                    const next_reg = try self.llvm.nextRegister();
                                    try self.getWriter().print("  {s} = call ptr @boblang_get_index(ptr {s}, ptr {s})\n", .{ next_reg, current_reg, idx_reg });
                                    current_reg = next_reg;
                                }
                            }
                        } else {
                            i += 1;
                        }
                    }
                    return "";
                }

                if (self.execLookupFloat(node.name)) |float_stack| {
                    if (try self.tryEmitAsFloat(node.args.?.items[0])) |float_reg| {
                        try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ float_reg, float_stack });
                    } else {
                        const unboxed = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unboxed, val_reg });
                        try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ unboxed, float_stack });
                    }
                    return "";
                }

                if (self.execLookupInt(node.name)) |int_stack| {
                    if (try self.tryEmitAsInt(node.args.?.items[0])) |int_reg| {
                        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ int_reg, int_stack });
                    } else {
                        const unboxed = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, val_reg });
                        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ unboxed, int_stack });
                    }
                    return "";
                }

                if (self.execLookup(node.name)) |stack_ptr| {
                    const old_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ old_reg, stack_ptr });
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ val_reg, stack_ptr });
                    return "";
                }

                if (try self.tryEmitAsInt(node.args.?.items[0])) |int_reg| {
                    const int_ptr = try self.llvm.allocIntSlot(self.getWriter());
                    try self.execAssignInt(node.name, int_ptr);
                    try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ int_reg, int_ptr });
                    return "";
                }

                if (try self.tryEmitAsFloat(node.args.?.items[0])) |float_reg| {
                    const float_ptr = try self.llvm.allocFloatSlot(self.getWriter());
                    try self.execAssignFloat(node.name, float_ptr);
                    try self.getWriter().print("  store double {s}, ptr {s}, align 8\n", .{ float_reg, float_ptr });
                    return "";
                }

                const stack_ptr = try self.llvm.allocScratchPtr(self.getWriter());
                try self.execAssign(node.name, stack_ptr);

                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ val_reg, stack_ptr });
                return "";
            },
            .aug_assign_add => {
                const rhs_node = node.args.?.items[0];
                if (node.target == null) {
                    if (self.execLookupInt(node.name)) |int_stack| {
                        if (try self.tryEmitAsInt(rhs_node)) |rhs_int| {
                            const lhs_int = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ lhs_int, int_stack });
                            const result_int = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = add i64 {s}, {s}\n", .{ result_int, lhs_int, rhs_int });
                            try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ result_int, int_stack });
                            return "";
                        }
                    }
                }
                const rhs_val = try self.walkAstAndEmit(rhs_node);
                if (node.target) |target| {
                    const obj_reg = try self.walkAstAndEmit(target);
                    const prop_str_reg = try self.emitPropString(node.name);
                    const lhs_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_get_property(ptr {s}, ptr {s})\n", .{ lhs_val, obj_reg, prop_str_reg });
                    const res_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @badd(ptr {s}, ptr {s})\n", .{ res_reg, lhs_val, rhs_val });
                    try self.getWriter().print("  call void @boblang_set_property(ptr {s}, ptr {s}, ptr {s})\n", .{ obj_reg, prop_str_reg, res_reg });
                    return "";
                }

                var lhs_val: []const u8 = "";
                if (self.execLookupInt(node.name)) |int_stack| {
                    const load_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ load_reg, int_stack });
                    lhs_val = try self.boxIntToPtr(load_reg);
                } else if (self.execLookup(node.name)) |stack_ptr| {
                    lhs_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ lhs_val, stack_ptr });
                } else {
                    lhs_val = try self.emitZero();
                    const stack_ptr = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr});
                    try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr});
                    try self.execAssign(node.name, stack_ptr);
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ lhs_val, stack_ptr });
                }

                const res_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @badd(ptr {s}, ptr {s})\n", .{ res_reg, lhs_val, rhs_val });

                if (self.execLookupInt(node.name)) |int_stack| {
                    const unboxed = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, res_reg });
                    try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ unboxed, int_stack });
                } else if (self.execLookup(node.name)) |stack_ptr| {
                    const old_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ old_reg, stack_ptr });
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ res_reg, stack_ptr });
                }
                return "";
            },
            .aug_assign_mul => {
                const rhs_node = node.args.?.items[0];
                if (node.target == null) {
                    if (self.execLookupInt(node.name)) |int_stack| {
                        if (try self.tryEmitAsInt(rhs_node)) |rhs_int| {
                            const lhs_int = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ lhs_int, int_stack });
                            const result_int = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = mul i64 {s}, {s}\n", .{ result_int, lhs_int, rhs_int });
                            try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ result_int, int_stack });
                            return "";
                        }
                    }
                }
                const rhs_val = try self.walkAstAndEmit(rhs_node);
                if (node.target) |target| {
                    const obj_reg = try self.walkAstAndEmit(target);
                    const prop_str_reg = try self.emitPropString(node.name);
                    const lhs_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_get_property(ptr {s}, ptr {s})\n", .{ lhs_val, obj_reg, prop_str_reg });
                    const res_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @bmul(ptr {s}, ptr {s})\n", .{ res_reg, lhs_val, rhs_val });
                    try self.getWriter().print("  call void @boblang_set_property(ptr {s}, ptr {s}, ptr {s})\n", .{ obj_reg, prop_str_reg, res_reg });
                    return "";
                }

                var lhs_val: []const u8 = "";
                if (self.execLookupInt(node.name)) |int_stack| {
                    const load_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ load_reg, int_stack });
                    lhs_val = try self.boxIntToPtr(load_reg);
                } else if (self.execLookup(node.name)) |stack_ptr| {
                    lhs_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ lhs_val, stack_ptr });
                } else {
                    lhs_val = try self.emitZero();
                    const stack_ptr = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr});
                    try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr});
                    try self.execAssign(node.name, stack_ptr);
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ lhs_val, stack_ptr });
                }

                const res_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @bmul(ptr {s}, ptr {s})\n", .{ res_reg, lhs_val, rhs_val });

                if (self.execLookupInt(node.name)) |int_stack| {
                    const unboxed = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, res_reg });
                    try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ unboxed, int_stack });
                } else if (self.execLookup(node.name)) |stack_ptr| {
                    const old_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ old_reg, stack_ptr });
                    try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ res_reg, stack_ptr });
                }
                return "";
            },
            .div => {
                const lhs_node = node.args.?.items[0];
                const rhs_node = node.args.?.items[1];
                const left_int = try self.tryEmitAsInt(lhs_node);
                const right_int = try self.tryEmitAsInt(rhs_node);
                if (left_int != null and right_int != null) {
                    const a = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = sitofp i64 {s} to double\n", .{ a, left_int.? });
                    const b = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = sitofp i64 {s} to double\n", .{ b, right_int.? });
                    const d = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = fdiv double {s}, {s}\n", .{ d, a, b });
                    const reg = try self.llvm.nextRegister();
                    const fbits = try self.llvm.nextRegister();
                    const fclear = try self.llvm.nextRegister();
                    const ftag = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = bitcast double {s} to i64\n", .{ fbits, d });
                    try self.getWriter().print("  {s} = and i64 {s}, -8\n", .{ fclear, fbits });
                    try self.getWriter().print("  {s} = or i64 {s}, 4\n", .{ ftag, fclear });
                    try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, ftag });
                    return reg;
                }
                const left = try self.walkAstAndEmit(lhs_node);
                const right = try self.walkAstAndEmit(rhs_node);
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @bdiv(ptr {s}, ptr {s})\n", .{ reg, left, right });
                return reg;
            },
            .pow => {
                const lhs_node = node.args.?.items[0];
                const rhs_node = node.args.?.items[1];
                const left_int = try self.tryEmitAsInt(lhs_node);
                const right_int = try self.tryEmitAsInt(rhs_node);
                if (left_int != null and right_int != null) {
                    const a = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = sitofp i64 {s} to double\n", .{ a, left_int.? });
                    const b = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = sitofp i64 {s} to double\n", .{ b, right_int.? });
                    const p = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call double @llvm.pow.f64(double {s}, double {s})\n", .{ p, a, b });
                    const reg = try self.llvm.nextRegister();
                    const fbits = try self.llvm.nextRegister();
                    const fclear = try self.llvm.nextRegister();
                    const ftag = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = bitcast double {s} to i64\n", .{ fbits, p });
                    try self.getWriter().print("  {s} = and i64 {s}, -8\n", .{ fclear, fbits });
                    try self.getWriter().print("  {s} = or i64 {s}, 4\n", .{ ftag, fclear });
                    try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, ftag });
                    return reg;
                }
                const left = try self.walkAstAndEmit(lhs_node);
                const right = try self.walkAstAndEmit(rhs_node);
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @bpow(ptr {s}, ptr {s})\n", .{ reg, left, right });
                return reg;
            },
            .in_op => {
                const lhs = try self.walkAstAndEmit(node.args.?.items[0]);
                const rhs = try self.walkAstAndEmit(node.args.?.items[1]);
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_contains(ptr {s}, ptr {s})\n", .{ reg, lhs, rhs });
                return reg;
            },
            .coalesce => {
                const lhs = try self.walkAstAndEmit(node.args.?.items[0]);
                const is_null = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call i32 @boblang_is_null(ptr {s})\n", .{ is_null, lhs });
                const lbl_id = self.llvm.reg_count;
                const use_rhs_lbl = try std.fmt.allocPrint(self.allocator, ".coal_rhs_{d}", .{lbl_id});
                defer self.allocator.free(use_rhs_lbl);
                const use_lhs_lbl = try std.fmt.allocPrint(self.allocator, ".coal_lhs_{d}", .{lbl_id});
                defer self.allocator.free(use_lhs_lbl);
                const end_lbl = try std.fmt.allocPrint(self.allocator, ".coal_end_{d}", .{lbl_id});
                defer self.allocator.free(end_lbl);
                const rhs_reg = try self.walkAstAndEmit(node.args.?.items[1]);
                const is_null_i1 = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = icmp ne i32 {s}, 0\n", .{ is_null_i1, is_null });
                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_null_i1, use_rhs_lbl, use_lhs_lbl });
                try self.getWriter().print("\n{s}:\n", .{use_rhs_lbl});
                try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                try self.getWriter().print("\n{s}:\n", .{use_lhs_lbl});
                try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                try self.getWriter().print("\n{s}:\n", .{end_lbl});
                const result = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ result, rhs_reg, use_rhs_lbl, lhs, use_lhs_lbl });
                return result;
            },
            .add, .sub, .mul, .mod, .int_div, .eq, .ne, .lt, .gt, .le, .ge => {
                const lhs = node.args.?.items[0];
                const rhs = node.args.?.items[1];
                if (lhs.node_type == .val_int and rhs.node_type == .val_int) {
                    const a = lhs.val_int;
                    const b = rhs.val_int;
                    const result: i64 = switch (node.node_type) {
                        .add => a + b,
                        .sub => a - b,
                        .mul => a * b,
                        .int_div => if (b != 0) @divTrunc(a, b) else 0,
                        .mod => if (b != 0) @mod(a, b) else 0,
                        .eq => if (a == b) 1 else 0,
                        .ne => if (a != b) 1 else 0,
                        .lt => if (a < b) 1 else 0,
                        .gt => if (a > b) 1 else 0,
                        .le => if (a <= b) 1 else 0,
                        .ge => if (a >= b) 1 else 0,
                        else => unreachable,
                    };
                    switch (node.node_type) {
                        .eq, .ne, .lt, .gt, .le, .ge => {
                            const reg = try self.llvm.nextRegister();
                            const v: i64 = if (result != 0) 1 else 0;
                            const tagged = (v << 2) | 2;
                            try self.getWriter().print("  {s} = inttoptr i64 {d} to ptr\n", .{ reg, tagged });
                            return reg;
                        },
                        else => return try self.makeTint(result),
                    }
                }
                const left_int = try self.tryEmitAsInt(lhs);
                const right_int = try self.tryEmitAsInt(rhs);
                if (left_int != null and right_int != null) {
                    const l = left_int.?;
                    const r = right_int.?;
                    const is_bool = switch (node.node_type) {
                        .eq, .ne, .lt, .gt, .le, .ge => true,
                        else => false,
                    };
                    if (is_bool) {
                        const cmp = switch (node.node_type) {
                            .eq => "icmp eq",
                            .ne => "icmp ne",
                            .lt => "icmp slt",
                            .gt => "icmp sgt",
                            .le => "icmp sle",
                            .ge => "icmp sge",
                            else => unreachable,
                        };
                        const cmp_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ cmp_reg, cmp, l, r });
                        const ext_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = zext i1 {s} to i64\n", .{ ext_reg, cmp_reg });
                        const tmp_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = shl i64 {s}, 2\n", .{ tmp_reg, ext_reg });
                        const or_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = or i64 {s}, 2\n", .{ or_reg, tmp_reg });
                        const reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, or_reg });
                        return reg;
                    } else {
                        const op = switch (node.node_type) {
                            .add => "add",
                            .sub => "sub",
                            .mul => "mul",
                            .int_div => "sdiv",
                            .mod => "srem",
                            else => unreachable,
                        };
                        if (node.node_type == .int_div or node.node_type == .mod) {
                            const rhs_node = node.args.?.items[1];
                            if (rhs_node.node_type == .val_int and rhs_node.val_int == 0) {
                                return try self.makeTint(0);
                            }
                            if (rhs_node.node_type == .val_int) {
                                const res_int = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ res_int, op, l, r });
                                const tmp = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ tmp, res_int });
                                const or_reg = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ or_reg, tmp });
                                const reg = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, or_reg });
                                return reg;
                            }
                            const zero_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = icmp eq i64 {s}, 0\n", .{ zero_reg, r });
                            const label_id = self.llvm.reg_count;
                            const zero_lbl = try std.fmt.allocPrint(self.allocator, "div_zero_{d}", .{label_id});
                            const normal_lbl = try std.fmt.allocPrint(self.allocator, "div_normal_{d}", .{label_id});
                            const end_lbl = try std.fmt.allocPrint(self.allocator, "div_end_{d}", .{label_id});
                            defer self.allocator.free(zero_lbl);
                            defer self.allocator.free(normal_lbl);
                            defer self.allocator.free(end_lbl);
                            const result_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ zero_reg, zero_lbl, normal_lbl });
                            try self.getWriter().print("\n{s}:\n", .{zero_lbl});
                            try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                            try self.getWriter().print("\n{s}:\n", .{normal_lbl});
                            try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ result_reg, op, l, r });
                            try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                            try self.getWriter().print("\n{s}:\n", .{end_lbl});
                            const res_int = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = phi i64 [0, %{s}], [{s}, %{s}]\n", .{ res_int, zero_lbl, result_reg, normal_lbl });
                            const tmp = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ tmp, res_int });
                            const or_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ or_reg, tmp });
                            const reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, or_reg });
                            return reg;
                        }
                        const res_int = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ res_int, op, l, r });
                        const tmp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ tmp, res_int });
                        const or_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ or_reg, tmp });
                        const reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ reg, or_reg });
                        return reg;
                    }
                }
                if (switch (node.node_type) {
                    .add, .sub, .mul, .div => true,
                    else => false,
                }) {
                    const left_float = try self.tryEmitAsFloat(lhs);
                    const right_float = try self.tryEmitAsFloat(rhs);
                    if (left_float != null and right_float != null) {
                        const lf = left_float.?;
                        const rf = right_float.?;
                        const op = switch (node.node_type) {
                            .add => "fadd",
                            .sub => "fsub",
                            .mul => "fmul",
                            .div => "fdiv",
                            else => unreachable,
                        };
                        const res = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = {s} double {s}, {s}\n", .{ res, op, lf, rf });
                        return try self.boxFloatToPtr(res);
                    }
                }
                const left = try self.walkAstAndEmit(lhs);
                const right = try self.walkAstAndEmit(rhs);
                const label_id = self.llvm.reg_count;
                const fast_lbl = try std.fmt.allocPrint(self.allocator, "op_fast_{d}", .{label_id});
                const slow_lbl = try std.fmt.allocPrint(self.allocator, "op_slow_{d}", .{label_id});
                const end_lbl = try std.fmt.allocPrint(self.allocator, "op_end_{d}", .{label_id});
                defer self.allocator.free(fast_lbl);
                defer self.allocator.free(slow_lbl);
                defer self.allocator.free(end_lbl);
                const left_i = try self.llvm.nextRegister();
                const right_i = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = ptrtoint ptr {s} to i64\n", .{ left_i, left });
                try self.getWriter().print("  {s} = ptrtoint ptr {s} to i64\n", .{ right_i, right });
                const l_tag = try self.llvm.nextRegister();
                const r_tag = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = and i64 {s}, 1\n", .{ l_tag, left_i });
                try self.getWriter().print("  {s} = and i64 {s}, 1\n", .{ r_tag, right_i });
                const both_tag = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = and i64 {s}, {s}\n", .{ both_tag, l_tag, r_tag });
                const is_fast = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = icmp eq i64 {s}, 1\n", .{ is_fast, both_tag });
                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_fast, fast_lbl, slow_lbl });
                try self.getWriter().print("\n{s}:\n", .{fast_lbl});
                const l_val = try self.llvm.nextRegister();
                const r_val = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = ashr i64 {s}, 1\n", .{ l_val, left_i });
                try self.getWriter().print("  {s} = ashr i64 {s}, 1\n", .{ r_val, right_i });
                const is_bool = switch (node.node_type) {
                    .eq, .ne, .lt, .gt, .le, .ge => true,
                    else => false,
                };
                if (is_bool) {
                    const cmp = switch (node.node_type) {
                        .eq => "icmp eq",
                        .ne => "icmp ne",
                        .lt => "icmp slt",
                        .gt => "icmp sgt",
                        .le => "icmp sle",
                        .ge => "icmp sge",
                        else => unreachable,
                    };
                    const cmp_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ cmp_reg, cmp, l_val, r_val });
                    const ext_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = zext i1 {s} to i64\n", .{ ext_reg, cmp_reg });
                    const tmp_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = shl i64 {s}, 2\n", .{ tmp_reg, ext_reg });
                    const or_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = or i64 {s}, 2\n", .{ or_reg, tmp_reg });
                    const fast_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ fast_res, or_reg });
                    try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                    try self.getWriter().print("\n{s}:\n", .{slow_lbl});
                    const op_func = switch (node.node_type) {
                        .eq => "beq",
                        .ne => "bneq",
                        .lt => "blt",
                        .gt => "bgt",
                        .le => "ble",
                        .ge => "bge",
                        else => unreachable,
                    };
                    const slow_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @{s}(ptr {s}, ptr {s})\n", .{ slow_res, op_func, left, right });
                    try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                    try self.getWriter().print("\n{s}:\n", .{end_lbl});
                    const phi_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ phi_res, fast_res, fast_lbl, slow_res, slow_lbl });
                    return phi_res;
                } else {
                    if (node.node_type == .int_div or node.node_type == .mod) {
                        const rhs_node = node.args.?.items[1];
                        const rhs_val: i64 = if (rhs_node.node_type == .val_int) rhs_node.val_int else 0;
                        const rhs_known_int = rhs_node.node_type == .val_int;
                        if (rhs_known_int and rhs_val == 0) {
                            const fast_res = try self.makeTint(0);
                            try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                            try self.getWriter().print("\n{s}:\n", .{slow_lbl});
                            const slow_res = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call ptr @bmod(ptr {s}, ptr {s})\n", .{ slow_res, left, right });
                            try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                            try self.getWriter().print("\n{s}:\n", .{end_lbl});
                            const phi_res = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ phi_res, fast_res, fast_lbl, slow_res, slow_lbl });
                            return phi_res;
                        }
                        const idiv_op = if (node.node_type == .int_div) "sdiv" else "srem";
                        if (rhs_known_int) {
                            const fi_res = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ fi_res, idiv_op, l_val, r_val });
                            const fi_tmp = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ fi_tmp, fi_res });
                            const fi_or = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ fi_or, fi_tmp });
                            const fast_res = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ fast_res, fi_or });
                            try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                            try self.getWriter().print("\n{s}:\n", .{slow_lbl});
                            const slow_res = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call ptr @{s}(ptr {s}, ptr {s})\n", .{ slow_res, if (node.node_type == .int_div) "bidiv" else "bmod", left, right });
                            try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                            try self.getWriter().print("\n{s}:\n", .{end_lbl});
                            const phi_res = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ phi_res, fast_res, fast_lbl, slow_res, slow_lbl });
                            return phi_res;
                        }

                        const zero = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = icmp eq i64 {s}, 0\n", .{ zero, r_val });
                        const div_zero_lbl = try std.fmt.allocPrint(self.allocator, "div_zero_{d}", .{label_id});
                        const div_normal_lbl = try std.fmt.allocPrint(self.allocator, "div_normal_{d}", .{label_id});
                        const div_end_lbl = try std.fmt.allocPrint(self.allocator, "div_end_{d}", .{label_id});
                        defer self.allocator.free(div_zero_lbl);
                        defer self.allocator.free(div_normal_lbl);
                        defer self.allocator.free(div_end_lbl);
                        const div_res = try self.llvm.nextRegister();
                        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ zero, div_zero_lbl, div_normal_lbl });
                        try self.getWriter().print("\n{s}:\n", .{div_zero_lbl});
                        try self.getWriter().print("  br label %{s}\n", .{div_end_lbl});
                        try self.getWriter().print("\n{s}:\n", .{div_normal_lbl});
                        try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ div_res, idiv_op, l_val, r_val });
                        try self.getWriter().print("  br label %{s}\n", .{div_end_lbl});
                        try self.getWriter().print("\n{s}:\n", .{div_end_lbl});
                        const fi_res = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = phi i64 [0, %{s}], [{s}, %{s}]\n", .{ fi_res, div_zero_lbl, div_res, div_normal_lbl });
                        const fi_tmp = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ fi_tmp, fi_res });
                        const fi_or = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ fi_or, fi_tmp });
                        const fast_res = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ fast_res, fi_or });
                        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                        try self.getWriter().print("\n{s}:\n", .{slow_lbl});
                        const op_func = if (node.node_type == .int_div) "bidiv" else "bmod";
                        const slow_res = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @{s}(ptr {s}, ptr {s})\n", .{ slow_res, op_func, left, right });
                        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                        try self.getWriter().print("\n{s}:\n", .{end_lbl});
                        const phi_res = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ phi_res, fast_res, div_end_lbl, slow_res, slow_lbl });
                        return phi_res;
                    }
                    const op = switch (node.node_type) {
                        .add => "add",
                        .sub => "sub",
                        .mul => "mul",
                        else => unreachable,
                    };
                    const res_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = {s} i64 {s}, {s}\n", .{ res_val, op, l_val, r_val });
                    const tmp = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = shl i64 {s}, 1\n", .{ tmp, res_val });
                    const or_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = or i64 {s}, 1\n", .{ or_reg, tmp });
                    const fast_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ fast_res, or_reg });
                    try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                    try self.getWriter().print("\n{s}:\n", .{slow_lbl});
                    const op_func = switch (node.node_type) {
                        .add => "badd",
                        .sub => "bsub",
                        .mul => "bmul",
                        else => unreachable,
                    };
                    const slow_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @{s}(ptr {s}, ptr {s})\n", .{ slow_res, op_func, left, right });
                    try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                    try self.getWriter().print("\n{s}:\n", .{end_lbl});
                    const phi_res = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ phi_res, fast_res, fast_lbl, slow_res, slow_lbl });
                    return phi_res;
                }
            },
            .and_op, .or_op => {
                const lhs_reg = try self.walkAstAndEmit(node.args.?.items[0]);
                const cond_i1 = try self.emitTruthyCheck(lhs_reg);
                const label_id = self.llvm.reg_count;
                const rhs_lbl = try std.fmt.allocPrint(self.allocator, "logical_rhs_{d}", .{label_id});
                const merge_lbl = try std.fmt.allocPrint(self.allocator, "logical_merge_{d}", .{label_id});
                defer self.allocator.free(rhs_lbl);
                defer self.allocator.free(merge_lbl);
                const is_and = node.node_type == .and_op;
                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ lhs_reg, self.llvm.entry_scratch });
                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ cond_i1, if (is_and) rhs_lbl else merge_lbl, if (is_and) merge_lbl else rhs_lbl });
                try self.getWriter().print("\n{s}:\n", .{rhs_lbl});
                const rhs_reg = try self.walkAstAndEmit(node.args.?.items[1]);
                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ rhs_reg, self.llvm.entry_scratch });
                try self.getWriter().print("  br label %{s}\n", .{merge_lbl});
                try self.getWriter().print("\n{s}:\n", .{merge_lbl});
                const reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ reg, self.llvm.entry_scratch });
                return reg;
            },
            .if_stmt => {
                const cond_i1 = if (try self.tryEmitCondAsI1(node.args.?.items[0])) |i1_reg| blk: {
                    break :blk i1_reg;
                } else blk: {
                    const cond_reg = try self.walkAstAndEmit(node.args.?.items[0]);
                    break :blk try self.emitTruthyCheck(cond_reg);
                };

                const label_id = self.llvm.reg_count;
                const if_true = try std.fmt.allocPrint(self.allocator, "if_true_{d}", .{label_id});
                defer self.allocator.free(if_true);
                const if_end = try std.fmt.allocPrint(self.allocator, "if_end_{d}", .{label_id});
                defer self.allocator.free(if_end);

                var next_branch = if_end;
                var elif_labels = std.ArrayList([]const u8).init(self.allocator);
                defer {
                    for (elif_labels.items) |lbl| self.allocator.free(lbl);
                    elif_labels.deinit();
                }

                if (node.elifs) |elifs| {
                    if (elifs.items.len > 0) {
                        const next_id = label_id + 100;
                        const first_elif = try std.fmt.allocPrint(self.allocator, "elif_cond_{d}_0", .{next_id});
                        next_branch = first_elif;
                    }
                } else if (node.else_tree != null) {
                    const next_id = label_id + 200;
                    const else_lbl = try std.fmt.allocPrint(self.allocator, "else_branch_{d}", .{next_id});
                    next_branch = else_lbl;
                }

                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ cond_i1, if_true, next_branch });
                try self.getWriter().print("\n{s}:\n", .{if_true});

                var reachable = false;

                self.func_ended = false;
                if (node.subtree) |sub| {
                    for (sub.items) |child| {
                        if (self.func_ended) break;
                        _ = try self.emitStmt(child);
                    }
                }
                if (self.func_ended) {} else {
                    try self.getWriter().print("  br label %{s}\n", .{if_end});
                    reachable = true;
                }

                if (node.elifs) |elifs| {
                    for (elifs.items, 0..) |elif_node, idx| {
                        const next_id = label_id + 100;
                        const cur_cond_lbl = try std.fmt.allocPrint(self.allocator, "elif_cond_{d}_{d}", .{ next_id, idx });
                        const cur_body_lbl = try std.fmt.allocPrint(self.allocator, "elif_body_{d}_{d}", .{ next_id, idx });

                        var elif_next = if_end;
                        if (idx + 1 < elifs.items.len) {
                            elif_next = try std.fmt.allocPrint(self.allocator, "elif_cond_{d}_{d}", .{ next_id, idx + 1 });
                        } else if (node.else_tree != null) {
                            const else_id = label_id + 200;
                            elif_next = try std.fmt.allocPrint(self.allocator, "else_branch_{d}", .{else_id});
                        }

                        try self.getWriter().print("\n{s}:\n", .{cur_cond_lbl});
                        self.func_ended = false;
                        const e_i1 = if (try self.tryEmitCondAsI1(elif_node.args.?.items[0])) |i1_reg| blk: {
                            break :blk i1_reg;
                        } else blk: {
                            const e_cond = try self.walkAstAndEmit(elif_node.args.?.items[0]);
                            break :blk try self.emitTruthyCheck(e_cond);
                        };
                        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ e_i1, cur_body_lbl, elif_next });

                        try self.getWriter().print("\n{s}:\n", .{cur_body_lbl});
                        self.func_ended = false;

                        if (elif_node.subtree) |e_sub| {
                            for (e_sub.items) |child| {
                                if (self.func_ended) break;
                                _ = try self.emitStmt(child);
                            }
                        }
                        if (self.func_ended) {} else {
                            try self.getWriter().print("  br label %{s}\n", .{if_end});
                            reachable = true;
                        }

                        self.allocator.free(cur_cond_lbl);
                        self.allocator.free(cur_body_lbl);
                    }
                }

                if (node.else_tree) |else_tree| {
                    const else_id = label_id + 200;
                    const else_lbl = try std.fmt.allocPrint(self.allocator, "else_branch_{d}", .{else_id});
                    defer self.allocator.free(else_lbl);
                    try self.getWriter().print("\n{s}:\n", .{else_lbl});

                    self.func_ended = false;
                    for (else_tree.items) |child| {
                        if (self.func_ended) break;
                        _ = try self.emitStmt(child);
                    }
                    if (self.func_ended) {} else {
                        try self.getWriter().print("  br label %{s}\n", .{if_end});
                        reachable = true;
                    }
                } else {
                    reachable = true;
                }

                if (reachable) {
                    try self.getWriter().print("\n{s}:\n", .{if_end});
                    self.func_ended = false;
                }
                return "";
            },
            .while_loop => {
                const label_id = self.llvm.reg_count;
                const w_cond = try std.fmt.allocPrint(self.allocator, "while_cond_{d}", .{label_id});
                defer self.allocator.free(w_cond);
                const w_body = try std.fmt.allocPrint(self.allocator, "while_body_{d}", .{label_id});
                defer self.allocator.free(w_body);
                const w_end = try std.fmt.allocPrint(self.allocator, "end_{d}", .{label_id});
                defer self.allocator.free(w_end);

                try self.loop_end_stack.append(label_id);
                try self.getWriter().print("  br label %{s}\n", .{w_cond});
                try self.getWriter().print("\n{s}:\n", .{w_cond});

                const cond_i1 = if (try self.tryEmitCondAsI1(node.args.?.items[0])) |i1_reg| blk: {
                    break :blk i1_reg;
                } else blk: {
                    const cond_reg = try self.walkAstAndEmit(node.args.?.items[0]);
                    break :blk try self.emitTruthyCheck(cond_reg);
                };
                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ cond_i1, w_body, w_end });

                try self.getWriter().print("\n{s}:\n", .{w_body});
                self.func_ended = false;

                if (node.subtree) |sub| {
                    for (sub.items) |child| {
                        if (self.func_ended) break;
                        _ = try self.emitStmt(child);
                    }
                }

                if (self.func_ended) {} else {
                    try self.getWriter().print("  br label %{s}\n", .{w_cond});
                }

                try self.getWriter().print("\n{s}:\n", .{w_end});
                self.func_ended = false;
                _ = self.loop_end_stack.pop();
                return "";
            },
            .for_loop => {
                const label_id = self.llvm.reg_count;
                const f_cond = try std.fmt.allocPrint(self.allocator, "for_cond_{d}", .{label_id});
                defer self.allocator.free(f_cond);
                const f_body = try std.fmt.allocPrint(self.allocator, "for_body_{d}", .{label_id});
                defer self.allocator.free(f_body);
                const f_end = try std.fmt.allocPrint(self.allocator, "end_{d}", .{label_id});
                defer self.allocator.free(f_end);

                const iter_node = node.args.?.items[0];
                const is_range = iter_node.node_type == .call and std.mem.eql(u8, iter_node.name, "range") and iter_node.args != null;

                if (is_range) {
                    const range_args = iter_node.args.?;
                    const range_arity = range_args.items.len;
                    const end_reg = try self.walkAstAndEmit(range_args.items[if (range_arity >= 2) 1 else 0]);

                    const counter_ptr = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = alloca i64, align 8\n", .{counter_ptr});
                    if (range_arity >= 2) {
                        const start_reg = try self.walkAstAndEmit(range_args.items[0]);
                        const init_val = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ init_val, start_reg });
                        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ init_val, counter_ptr });
                    } else {
                        try self.getWriter().print("  store i64 0, ptr {s}, align 8\n", .{counter_ptr});
                    }

                    try self.loop_end_stack.append(label_id);
                    try self.getWriter().print("  br label %{s}\n", .{f_cond});
                    try self.getWriter().print("\n{s}:\n", .{f_cond});

                    const cur_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ cur_val, counter_ptr });
                    const end_int = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ end_int, end_reg });
                    const step_int = try self.llvm.nextRegister();
                    if (range_arity >= 3) {
                        const step_reg = try self.walkAstAndEmit(range_args.items[2]);
                        try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ step_int, step_reg });
                    } else {
                        try self.getWriter().print("  {s} = or i64 0, 1\n", .{step_int});
                    }
                    const step_pos = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = icmp sgt i64 {s}, 0\n", .{ step_pos, step_int });
                    const cond_pos = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = icmp slt i64 {s}, {s}\n", .{ cond_pos, cur_val, end_int });
                    const cond_neg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = icmp sgt i64 {s}, {s}\n", .{ cond_neg, cur_val, end_int });
                    const cond = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = select i1 {s}, i1 {s}, i1 {s}\n", .{ cond, step_pos, cond_pos, cond_neg });
                    try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ cond, f_body, f_end });

                    try self.getWriter().print("\n{s}:\n", .{f_body});

                    const elem_val = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i64, ptr {s}, align 8\n", .{ elem_val, counter_ptr });
                    var int_ptr = self.execLookupInt(node.name);
                    const is_new_int_var = int_ptr == null;
                    if (is_new_int_var) {
                        int_ptr = try self.llvm.allocIntSlot(self.getWriter());
                        try self.execAssignInt(node.name, int_ptr.?);
                    }
                    try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ elem_val, int_ptr.? });
                    self.func_ended = false;

                    if (node.subtree) |sub| {
                        for (sub.items) |child| {
                            if (self.func_ended) break;
                            _ = try self.emitStmt(child);
                        }
                    }

                    if (self.func_ended) {} else {
                        const next_val = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = add i64 {s}, {s}\n", .{ next_val, elem_val, step_int });
                        try self.getWriter().print("  store i64 {s}, ptr {s}, align 8\n", .{ next_val, counter_ptr });
                        try self.getWriter().print("  br label %{s}\n", .{f_cond});
                    }

                    try self.getWriter().print("\n{s}:\n", .{f_end});
                    self.func_ended = false;
                    _ = self.loop_end_stack.pop();
                    return "";
                }

                const iterable = try self.walkAstAndEmit(iter_node);
                const size_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call i32 @boblang_list_size_raw(ptr {s})\n", .{ size_reg, iterable });

                const items_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_list_items(ptr {s})\n", .{ items_reg, iterable });

                const idx_ptr = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = alloca i32, align 4\n", .{idx_ptr});
                try self.getWriter().print("  store i32 0, ptr {s}, align 4\n", .{idx_ptr});

                var var_ptr = self.execLookup(node.name);
                const is_new_var = var_ptr == null;
                if (is_new_var) {
                    var_ptr = try self.llvm.allocScratchPtr(self.getWriter());
                    try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{var_ptr.?});
                    try self.getWriter().print("  store ptr null, ptr {s}, align 8\n", .{var_ptr.?});
                    try self.execAssign(node.name, var_ptr.?);
                }

                try self.loop_end_stack.append(label_id);
                try self.getWriter().print("  br label %{s}\n", .{f_cond});
                try self.getWriter().print("\n{s}:\n", .{f_cond});

                const idx_val = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load i32, ptr {s}, align 4\n", .{ idx_val, idx_ptr });
                const done = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = icmp slt i32 {s}, {s}\n", .{ done, idx_val, size_reg });
                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ done, f_body, f_end });

                try self.getWriter().print("\n{s}:\n", .{f_body});

                const idx_ext = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ idx_ext, idx_val });
                const elem_ptr2 = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = getelementptr ptr, ptr {s}, i64 {s}\n", .{ elem_ptr2, items_reg, idx_ext });
                const elem = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ elem, elem_ptr2 });

                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ elem, var_ptr.? });

                self.func_ended = false;
                if (node.subtree) |sub| {
                    for (sub.items) |child| {
                        if (self.func_ended) break;
                        _ = try self.emitStmt(child);
                    }
                }

                if (self.func_ended) {} else {
                    const next_idx = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = add i32 {s}, 1\n", .{ next_idx, idx_val });
                    try self.getWriter().print("  store i32 {s}, ptr {s}, align 4\n", .{ next_idx, idx_ptr });
                    try self.getWriter().print("  br label %{s}\n", .{f_cond});
                }

                try self.getWriter().print("\n{s}:\n", .{f_end});
                self.func_ended = false;
                _ = self.loop_end_stack.pop();
                return "";
            },
            .break_stmt => {
                if (self.loop_end_stack.items.len > 0) {
                    const end_label = self.loop_end_stack.items[self.loop_end_stack.items.len - 1];
                    try self.getWriter().print("  br label %end_{d}\n", .{end_label});
                    self.func_ended = true;
                }
                return "";
            },
            .pass_stmt => {
                return "";
            },
            .func_def => {
                if (node.is_extern) {
                    return "";
                }
                const old_inside = self.is_inside_func;
                const old_closure = self.is_inside_closure;
                const saved_scratch = self.llvm.saveScratchState();
                const saved_int = self.llvm.saveIntSlotState();
                const saved_float = self.llvm.saveFloatSlotState();
                const old_ended = self.func_ended;
                const old_recursion_checked = self.current_func_recursion_checked;
                const old_loop_head = self.current_func_loop_head;
                const old_func_name = self.current_func_name;
                const saved_arg_slots = self.current_func_arg_slots;
                self.func_ended = false;
                self.current_func_loop_head = null;
                self.current_func_name = null;
                self.current_func_arg_slots = std.ArrayList([]const u8).init(self.allocator);
                self.is_inside_func = true;

                const is_method = self.current_class_name.len > 0;
                const is_module_func = self.current_module_prefix != null;
                const sym_part = try self.junkName(node.name);
                const func_name = if (is_method)
                    try std.fmt.allocPrint(self.allocator, "bob_class_{s}_{s}", .{ try self.junkName(self.current_class_name), sym_part })
                else if (is_module_func)
                    try std.fmt.allocPrint(self.allocator, "bob_mod_{s}_{s}", .{ self.current_module_prefix.?, sym_part })
                else
                    try std.fmt.allocPrint(self.allocator, "bob_{s}", .{sym_part});
                defer self.allocator.free(func_name);

                const declared_arity = if (node.args) |args| args.items.len else 0;
                self.current_func_name = node.name;

                const is_nested = old_inside;
                if (is_nested) self.is_inside_closure = true;

                if (self.emitted_funcs.get(func_name)) |first_line| {
                    const display = if (is_method)
                        try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_class_name, node.name })
                    else if (is_module_func)
                        try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_module_prefix.?, node.name })
                    else
                        try self.allocator.dupe(u8, node.name);
                    defer self.allocator.free(display);
                    const msg = try std.fmt.allocPrint(self.allocator, "function '{s}' is already defined", .{display});
                    defer self.allocator.free(msg);
                    errors.printSemanticError(node.line, msg);
                    const note = try std.fmt.allocPrint(self.allocator, "function '{s}' was first defined here", .{display});
                    defer self.allocator.free(note);
                    errors.printSemanticNote(first_line, note);
                    std.process.exit(1);
                }
                try self.emitted_funcs.put(try self.allocator.dupe(u8, func_name), node.line);

                try self.getWriter().print("\ndefine ptr @{s}(", .{func_name});
                if (is_method) {
                    try self.getWriter().print("ptr %arg_self", .{});
                    if (declared_arity > 0) try self.getWriter().print(", ", .{});
                }
                var i: usize = 0;
                while (i < declared_arity) : (i += 1) {
                    try self.getWriter().print("ptr %arg_{d}", .{i});
                    if (i < declared_arity - 1) try self.getWriter().print(", ", .{});
                }
                try self.getWriter().print(") {{\nentry:\n", .{});

                {
                    const fn_str = try self.llvm.buildGlobalString(try self.junkName(node.name));
                    try self.getWriter().print("  call void @boblang_push_frame(ptr {s})\n", .{fn_str});
                }

                var has_recursive_decorator = false;
                if (node.decorators) |decorators| {
                    for (decorators.items) |dec| {
                        if (dec.node_type == .var_ref and dec.target == null and std.mem.eql(u8, dec.name, "recursive")) {
                            has_recursive_decorator = true;
                            break;
                        }
                    }
                }

                if (has_recursive_decorator) {
                    self.current_func_recursion_checked = false;
                } else {
                    self.current_func_recursion_checked = true;
                    const rid = self.llvm.reg_count;
                    const exc_lbl = try std.fmt.allocPrint(self.allocator, "rec_exc_{d}", .{rid});
                    defer self.allocator.free(exc_lbl);
                    const ok_lbl = try std.fmt.allocPrint(self.allocator, "rec_ok_{d}", .{rid});
                    defer self.allocator.free(ok_lbl);
                    const d0 = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i32, ptr @boblang_recursion_depth\n", .{d0});
                    const d1 = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = add i32 {s}, 1\n", .{ d1, d0 });
                    try self.getWriter().print("  store i32 {s}, ptr @boblang_recursion_depth\n", .{d1});
                    const dlim = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = icmp sgt i32 {s}, {d}\n", .{ dlim, d1, RECURSION_LIMIT });
                    try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ dlim, exc_lbl, ok_lbl });
                    try self.getWriter().print("\n{s}:\n", .{exc_lbl});
                    const wmsg = try self.llvm.buildGlobalString("warning: max recursion limit exceeded\n");
                    const wreg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_str_new(ptr {s})\n", .{ wreg, wmsg });
                    try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{wreg});
                    const d2 = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load i32, ptr @boblang_recursion_depth\n", .{d2});
                    const d3 = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = sub i32 {s}, 1\n", .{ d3, d2 });
                    try self.getWriter().print("  store i32 {s}, ptr @boblang_recursion_depth\n", .{d3});
                    const nreg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = inttoptr i64 0 to ptr\n", .{nreg});
                    try self.getWriter().print("  call void @boblang_pop_frame()\n", .{});
                    try self.getWriter().print("  ret ptr {s}\n", .{nreg});
                    try self.getWriter().print("\n{s}:\n", .{ok_lbl});
                }

                if (node.args) |args| {
                    for (args.items) |arg| {
                        if (std.mem.eql(u8, arg.name, "_prev_") and !self.current_class_has_base) {
                            errors.printCompileError("", "_prev_ parameter is only valid in inheriting classes\n");
                            std.process.exit(1);
                        }
                        if (std.mem.eql(u8, arg.name, "self")) {
                            errors.printCompileError("", "'self' is implicit and cannot be declared as a parameter\n");
                            std.process.exit(1);
                        }
                    }
                }
                try self.pushScope();
                if (is_method) {
                    const stack_ptr = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr});
                    try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr});
                    try self.getWriter().print("  store ptr null, ptr {s}, align 8\n", .{stack_ptr});
                    try self.getWriter().print("  store ptr %arg_self, ptr {s}, align 8\n", .{stack_ptr});
                    try self.execAssign("self", stack_ptr);
                }
                if (node.args) |args| {
                    for (args.items, 0..) |arg, idx| {
                        const stack_ptr = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr});
                        try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr});
                        try self.getWriter().print("  store ptr null, ptr {s}, align 8\n", .{stack_ptr});
                        try self.getWriter().print("  store ptr %arg_{d}, ptr {s}, align 8\n", .{ idx, stack_ptr });
                        try self.current_func_arg_slots.append(stack_ptr);
                        const has_default = arg.args != null and arg.args.?.items.len > 0;
                        if (has_default) {
                            const is_null = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = icmp eq ptr %arg_{d}, null\n", .{ is_null, idx });
                            const lbl_id = self.llvm.reg_count;
                            const use_def_lbl = try std.fmt.allocPrint(self.allocator, ".use_def_{d}", .{lbl_id});
                            const after_def_lbl = try std.fmt.allocPrint(self.allocator, ".after_def_{d}", .{lbl_id});
                            defer self.allocator.free(use_def_lbl);
                            defer self.allocator.free(after_def_lbl);
                            try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_null, use_def_lbl, after_def_lbl });
                            try self.getWriter().print("\n{s}:\n", .{use_def_lbl});
                            const default_val = try self.walkAstAndEmit(arg.args.?.items[0]);
                            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ default_val, stack_ptr });
                            try self.getWriter().print("  br label %{s}\n", .{after_def_lbl});
                            try self.getWriter().print("\n{s}:\n", .{after_def_lbl});
                        }
                        try self.execAssign(arg.name, stack_ptr);
                        if (arg.extra) |arg_type| {
                            if (arg.is_optional) {
                                const not_null = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = icmp ne ptr %arg_{d}, null\n", .{ not_null, idx });
                                const lbl_id = self.llvm.reg_count;
                                const chk_lbl = try std.fmt.allocPrint(self.allocator, ".type_chk_{d}", .{lbl_id});
                                const skp_lbl = try std.fmt.allocPrint(self.allocator, ".type_skp_{d}", .{lbl_id});
                                defer self.allocator.free(chk_lbl);
                                defer self.allocator.free(skp_lbl);
                                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ not_null, chk_lbl, skp_lbl });
                                try self.getWriter().print("\n{s}:\n", .{chk_lbl});
                                const type_str = try self.llvm.buildGlobalString(arg_type);
                                const name_str = try self.llvm.buildGlobalString(arg.name);
                                try self.getWriter().print("  call void @boblang_assert_type(ptr %arg_{d}, ptr {s}, ptr {s}, i32 0)\n", .{ idx, type_str, name_str });
                                try self.getWriter().print("  br label %{s}\n", .{skp_lbl});
                                try self.getWriter().print("\n{s}:\n", .{skp_lbl});
                            } else {
                                const type_str = try self.llvm.buildGlobalString(arg_type);
                                const name_str = try self.llvm.buildGlobalString(arg.name);
                                try self.getWriter().print("  call void @boblang_assert_type(ptr %arg_{d}, ptr {s}, ptr {s}, i32 0)\n", .{ idx, type_str, name_str });
                            }
                        }
                    }
                }
                self.current_func_ret_type = if (node.extra) |rt| blk: {
                    const gs = try self.llvm.buildGlobalString(rt);
                    break :blk gs;
                } else null;

                try self.hoistFunctionLocals(node);

                {
                    const faddr = try self.llvm.buildGlobalString(try self.fileToken());
                    try self.getWriter().print("  call void @boblang_set_file(ptr {s})\n", .{faddr});
                }
                try self.getWriter().print("  call void @boblang_gc_frame_begin()\n", .{});

                if (self.hasSelfTailCall(node)) {
                    const lh_id = self.llvm.reg_count;
                    const loop_head = try std.fmt.allocPrint(self.allocator, "loop_head_{d}", .{lh_id});
                    self.current_func_loop_head = loop_head;
                    try self.getWriter().print("  br label %{s}\n", .{loop_head});
                    try self.getWriter().print("\n{s}:\n", .{loop_head});
                }

                var missing_return = true;
                if (node.subtree) |sub| {
                    for (sub.items) |child| {
                        if (self.func_ended) break;
                        _ = try self.emitStmt(child);
                        if (child.node_type == .return_stmt) missing_return = false;
                    }
                }
                if (!self.func_ended) {
                    if (missing_return) {
                        try self.emitRecursionPop();
                        try self.getWriter().print("  call void @boblang_pop_frame()\n", .{});
                        try self.getWriter().print("  call void @boblang_gc_frame_end()\n", .{});
                        const def_nil = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = inttoptr i64 0 to ptr\n", .{def_nil});
                        try self.getWriter().print("  ret ptr {s}\n", .{def_nil});
                    }
                }
                try self.getWriter().print("}}\n", .{});
                if (is_nested) self.is_inside_closure = false;
                self.popScope();
                self.llvm.restoreScratchState(saved_scratch);
                self.llvm.restoreIntSlotState(saved_int);
                self.llvm.restoreFloatSlotState(saved_float);
                self.func_ended = old_ended;
                self.current_func_recursion_checked = old_recursion_checked;
                self.current_func_arg_slots.deinit();
                self.current_func_arg_slots = saved_arg_slots;
                self.current_func_loop_head = old_loop_head;
                self.current_func_name = old_func_name;

                self.is_inside_func = old_inside;
                self.is_inside_closure = old_closure;
                var required_arity: u32 = 0;
                if (node.args) |fargs| {
                    for (fargs.items) |farg| {
                        const has_default = farg.args != null and farg.args.?.items.len > 0;
                        if (!farg.is_optional and !has_default) required_arity += 1;
                    }
                }
                if (is_module_func) {
                    if (self.current_module_prefix) |prefix| {
                        if (self.bob_modules.getPtr(prefix)) |mod| {
                            try mod.arities.put(try self.allocator.dupe(u8, node.name), .{ .declared = @intCast(declared_arity), .required = required_arity });
                        }
                    }
                } else if (!is_method) {
                    try self.known_funcs.put(try self.allocator.dupe(u8, node.name), try self.allocator.dupe(u8, func_name));
                    try self.known_funcs_arity.put(try self.allocator.dupe(u8, node.name), @intCast(declared_arity));
                    try self.known_funcs_required_arity.put(try self.allocator.dupe(u8, node.name), required_arity);
                    if (!self.is_inside_func and !self.is_inside_closure and self.current_module_prefix == null) {
                        try self.wasm_exports.append(try self.allocator.dupe(u8, func_name));
                    }
                    const func_obj_reg = try self.llvm.nextRegister();
                    const fn_name_str = try self.emitPropString(node.name);
                    try self.getWriter().print("  {s} = call ptr @boblang_func_new(ptr @{s}, i32 {d}, i32 {d}, ptr {s}, ptr null, ptr null, ptr null, i32 0)\n", .{ func_obj_reg, func_name, declared_arity, declared_arity, fn_name_str });
                    if (!self.is_inside_func) {
                        const g = try self.emitTopLevelObject(node.name, func_obj_reg);
                        if (node.decorators) |decorators| {
                            try self.applyDecorators(decorators, g);
                        }
                    } else {
                        var stack_ptr = self.execLookup(node.name);
                        if (stack_ptr == null) {
                            stack_ptr = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr.?});
                            try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr.?});
                            try self.execAssign(node.name, stack_ptr.?);
                        }
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ func_obj_reg, stack_ptr.? });
                        if (node.decorators) |decorators| {
                            try self.applyDecorators(decorators, stack_ptr.?);
                        }
                    }
                }
                return "";
            },
            .return_stmt => {
                if (self.is_inside_func) {
                    const ret_expr = node.args.?.items[0];
                    if (ret_expr.node_type == .call and ret_expr.target == null and
                        self.current_func_loop_head != null and
                        self.current_func_name != null and
                        std.mem.eql(u8, ret_expr.name, self.current_func_name.?) and
                        ret_expr.args != null and ret_expr.args.?.items.len == self.current_func_arg_slots.items.len)
                    {
                        try self.emitSelfTailCall(ret_expr);
                        self.func_ended = true;
                        return "";
                    }
                    const val = try self.walkAstAndEmit(ret_expr);
                    if (self.current_func_ret_type) |ret_type| {
                        const ret_name_str = try self.llvm.buildGlobalString("return value");
                        try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ val, ret_type, ret_name_str, node.line });
                    }
                    try self.emitRecursionPop();
                    try self.getWriter().print("  call void @boblang_pop_frame()\n", .{});
                    try self.getWriter().print("  call void @boblang_gc_frame_end()\n", .{});
                    try self.getWriter().print("  ret ptr {s}\n", .{val});
                } else {
                    try self.getWriter().print("  ret i32 0\n", .{});
                }
                self.func_ended = true;
                return "";
            },
            .call => {
                const callee = node.name;

                var arg_regs = std.ArrayList([]const u8).init(self.allocator);
                var arg_owned = std.ArrayList(bool).init(self.allocator);
                defer {
                    for (arg_regs.items) |r| self.allocator.free(r);
                    arg_regs.deinit();
                    arg_owned.deinit();
                }
                const is_print_call = std.mem.eql(u8, callee, "print");
                if (node.args) |args| {
                    for (args.items) |arg| {
                        const r = try self.walkAstAndEmit(arg);
                        if (!is_print_call and !arg.is_optional and arg.node_type != .val_nil) {
                            const null_ok = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = icmp eq ptr {s}, null\n", .{ null_ok, r });
                            const lbl_id = self.llvm.reg_count;
                            const null_lbl = try std.fmt.allocPrint(self.allocator, ".null_arg_{d}", .{lbl_id});
                            const ok_lbl = try std.fmt.allocPrint(self.allocator, ".ok_arg_{d}", .{lbl_id});
                            defer self.allocator.free(null_lbl);
                            defer self.allocator.free(ok_lbl);
                            try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ null_ok, null_lbl, ok_lbl });
                            try self.getWriter().print("\n{s}:\n", .{null_lbl});
                            const null_msg = try self.llvm.buildGlobalString("null value in function call");
                            const str_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = call ptr @boblang_str_new(ptr {s})\n", .{ str_reg, null_msg });
                            try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{str_reg});
                            const file_addr = try self.llvm.buildGlobalString(try self.fileToken());
                            try self.getWriter().print("  call void @boblang_runtime_error(i32 1, ptr {s}, i32 {d})\n", .{ file_addr, node.line });
                            try self.getWriter().print("  br label %{s}\n", .{ok_lbl});
                            try self.getWriter().print("\n{s}:\n", .{ok_lbl});
                        }
                        try arg_regs.append(try self.allocator.dupe(u8, r));
                        try arg_owned.append(!isBorrowedNode(arg));
                    }
                }

                if (std.mem.startsWith(u8, callee, "js.")) {
                    const js_name = callee[3..];
                    if (js_name.len == 0 or std.mem.containsAtLeast(u8, js_name, 1, ".")) {
                        errors.printSemanticError(node.line, "js.<name> requires a single JS function name");
                        std.process.exit(1);
                    }
                    const name_addr = try self.llvm.buildGlobalString(js_name);
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_js_call(ptr {s}, i32 {d}", .{ reg, name_addr, arg_regs.items.len });
                    for (arg_regs.items) |arg_reg| {
                        try self.getWriter().print(", ptr {s}", .{arg_reg});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }

                if (node.target) |target| {
                    if (std.mem.eql(u8, callee, "_init_")) {
                        errors.printSemanticError(node.line, "cannot call _init_ directly; construct the class instead");
                        std.process.exit(1);
                    }
                    if (try self.resolveModuleCallFromTarget(target, node.name, &arg_regs, node.line)) |result| {
                        return result;
                    }
                    const obj_reg = try self.walkAstAndEmit(target);
                    if (node.is_optional) {
                        return try self.emitOptionalCall(obj_reg, callee, &arg_regs);
                    }
                    const method_str_reg = try self.emitPropString(callee);

                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_method_va(ptr {s}, ptr {s}, i32 {d}", .{ reg, obj_reg, method_str_reg, arg_regs.items.len });
                    for (arg_regs.items) |arg_reg| {
                        try self.getWriter().print(", ptr {s}", .{arg_reg});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }

                if (std.mem.containsAtLeast(u8, callee, 1, ".")) {
                    var dot_positions = std.ArrayList(usize).init(self.allocator);
                    defer dot_positions.deinit();
                    for (callee, 0..) |c, i| {
                        if (c == '.') try dot_positions.append(i);
                    }
                    var di: usize = dot_positions.items.len;
                    while (di > 0) {
                        di -= 1;
                        const split = dot_positions.items[di];
                        const mod_name = callee[0..split];
                        const func_name = callee[split + 1 ..];
                        if (self.c_modules.get(mod_name)) |mod_entry| {
                            if (mod_entry.contains(func_name)) {
                                return try self.emitCCall(mod_name, func_name, &arg_regs);
                            }
                            const mangled_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ mod_name, func_name });
                            defer self.allocator.free(mangled_name);
                            if (mod_entry.contains(mangled_name)) {
                                return try self.emitCCall(mod_name, mangled_name, &arg_regs);
                            }
                        }
                        if (self.bob_modules.contains(mod_name)) {
                            return try self.emitBobCall(mod_name, func_name, &arg_regs, node.line);
                        }
                    }
                    var it = std.mem.splitSequence(u8, callee, ".");
                    const obj_name = it.next().?;
                    const method_name = it.next().?;
                    if (std.mem.eql(u8, method_name, "_init_")) {
                        errors.printSemanticError(node.line, "cannot call _init_ directly; construct the class instead");
                        std.process.exit(1);
                    }
                    if (self.bob_modules.contains(obj_name)) {
                        return try self.emitBobCall(obj_name, method_name, &arg_regs, node.line);
                    }
                    const obj_stack = self.execLookup(obj_name) orelse {
                        try self.elookuperr(node.line);
                        return try self.emitZero();
                    };
                    const obj_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ obj_reg, obj_stack });
                    if (std.mem.eql(u8, method_name, "append") and arg_regs.items.len == 1) {
                        if (self.execLookupIntList(obj_name) != null) {
                            const rhs = node.args.?.items[0];
                            if (try self.tryEmitAsInt(rhs)) |rhs_int| {
                                try self.getWriter().print("  call void @boblang_int_list_append(ptr {s}, i64 {s})\n", .{ obj_reg, rhs_int });
                            } else {
                                const rhs_val = try self.walkAstAndEmit(rhs);
                                const type_str = try self.llvm.buildGlobalString("int");
                                const name_str = try self.llvm.buildGlobalString(obj_name);
                                try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ rhs_val, type_str, name_str, node.line });
                                const unboxed = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, rhs_val });
                                try self.getWriter().print("  call void @boblang_int_list_append(ptr {s}, i64 {s})\n", .{ obj_reg, unboxed });
                            }
                            return obj_reg;
                        }
                        if (self.execLookupFloatList(obj_name) != null) {
                            const rhs = node.args.?.items[0];
                            if (try self.tryEmitAsFloat(rhs)) |rhs_f| {
                                try self.getWriter().print("  call void @boblang_float_list_append(ptr {s}, double {s})\n", .{ obj_reg, rhs_f });
                            } else {
                                const rhs_val = try self.walkAstAndEmit(rhs);
                                const type_str = try self.llvm.buildGlobalString("float");
                                const name_str = try self.llvm.buildGlobalString(obj_name);
                                try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ rhs_val, type_str, name_str, node.line });
                                const unboxed = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unboxed, rhs_val });
                                try self.getWriter().print("  call void @boblang_float_list_append(ptr {s}, double {s})\n", .{ obj_reg, unboxed });
                            }
                            return obj_reg;
                        }
                        if (self.execLookupBoolList(obj_name) != null) {
                            const rhs = node.args.?.items[0];
                            if (try self.tryEmitAsInt(rhs)) |rhs_int| {
                                try self.getWriter().print("  call void @boblang_bool_list_append(ptr {s}, i64 {s})\n", .{ obj_reg, rhs_int });
                            } else {
                                const rhs_val = try self.walkAstAndEmit(rhs);
                                const type_str = try self.llvm.buildGlobalString("bool");
                                const name_str = try self.llvm.buildGlobalString(obj_name);
                                try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ rhs_val, type_str, name_str, node.line });
                                const unboxed = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unboxed, rhs_val });
                                try self.getWriter().print("  call void @boblang_bool_list_append(ptr {s}, i64 {s})\n", .{ obj_reg, unboxed });
                            }
                            return obj_reg;
                        }
                        if (self.generic_list_elem_types.get(obj_name)) |elem_type| {
                            if (!self.enum_types.contains(elem_type) and !std.mem.startsWith(u8, elem_type, "list[")) {
                                const type_str = try self.llvm.buildGlobalString(elem_type);
                                const name_str = try self.llvm.buildGlobalString(obj_name);
                                try self.getWriter().print("  call void @boblang_assert_type(ptr {s}, ptr {s}, ptr {s}, i32 {d})\n", .{ arg_regs.items[0], type_str, name_str, node.line });
                            }
                        }
                        const try_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call i32 @boblang_try_list_append(ptr {s}, ptr {s})\n", .{ try_reg, obj_reg, arg_regs.items[0] });
                        const is_ok = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = icmp ne i32 {s}, 0\n", .{ is_ok, try_reg });
                        const lbl_id = self.llvm.reg_count;
                        const fast_lbl = try std.fmt.allocPrint(self.allocator, ".dappend_fast_{d}", .{lbl_id});
                        defer self.allocator.free(fast_lbl);
                        const gen_lbl = try std.fmt.allocPrint(self.allocator, ".dappend_gen_{d}", .{lbl_id});
                        defer self.allocator.free(gen_lbl);
                        const end_lbl = try std.fmt.allocPrint(self.allocator, ".dappend_end_{d}", .{lbl_id});
                        defer self.allocator.free(end_lbl);
                        try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_ok, fast_lbl, gen_lbl });
                        try self.getWriter().print("\n{s}:\n", .{fast_lbl});
                        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                        try self.getWriter().print("\n{s}:\n", .{gen_lbl});
                        const method_str_reg = try self.emitPropString(method_name);
                        const reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_method_va(ptr {s}, ptr {s}, i32 {d}", .{ reg, obj_reg, method_str_reg, arg_regs.items.len });
                        for (arg_regs.items) |arg_reg| {
                            try self.getWriter().print(", ptr {s}", .{arg_reg});
                        }
                        try self.getWriter().print(")\n", .{});
                        try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                        try self.getWriter().print("\n{s}:\n", .{end_lbl});
                        const result = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = phi ptr [{s}, %{s}], [{s}, %{s}]\n", .{ result, obj_reg, fast_lbl, reg, gen_lbl });
                        return result;
                    }
                    const method_str_reg = try self.emitPropString(method_name);
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_method_va(ptr {s}, ptr {s}, i32 {d}", .{ reg, obj_reg, method_str_reg, arg_regs.items.len });
                    for (arg_regs.items) |arg_reg| {
                        try self.getWriter().print(", ptr {s}", .{arg_reg});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }

                if (std.mem.eql(u8, callee, "print")) {
                    for (arg_regs.items, 0..) |arg_reg, idx| {
                        if (idx > 0) {
                            const space_reg = try self.llvm.nextRegister();
                            try self.getWriter().print("  {s} = load ptr, ptr @STR_SPACE, align 8\n", .{space_reg});
                            try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{space_reg});
                        }
                        try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{arg_reg});
                    }
                    const nl_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr @STR_NEWLINE, align 8\n", .{nl_reg});
                    try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{nl_reg});
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{reg});
                    return reg;
                }

                if (std.mem.eql(u8, callee, "js_call")) {
                    const name_node = node.args.?.items[0];
                    if (name_node.node_type != .val_string) {
                        errors.printSemanticError(node.line, "js_call first argument must be a string literal");
                        std.process.exit(1);
                    }
                    const name_addr = try self.llvm.buildGlobalString(name_node.val_string);
                    const argc = arg_regs.items.len - 1;
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_js_call(ptr {s}, i32 {d}", .{ reg, name_addr, argc });
                    for (arg_regs.items[1..]) |arg_reg| {
                        try self.getWriter().print(", ptr {s}", .{arg_reg});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }

                if (std.mem.eql(u8, callee, "raw_int") or std.mem.eql(u8, callee, "raw_float") or std.mem.eql(u8, callee, "raw_bool")) {
                    self.warnRawType();
                    const fn_name = if (std.mem.eql(u8, callee, "raw_int")) "boblang_raw_int_new" else if (std.mem.eql(u8, callee, "raw_float")) "boblang_raw_float_new" else "boblang_raw_bool_new";
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @{s}(i64 0)\n", .{ reg, fn_name });
                    return reg;
                }

                const reg = try self.llvm.nextRegister();

                if (std.mem.eql(u8, callee, "range")) {
                    try self.getWriter().print("  {s} = call ptr @bob_range(", .{reg});
                    try self.getWriter().print("ptr {s}", .{if (arg_regs.items.len >= 1) arg_regs.items[0] else "null"});
                    try self.getWriter().print(", ptr {s}", .{if (arg_regs.items.len >= 2) arg_regs.items[1] else "null"});
                    try self.getWriter().print(", ptr {s}", .{if (arg_regs.items.len >= 3) arg_regs.items[2] else "null"});
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }

                if (self.current_module_prefix) |prefix| {
                    if (self.bob_modules.get(prefix)) |mod| {
                        if (mod.exports.get(callee)) |mangled| {
                            if (mangled.len > 0 and mangled[0] == '@') {
                                const callable_load = try self.llvm.nextRegister();
                                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ callable_load, mangled });
                                try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_callable(ptr {s}, i32 {d}", .{ reg, callable_load, arg_regs.items.len });
                                for (arg_regs.items) |arg_reg| {
                                    try self.getWriter().print(", ptr {s}", .{arg_reg});
                                }
                                try self.getWriter().print(")\n", .{});
                                return reg;
                            }
                            try self.checkModuleArity(&mod, prefix, callee, arg_regs.items.len, node.line);
                            try self.getWriter().print("  {s} = call ptr @{s}(", .{ reg, mangled });
                            for (arg_regs.items, 0..) |arg_reg, idx| {
                                try self.getWriter().print("ptr {s}", .{arg_reg});
                                if (idx < arg_regs.items.len - 1) try self.getWriter().print(", ", .{});
                            }
                            try self.getWriter().print(")\n", .{});
                            return reg;
                        }
                    }
                }

                if (self.known_funcs.get(callee)) |mangled| {
                    const expected_arity = self.known_funcs_arity.get(callee) orelse @as(u32, @intCast(arg_regs.items.len));
                    const required_arity = self.known_funcs_required_arity.get(callee) orelse expected_arity;
                    if (arg_regs.items.len < required_arity) {
                        const msg = try std.fmt.allocPrint(self.allocator, "function '{s}' expects at least {d} argument{s}, got {d}", .{ callee, required_arity, if (required_arity == 1) "" else "s", arg_regs.items.len });
                        defer self.allocator.free(msg);
                        errors.printSemanticError(node.line, msg);
                        std.process.exit(1);
                    }
                    if (arg_regs.items.len > expected_arity) {
                        const msg = try std.fmt.allocPrint(self.allocator, "function '{s}' takes at most {d} argument{s}, got {d}", .{ callee, expected_arity, if (expected_arity == 1) "" else "s", arg_regs.items.len });
                        defer self.allocator.free(msg);
                        errors.printSemanticError(node.line, msg);
                        std.process.exit(1);
                    }
                    var padded = std.ArrayList([]const u8).init(self.allocator);
                    defer padded.deinit();
                    for (arg_regs.items) |a| try padded.append(a);
                    while (padded.items.len < expected_arity) {
                        const nil_reg = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = inttoptr i64 0 to ptr\n", .{nil_reg});
                        try padded.append(try self.allocator.dupe(u8, nil_reg));
                    }
                    try self.getWriter().print("  {s} = call ptr @{s}(", .{ reg, mangled });
                    for (padded.items, 0..) |arg_reg, idx| {
                        try self.getWriter().print("ptr {s}", .{arg_reg});
                        if (idx < padded.items.len - 1) try self.getWriter().print(", ", .{});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }

                const is_builtin = self.builtin_thunks.contains(callee);
                if (!is_builtin and self.execLookup(callee) != null) {
                    const stack_ptr = self.execLookup(callee).?;
                    const callable_load = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ callable_load, stack_ptr });
                    try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_callable(ptr {s}, i32 {d}", .{ reg, callable_load, arg_regs.items.len });
                    for (arg_regs.items) |arg_reg| {
                        try self.getWriter().print(", ptr {s}", .{arg_reg});
                    }
                    try self.getWriter().print(")\n", .{});
                } else {
                    const func_name = try std.fmt.allocPrint(self.allocator, "bob_{s}", .{callee});
                    defer self.allocator.free(func_name);
                    try self.getWriter().print("  {s} = call ptr @{s}(", .{ reg, func_name });
                    for (arg_regs.items, 0..) |arg_reg, idx| {
                        try self.getWriter().print("ptr {s}", .{arg_reg});
                        if (idx < arg_regs.items.len - 1) try self.getWriter().print(", ", .{});
                    }
                    try self.getWriter().print(")\n", .{});
                }
                return reg;
            },
            .import_stmt => {
                const path = node.extra.?;
                const alias = node.name;

                if (!std.mem.containsAtLeast(u8, path, 1, ".") and !std.mem.containsAtLeast(u8, path, 1, "/")) {
                    return try self.handlePackageImport(path, alias);
                }

                if (std.mem.endsWith(u8, path, ".c")) {
                    const file_contents = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
                    defer self.allocator.free(file_contents);
                    var sigs = try c_parser.pcsign(self.allocator, file_contents);
                    errdefer c_parser.dcfuns(self.allocator, &sigs);

                    {
                        var it = sigs.iterator();
                        while (it.next()) |entry| {
                            const func = entry.value_ptr.*;
                            const ret_llvm = c_parser.ctllvm(func.return_type);
                            try self.llvm.global_buffer.writer().print("declare {s} @{s}(", .{ ret_llvm, func.name });
                            for (func.params, 0..) |param, idx| {
                                const param_llvm = c_parser.ctllvm(param.param_type);
                                try self.llvm.global_buffer.writer().print("{s}", .{param_llvm});
                                if (idx < func.params.len - 1) try self.llvm.global_buffer.writer().print(", ", .{});
                            }
                            try self.llvm.global_buffer.writer().print(")\n", .{});
                        }
                    }

                    try self.c_modules.put(try self.allocator.dupe(u8, alias), sigs);
                    const abs_path = std.fs.realpathAlloc(self.allocator, path) catch path;
                    try self.c_source_files.append(abs_path);
                    return "";
                }

                if (std.mem.endsWith(u8, path, ".go")) {
                    const file_contents = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch {
                        progress.clear();
                        std.debug.print("error: could not read Go file '{s}'\n", .{path});
                        return "";
                    };
                    defer self.allocator.free(file_contents);

                    var go_funcs = go_parser.parseGoExports(self.allocator, file_contents) catch {
                        progress.clear();
                        std.debug.print("error: could not parse Go exports in '{s}'\n", .{path});
                        return "";
                    };
                    defer go_parser.deinitGoFunctions(self.allocator, &go_funcs);

                    const go_dir = try std.fmt.allocPrint(self.allocator, ".boblang/go_mod/{s}", .{alias});
                    defer self.allocator.free(go_dir);
                    try std.fs.cwd().makePath(go_dir);

                    const go_src_path = try std.fmt.allocPrint(self.allocator, "{s}/bridge.go", .{go_dir});
                    defer self.allocator.free(go_src_path);
                    {
                        var f = try std.fs.cwd().createFile(go_src_path, .{});
                        defer f.close();
                        try f.writer().writeAll(file_contents);
                        try f.writer().writeAll("\nfunc main() {}\n");
                    }

                    const go_mod_path = try std.fmt.allocPrint(self.allocator, "{s}/go.mod", .{go_dir});
                    defer self.allocator.free(go_mod_path);

                    const go_src_dir = std.fs.path.dirname(path) orelse ".";
                    const src_go_mod = try std.fmt.allocPrint(self.allocator, "{s}/go.mod", .{go_src_dir});
                    defer self.allocator.free(src_go_mod);
                    const mod_file = std.fs.cwd().readFileAlloc(self.allocator, src_go_mod, 1024);
                    if (mod_file) |mod_content| {
                        defer self.allocator.free(mod_content);
                        var f = try std.fs.cwd().createFile(go_mod_path, .{});
                        defer f.close();
                        try f.writer().writeAll(mod_content);
                        const sum_src = try std.fmt.allocPrint(self.allocator, "{s}/go.sum", .{go_src_dir});
                        defer self.allocator.free(sum_src);
                        if (std.fs.cwd().readFileAlloc(self.allocator, sum_src, 1024 * 1024)) |sum_content| {
                            defer self.allocator.free(sum_content);
                            const sum_dst = try std.fmt.allocPrint(self.allocator, "{s}/go.sum", .{go_dir});
                            defer self.allocator.free(sum_dst);
                            var sf = try std.fs.cwd().createFile(sum_dst, .{});
                            defer sf.close();
                            try sf.writer().writeAll(sum_content);
                        } else |_| {}
                    } else |_| {
                        var f = try std.fs.cwd().createFile(go_mod_path, .{});
                        defer f.close();
                        try f.writer().print("module boblang_go_mod_{s}\n\ngo 1.21\n", .{alias});
                    }

                    const original_cwd = try std.fs.realpathAlloc(self.allocator, ".");
                    defer self.allocator.free(original_cwd);
                    const output_a = try std.fmt.allocPrint(self.allocator, "{s}/.boblang/go_mod/{s}/libboblang_go_{s}.a", .{ original_cwd, alias, alias });
                    defer self.allocator.free(output_a);

                    var go_args = std.ArrayList([]const u8).init(self.allocator);
                    defer go_args.deinit();
                    try go_args.append("go");
                    try go_args.append("build");
                    try go_args.append("-buildmode=c-archive");
                    try go_args.append("-o");
                    try go_args.append(output_a);
                    try go_args.append(".");

                    var go_child = std.process.Child.init(go_args.items, self.allocator);
                    go_child.stdout_behavior = .Inherit;
                    go_child.stderr_behavior = .Inherit;
                    go_child.cwd = go_dir;

                    const go_term = go_child.spawnAndWait() catch |err| {
                        progress.clear();
                        std.debug.print("error: failed to run go build for '{s}': {s}\n  -> make sure Go is installed\n", .{ path, @errorName(err) });
                        return "";
                    };

                    if (go_term != .Exited or go_term.Exited != 0) {
                        progress.clear();
                        std.debug.print("error: go build failed for '{s}'\n", .{path});
                        return "";
                    }

                    var bridge_sigs = std.StringHashMap(c_parser.CFunction).init(self.allocator);
                    for (go_funcs.items) |gf| {
                        var params = std.ArrayList(c_parser.CParam).init(self.allocator);
                        for (0..gf.param_count) |_| {
                            try params.append(.{ .param_type = .boblang_ptr, .name = "" });
                        }
                        const cfn = c_parser.CFunction{
                            .return_type = .boblang_ptr,
                            .name = try self.allocator.dupe(u8, gf.name),
                            .params = try params.toOwnedSlice(),
                        };
                        try bridge_sigs.put(try self.allocator.dupe(u8, gf.name), cfn);
                    }

                    {
                        var declared = std.StringHashMap(void).init(self.allocator);
                        defer declared.deinit();
                        var bit = bridge_sigs.iterator();
                        while (bit.next()) |bentry| {
                            const bfn = bentry.value_ptr.*;
                            if (declared.contains(bfn.name)) continue;
                            try declared.put(bfn.name, {});
                            try self.llvm.global_buffer.writer().print("declare ptr @{s}(...)\n", .{bfn.name});
                        }
                    }

                    try self.c_modules.put(try self.allocator.dupe(u8, alias), bridge_sigs);
                    try self.go_object_files.append(try self.allocator.dupe(u8, output_a));
                    return "";
                }

                const file_path_owned = !std.mem.endsWith(u8, path, ".bob");
                const file_path = if (file_path_owned) blk: {
                    var file_path_buf = std.ArrayList(u8).init(self.allocator);
                    defer file_path_buf.deinit();
                    for (path) |c| {
                        if (c == '.') try file_path_buf.append('/') else try file_path_buf.append(c);
                    }
                    try file_path_buf.appendSlice(".bob");
                    break :blk try file_path_buf.toOwnedSlice();
                } else path;
                defer if (file_path_owned) self.allocator.free(file_path);

                const gop = self.importing_files.getOrPut(file_path) catch {
                    progress.clear();
                    std.debug.print("Error: Could not read module '{s}'\n", .{file_path});
                    return "";
                };
                if (gop.found_existing) {
                    progress.clear();
                    std.debug.print("Error: Circular import detected for module '{s}'\n", .{file_path});
                    return "";
                }
                defer _ = self.importing_files.remove(file_path);

                const source = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch {
                    progress.clear();
                    std.debug.print("Error: Could not read module '{s}'\n", .{file_path});
                    return "";
                };
                defer self.allocator.free(source);

                const cleaned = std.mem.trim(u8, source, " \n\r\t");
                if (cleaned.len == 0) return "";

                const saved_file = self.current_file;
                self.current_file = file_path;
                errors.setCurrentFile(file_path);
                defer {
                    self.current_file = saved_file;
                    errors.setCurrentFile(saved_file);
                }

                const ast = try parser.ptoast(self.allocator, cleaned);
                defer parser.frtree(self.allocator, ast);

                var exports = std.StringHashMap([]const u8).init(self.allocator);
                errdefer {
                    var ex_it = exports.iterator();
                    while (ex_it.next()) |ex| {
                        self.allocator.free(ex.key_ptr.*);
                        self.allocator.free(ex.value_ptr.*);
                    }
                    exports.deinit();
                }

                for (ast.items) |top_node| {
                    if (top_node.node_type == .func_def) {
                        var mangled = std.ArrayList(u8).init(self.allocator);
                        defer mangled.deinit();
                        try std.fmt.format(mangled.writer(), "bob_mod_{s}_{s}", .{ alias, try self.junkName(top_node.name) });
                        const mangled_str = try mangled.toOwnedSlice();
                        try exports.put(
                            try self.allocator.dupe(u8, top_node.name),
                            mangled_str,
                        );
                    } else if (top_node.node_type == .class_def) {
                        const gname = try std.fmt.allocPrint(self.allocator, "@bob_mod_{s}_{s}", .{ alias, try self.junkName(top_node.name) });
                        try exports.put(
                            try self.allocator.dupe(u8, top_node.name),
                            gname,
                        );
                    }
                }

                try self.bob_modules.put(try self.allocator.dupe(u8, alias), .{ .exports = exports, .arities = std.StringHashMap(ModuleArity).init(self.allocator) });

                const old_prefix = self.current_module_prefix;
                self.current_module_prefix = alias;
                defer self.current_module_prefix = old_prefix;

                for (ast.items) |top_node| {
                    _ = try self.walkAstAndEmit(top_node);
                }

                return "";
            },
            .export_stmt => {
                const source_name = node.extra orelse "";
                const func_name = node.name;
                const export_alias = node.val_string;

                if (self.current_module_prefix) |prefix| {
                    if (self.bob_modules.getPtr(prefix)) |mod| {
                        if (source_name.len > 0) {
                            if (self.c_modules.get(source_name)) |c_mod| {
                                if (c_mod.get(func_name)) |_| {
                                    try mod.exports.put(
                                        try self.allocator.dupe(u8, export_alias),
                                        try self.allocator.dupe(u8, func_name),
                                    );
                                }
                            }
                            if (self.bob_modules.get(source_name)) |bob_mod| {
                                if (bob_mod.exports.get(func_name)) |mangled| {
                                    try mod.exports.put(
                                        try self.allocator.dupe(u8, export_alias),
                                        try self.allocator.dupe(u8, mangled),
                                    );
                                }
                            }
                        } else {
                            if (self.known_funcs.get(func_name)) |mangled| {
                                try mod.exports.put(
                                    try self.allocator.dupe(u8, export_alias),
                                    try self.allocator.dupe(u8, mangled),
                                );
                            }
                        }
                    }
                }
                return "";
            },
            .try_stmt => {
                const label_id = self.llvm.reg_count;
                const try_body = try std.fmt.allocPrint(self.allocator, "try_body_{d}", .{label_id});
                defer self.allocator.free(try_body);
                const try_end = try std.fmt.allocPrint(self.allocator, "try_end_{d}", .{label_id});
                defer self.allocator.free(try_end);
                const err_chk = try self.llvm.nextRegister();

                try self.getWriter().print("  store i32 1, ptr @boblang_error_protect\n", .{});
                try self.getWriter().print("  store i32 0, ptr @boblang_error_occurred\n", .{});
                try self.getWriter().print("  br label %{s}\n", .{try_body});
                try self.getWriter().print("\n{s}:\n", .{try_body});

                try self.pushScope();
                if (node.subtree) |sub| {
                    for (sub.items) |child| _ = try self.emitStmt(child);
                }
                self.popScope();

                try self.getWriter().print("  {s} = load volatile i32, ptr @boblang_error_occurred\n", .{err_chk});

                if (node.except_tree) |_| {
                    const skip_except = try std.fmt.allocPrint(self.allocator, "skip_except_{d}", .{label_id});
                    defer self.allocator.free(skip_except);
                    const except_lbl = try std.fmt.allocPrint(self.allocator, "try_except_{d}", .{label_id});
                    defer self.allocator.free(except_lbl);
                    const no_err = try self.llvm.nextRegister();

                    try self.getWriter().print("  {s} = icmp eq i32 {s}, 0\n", .{ no_err, err_chk });
                    try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ no_err, skip_except, except_lbl });
                    try self.getWriter().print("\n{s}:\n", .{except_lbl});
                    try self.pushScope();
                    if (node.name.len > 0) {
                        const stack_ptr = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{stack_ptr});
                        try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{stack_ptr});
                        const err_obj = try self.llvm.nextRegister();
                        try self.getWriter().print("  {s} = call ptr @boblang_error_object()\n", .{err_obj});
                        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ err_obj, stack_ptr });
                        try self.execAssign(node.name, stack_ptr);
                    }
                    if (node.except_tree) |except_tree| {
                        for (except_tree.items) |child| _ = try self.emitStmt(child);
                    }
                    self.popScope();
                    try self.getWriter().print("  store i32 0, ptr @boblang_error_occurred\n", .{});
                    try self.getWriter().print("  br label %{s}\n", .{skip_except});
                    try self.getWriter().print("\n{s}:\n", .{skip_except});
                } else {
                    try self.getWriter().print("  br label %{s}\n", .{try_end});
                }

                try self.getWriter().print("  store i32 0, ptr @boblang_error_protect\n", .{});
                try self.getWriter().print("  br label %{s}\n", .{try_end});
                try self.getWriter().print("\n{s}:\n", .{try_end});
                return "";
            },
            else => return "",
        }
    }

    fn emitCCall(self: *Builder, module_name: []const u8, func_name: []const u8, arg_regs: *std.ArrayList([]const u8)) ![]const u8 {
        const mod_entry = self.c_modules.get(module_name) orelse {
            progress.clear();
            std.debug.print("[*] Error: Module '{s}' not imported\n", .{module_name});
            return try self.emitZero();
        };
        const func = mod_entry.get(func_name) orelse {
            progress.clear();
            std.debug.print("[*] Error: Function '{s}' not found in module '{s}'\n", .{ func_name, module_name });
            return try self.emitZero();
        };

        if (func.params.len != arg_regs.items.len) {
            progress.clear();
            std.debug.print("[*] Error: Argument count mismatch for {s}.{s}: expected {d}, got {d}\n", .{ module_name, func_name, func.params.len, arg_regs.items.len });
            return try self.emitZero();
        }

        var c_arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (c_arg_regs.items) |item| self.allocator.free(item);
            c_arg_regs.deinit();
        }

        for (func.params, 0..) |param, idx| {
            const bob_reg = arg_regs.items[idx];
            const temp_reg = try self.llvm.nextRegister();
            const unbox_reg = try self.llvm.nextRegister();

            switch (param.param_type) {
                .int => {
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unbox_reg, bob_reg });
                    try self.getWriter().print("  {s} = trunc i64 {s} to i32\n", .{ temp_reg, unbox_reg });
                },
                .long, .long_long => {
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ temp_reg, bob_reg });
                },
                .double => {
                    try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ temp_reg, bob_reg });
                },
                .float => {
                    try self.getWriter().print("  {s} = call double @boblang_unbox_float(ptr {s})\n", .{ unbox_reg, bob_reg });
                    try self.getWriter().print("  {s} = fptrunc double {s} to float\n", .{ temp_reg, unbox_reg });
                },
                .char => {
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unbox_reg, bob_reg });
                    try self.getWriter().print("  {s} = trunc i64 {s} to i8\n", .{ temp_reg, unbox_reg });
                },
                .short => {
                    try self.getWriter().print("  {s} = call i64 @boblang_unbox_int(ptr {s})\n", .{ unbox_reg, bob_reg });
                    try self.getWriter().print("  {s} = trunc i64 {s} to i16\n", .{ temp_reg, unbox_reg });
                },
                .void, .unknown, .boblang_ptr => {
                    try c_arg_regs.append(try self.allocator.dupe(u8, bob_reg));
                    continue;
                },
            }
            try c_arg_regs.append(try self.allocator.dupe(u8, temp_reg));
        }

        const ret_llvm = c_parser.ctllvm(func.return_type);

        if (func.return_type == .void) {
            try self.getWriter().print("  call void @{s}(", .{func.name});
            for (c_arg_regs.items, 0..) |c_reg, idx| {
                const param_type = func.params[idx].param_type;
                const param_llvm = c_parser.ctllvm(param_type);
                if (idx > 0) try self.getWriter().print(", ", .{});
                try self.getWriter().print("{s} {s}", .{ param_llvm, c_reg });
            }
            try self.getWriter().print(")\n", .{});
            return try self.emitZero();
        }

        const call_reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call {s} @{s}(", .{ call_reg, ret_llvm, func.name });
        for (c_arg_regs.items, 0..) |c_reg, idx| {
            const param_type = func.params[idx].param_type;
            const param_llvm = c_parser.ctllvm(param_type);
            if (idx > 0) try self.getWriter().print(", ", .{});
            try self.getWriter().print("{s} {s}", .{ param_llvm, c_reg });
        }
        try self.getWriter().print(")\n", .{});

        const result_reg = try self.llvm.nextRegister();
        switch (func.return_type) {
            .int => {
                const ext_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = sext i32 {s} to i64\n", .{ ext_reg, call_reg });
                try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 {s})\n", .{ result_reg, ext_reg });
            },
            .long, .long_long => {
                try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 {s})\n", .{ result_reg, call_reg });
            },
            .double => {
                const fbits = try self.llvm.nextRegister();
                const fclear = try self.llvm.nextRegister();
                const ftag = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = bitcast double {s} to i64\n", .{ fbits, call_reg });
                try self.getWriter().print("  {s} = and i64 {s}, -8\n", .{ fclear, fbits });
                try self.getWriter().print("  {s} = or i64 {s}, 4\n", .{ ftag, fclear });
                try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ result_reg, ftag });
            },
            .float => {
                const ext_reg = try self.llvm.nextRegister();
                const fbits = try self.llvm.nextRegister();
                const fclear = try self.llvm.nextRegister();
                const ftag = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = fpext float {s} to double\n", .{ ext_reg, call_reg });
                try self.getWriter().print("  {s} = bitcast double {s} to i64\n", .{ fbits, ext_reg });
                try self.getWriter().print("  {s} = and i64 {s}, -8\n", .{ fclear, fbits });
                try self.getWriter().print("  {s} = or i64 {s}, 4\n", .{ ftag, fclear });
                try self.getWriter().print("  {s} = inttoptr i64 {s} to ptr\n", .{ result_reg, ftag });
            },
            .char => {
                const ext_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = sext i8 {s} to i64\n", .{ ext_reg, call_reg });
                try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 {s})\n", .{ result_reg, ext_reg });
            },
            .short => {
                const ext_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = sext i16 {s} to i64\n", .{ ext_reg, call_reg });
                try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 {s})\n", .{ result_reg, ext_reg });
            },
            .boblang_ptr => {
                return call_reg;
            },
            else => {
                try self.getWriter().print("  {s} = call ptr @boblang_int_new(i64 0)\n", .{result_reg});
            },
        }

        return result_reg;
    }

    fn checkModuleArity(self: *Builder, mod: *const BobModule, module_name: []const u8, func_name: []const u8, arg_count: usize, line: usize) !void {
        if (mod.arities.get(func_name)) |arity| {
            if (arg_count < arity.required) {
                const msg = try std.fmt.allocPrint(self.allocator, "function '{s}.{s}' expects at least {d} argument{s}, got {d}", .{ module_name, func_name, arity.required, if (arity.required == 1) "" else "s", arg_count });
                defer self.allocator.free(msg);
                errors.printSemanticError(line, msg);
                std.process.exit(1);
            }
            if (arg_count > arity.declared) {
                const msg = try std.fmt.allocPrint(self.allocator, "function '{s}.{s}' takes at most {d} argument{s}, got {d}", .{ module_name, func_name, arity.declared, if (arity.declared == 1) "" else "s", arg_count });
                defer self.allocator.free(msg);
                errors.printSemanticError(line, msg);
                std.process.exit(1);
            }
        }
    }

    fn emitBobCall(self: *Builder, module_name: []const u8, func_name: []const u8, arg_regs: *std.ArrayList([]const u8), line: usize) ![]const u8 {
        const mod = self.bob_modules.get(module_name) orelse {
            progress.clear();
            std.debug.print("[*] Erro: Module '{s}' not imported\n", .{module_name});
            return try self.emitZero();
        };
        const mangled = mod.exports.get(func_name) orelse {
            progress.clear();
            std.debug.print("[*] Error: Function '{s}' not fouund in module '{s}'\n", .{ func_name, module_name });
            {
                progress.clear();
                std.debug.print("  available exports:\n", .{});
                var ex_it = mod.exports.iterator();
                while (ex_it.next()) |ex| {
                    progress.clear();
                    std.debug.print("    '{s}' -> '{s}'\n", .{ ex.key_ptr.*, ex.value_ptr.* });
                }
            }
            return try self.emitZero();
        };
        try self.checkModuleArity(&mod, module_name, func_name, arg_regs.items.len, line);
        if (mangled.len > 0 and mangled[0] == '@') {
            const callable_reg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ callable_reg, mangled });
            const reg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_callable(ptr {s}, i32 {d}", .{ reg, callable_reg, arg_regs.items.len });
            for (arg_regs.items) |arg_reg| {
                try self.getWriter().print(", ptr {s}", .{arg_reg});
            }
            try self.getWriter().print(")\n", .{});
            return reg;
        }
        const reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @{s}(", .{ reg, mangled });
        for (arg_regs.items, 0..) |arg_reg, idx| {
            try self.getWriter().print("ptr {s}", .{arg_reg});
            if (idx < arg_regs.items.len - 1) try self.getWriter().print(", ", .{});
        }
        try self.getWriter().print(")\n", .{});
        return reg;
    }

    fn resolveModuleCallFromTarget(self: *Builder, target: *AstNode, callee: []const u8, arg_regs: *std.ArrayList([]const u8), line: usize) !?[]const u8 {
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parts.append(callee);
        var current = target;
        while (true) {
            if (current.node_type != .var_ref) return null;
            try parts.append(current.name);
            if (current.target) |t| {
                current = t;
            } else {
                break;
            }
        }
        var i: usize = parts.items.len;
        var full_path = std.ArrayList(u8).init(self.allocator);
        defer full_path.deinit();
        while (i > 0) {
            i -= 1;
            if (i < parts.items.len - 1) try full_path.append('.');
            try full_path.appendSlice(parts.items[i]);
        }
        const dot_idx = std.mem.indexOfScalar(u8, full_path.items, '.') orelse {
            return null;
        };
        const mod_name = full_path.items[0..dot_idx];
        const func_path = full_path.items[dot_idx + 1 ..];
        if (self.bob_modules.get(mod_name)) |mod_entry| {
            if (mod_entry.exports.get(func_path)) |mangled_or_raw| {
                if (std.mem.startsWith(u8, mangled_or_raw, "@")) {
                    const callable_reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ callable_reg, mangled_or_raw });
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_callable(ptr {s}, i32 {d}", .{ reg, callable_reg, arg_regs.items.len });
                    for (arg_regs.items) |arg_reg| {
                        try self.getWriter().print(", ptr {s}", .{arg_reg});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }
                if (std.mem.startsWith(u8, mangled_or_raw, "bob_")) {
                    try self.checkModuleArity(&mod_entry, mod_name, func_path, arg_regs.items.len, line);
                    const reg = try self.llvm.nextRegister();
                    try self.getWriter().print("  {s} = call ptr @{s}(", .{ reg, mangled_or_raw });
                    for (arg_regs.items, 0..) |arg_reg, idx| {
                        try self.getWriter().print("ptr {s}", .{arg_reg});
                        if (idx < arg_regs.items.len - 1) try self.getWriter().print(", ", .{});
                    }
                    try self.getWriter().print(")\n", .{});
                    return reg;
                }
                {
                    var cmod_it = self.c_modules.iterator();
                    while (cmod_it.next()) |cmod_entry| {
                        if (cmod_entry.value_ptr.contains(mangled_or_raw)) {
                            return try self.emitCCall(cmod_entry.key_ptr.*, mangled_or_raw, arg_regs);
                        }
                    }
                }
            }
        }

        if (self.c_modules.get(mod_name)) |c_mod| {
            if (c_mod.contains(func_path)) {
                return try self.emitCCall(mod_name, func_path, arg_regs);
            }
        }

        return null;
    }

    fn emitStmt(self: *Builder, node: *AstNode) !void {
        _ = try self.walkAstAndEmit(node);
    }

    fn isBorrowedNode(node: *AstNode) bool {
        return node.node_type == .var_ref or
            node.node_type == .comment;
    }

    fn compileBobModule(self: *Builder, file_path: []const u8, alias: []const u8) !void {
        const gop = self.importing_files.getOrPut(file_path) catch {
            progress.clear();
            std.debug.print("Error: Could not read module '{s}'\n", .{file_path});
            return;
        };
        if (gop.found_existing) {
            progress.clear();
            std.debug.print("Error: Circular import detected for module '{s}'\n", .{file_path});
            return;
        }
        defer _ = self.importing_files.remove(file_path);

        const source = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch {
            progress.clear();
            std.debug.print("Error: Could not read module '{s}'\n", .{file_path});
            return;
        };
        defer self.allocator.free(source);

        const cleaned = std.mem.trim(u8, source, " \n\r\t");
        if (cleaned.len == 0) return;

        const saved_file = self.current_file;
        self.current_file = file_path;
        errors.setCurrentFile(file_path);
        defer {
            self.current_file = saved_file;
            errors.setCurrentFile(saved_file);
        }

        const ast = parser.ptoast(self.allocator, cleaned) catch {
            progress.clear();
            std.debug.print("Error: Could not parse module '{s}'\n", .{file_path});
            return;
        };
        defer parser.frtree(self.allocator, ast);

        if (self.bob_modules.getPtr(alias) == null) {
            const exports = std.StringHashMap([]const u8).init(self.allocator);
            try self.bob_modules.put(try self.allocator.dupe(u8, alias), .{ .exports = exports, .arities = std.StringHashMap(ModuleArity).init(self.allocator) });
        }

        for (ast.items) |top_node| {
            if (top_node.node_type == .func_def and !top_node.is_extern) {
                var mangled = std.ArrayList(u8).init(self.allocator);
                defer mangled.deinit();
                try std.fmt.format(mangled.writer(), "bob_mod_{s}_{s}", .{ alias, try self.junkName(top_node.name) });
                const mangled_str = try mangled.toOwnedSlice();
                if (self.bob_modules.getPtr(alias)) |mod| {
                    try mod.exports.put(
                        try self.allocator.dupe(u8, top_node.name),
                        mangled_str,
                    );
                }
            } else if (top_node.node_type == .class_def) {
                const gname = try std.fmt.allocPrint(self.allocator, "@bob_mod_{s}_{s}", .{ alias, try self.junkName(top_node.name) });
                if (self.bob_modules.getPtr(alias)) |mod| {
                    try mod.exports.put(
                        try self.allocator.dupe(u8, top_node.name),
                        gname,
                    );
                }
            }
        }

        const old_prefix = self.current_module_prefix;
        self.current_module_prefix = alias;
        defer self.current_module_prefix = old_prefix;

        for (ast.items) |top_node| {
            _ = try self.walkAstAndEmit(top_node);
        }
    }

    fn emitNull(self: *Builder) ![]const u8 {
        const reg = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = call ptr @boblang_null_new()\n", .{reg});
        return reg;
    }

    fn handlePackageImport(self: *Builder, pkg_name: []const u8, alias: []const u8) ![]const u8 {
        if (self.bob_modules.contains(alias)) return "";

        const pkg_dist_base = blk: {
            const path = std.fs.path.join(self.allocator, &[_][]const u8{
                ".boblang", "packages", pkg_name, "dist",
            }) catch {
                progress.clear();
                std.debug.print("error: package '{s}' not found.\n  -> build it with 'boblang pack {s}' or copy the dist/ folder to .boblang/packages/{s}/\n", .{ pkg_name, pkg_name, pkg_name });
                return "";
            };
            if (std.fs.cwd().access(path, .{})) {
                break :blk path;
            } else |_| {
                self.allocator.free(path);
                progress.clear();
                std.debug.print("error: package '{s}' not found.\n  -> build it with 'boblang pack {s}' or copy the dist/ folder to .boblang/packages/{s}/\n", .{ pkg_name, pkg_name, pkg_name });
                return "";
            }
        };
        defer self.allocator.free(pkg_dist_base);

        {
            const exports = std.StringHashMap([]const u8).init(self.allocator);
            try self.bob_modules.put(try self.allocator.dupe(u8, alias), .{ .exports = exports, .arities = std.StringHashMap(ModuleArity).init(self.allocator) });
        }

        {
            const ll_name = try std.fmt.allocPrint(self.allocator, "{s}/libboblang_package_{s}.ll", .{ pkg_dist_base, pkg_name });
            defer self.allocator.free(ll_name);
            const ll_content = std.fs.cwd().readFileAlloc(self.allocator, ll_name, 1024 * 1024) catch null;
            if (ll_content) |content| {
                try self.package_ll_files.append(content);
            } else {
                var d = std.fs.cwd().openDir(pkg_dist_base, .{ .iterate = true }) catch return "";
                defer d.close();
                var dit = d.iterate();
                while (try dit.next()) |entry| {
                    if (std.mem.endsWith(u8, entry.name, ".ll")) {
                        const fallback = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pkg_dist_base, entry.name });
                        defer self.allocator.free(fallback);
                        const fallback_content = std.fs.cwd().readFileAlloc(self.allocator, fallback, 1024 * 1024) catch null;
                        if (fallback_content) |fc| {
                            try self.package_ll_files.append(fc);
                        }
                        break;
                    }
                }
            }
        }

        {
            const conf_in_dist = try std.fmt.allocPrint(self.allocator, "{s}/boblang.conf", .{pkg_dist_base});
            defer self.allocator.free(conf_in_dist);
            const conf_src = std.fs.cwd().readFileAlloc(self.allocator, conf_in_dist, 1024 * 1024) catch null;
            if (conf_src) |src| {
                defer self.allocator.free(src);
                const parsed = boblang_conf.parseBoblangConf(self.allocator, src) catch null;
                if (parsed) |dc| {
                    var conf = dc;
                    defer conf.deinit(self.allocator);
                    for (conf.files) |f| {
                        if (std.mem.endsWith(u8, f, ".c")) {
                            const abs_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pkg_dist_base, f });
                            try self.c_source_files.append(abs_path);
                        }
                        if (std.mem.endsWith(u8, f, ".go")) {
                            const go_file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pkg_dist_base, f });
                            defer self.allocator.free(go_file_path);

                            const go_contents = std.fs.cwd().readFileAlloc(self.allocator, go_file_path, 1024 * 1024) catch continue;
                            defer self.allocator.free(go_contents);

                            const go_dir = try std.fmt.allocPrint(self.allocator, ".boblang/go_mod/{s}", .{alias});
                            defer self.allocator.free(go_dir);
                            try std.fs.cwd().makePath(go_dir);

                            const go_src_path = try std.fmt.allocPrint(self.allocator, "{s}/bridge.go", .{go_dir});
                            defer self.allocator.free(go_src_path);
                            {
                                var gf = try std.fs.cwd().createFile(go_src_path, .{});
                                defer gf.close();
                                try gf.writer().writeAll(go_contents);
                                try gf.writer().writeAll("\nfunc main() {}\n");
                            }

                            const go_mod_path = try std.fmt.allocPrint(self.allocator, "{s}/go.mod", .{go_dir});
                            defer self.allocator.free(go_mod_path);
                            {
                                const src_mod = try std.fmt.allocPrint(self.allocator, "{s}/go.mod", .{pkg_dist_base});
                                defer self.allocator.free(src_mod);
                                if (std.fs.cwd().readFileAlloc(self.allocator, src_mod, 1024)) |mod_content| {
                                    defer self.allocator.free(mod_content);
                                    var mf = try std.fs.cwd().createFile(go_mod_path, .{});
                                    defer mf.close();
                                    try mf.writer().writeAll(mod_content);
                                    const src_sum = try std.fmt.allocPrint(self.allocator, "{s}/go.sum", .{pkg_dist_base});
                                    defer self.allocator.free(src_sum);
                                    if (std.fs.cwd().readFileAlloc(self.allocator, src_sum, 1024 * 1024)) |sum_content| {
                                        defer self.allocator.free(sum_content);
                                        const dst_sum = try std.fmt.allocPrint(self.allocator, "{s}/go.sum", .{go_dir});
                                        defer self.allocator.free(dst_sum);
                                        var sf = try std.fs.cwd().createFile(dst_sum, .{});
                                        defer sf.close();
                                        try sf.writer().writeAll(sum_content);
                                    } else |_| {}
                                } else |_| {
                                    var mf = try std.fs.cwd().createFile(go_mod_path, .{});
                                    defer mf.close();
                                    try mf.writer().print("module boblang_go_mod_{s}\n\ngo 1.21\n", .{alias});
                                }
                            }

                            const original_cwd = try std.fs.realpathAlloc(self.allocator, ".");
                            defer self.allocator.free(original_cwd);
                            const output_a = try std.fmt.allocPrint(self.allocator, "{s}/.boblang/go_mod/{s}/libboblang_go_{s}.a", .{ original_cwd, alias, alias });
                            defer self.allocator.free(output_a);

                            var go_args = std.ArrayList([]const u8).init(self.allocator);
                            defer go_args.deinit();
                            try go_args.append("go");
                            try go_args.append("build");
                            try go_args.append("-buildmode=c-archive");
                            try go_args.append("-o");
                            try go_args.append(output_a);
                            try go_args.append(".");

                            var go_child = std.process.Child.init(go_args.items, self.allocator);
                            go_child.stdout_behavior = .Inherit;
                            go_child.stderr_behavior = .Inherit;
                            go_child.cwd = go_dir;

                            const go_term = go_child.spawnAndWait() catch |err| {
                                progress.clear();
                                std.debug.print("warning: go build failed for '{s}': {s}\n", .{ f, @errorName(err) });
                                continue;
                            };

                            if (go_term != .Exited or go_term.Exited != 0) {
                                progress.clear();
                                std.debug.print("warning: go build failed for '{s}'\n", .{f});
                                continue;
                            }

                            try self.go_object_files.append(try self.allocator.dupe(u8, output_a));
                        }
                    }
                    for (conf.libs) |l| {
                        try self.link_libs.append(try self.allocator.dupe(u8, l));
                    }
                }
            }
        }

        const manifest_path = bundle.findPackageManifest(self.allocator, pkg_name);
        var bridge_sigs = std.StringHashMap(c_parser.CFunction).init(self.allocator);
        errdefer c_parser.dcfuns(self.allocator, &bridge_sigs);

        if (manifest_path) |mp| {
            defer self.allocator.free(mp);
            const manifest_src = std.fs.cwd().readFileAlloc(self.allocator, mp, 1024 * 1024) catch {
                progress.clear();
                std.debug.print("warning: could not read package manifest for '{s}'\n", .{pkg_name});
                try self.c_modules.put(try self.allocator.dupe(u8, alias), bridge_sigs);
                return "";
            };
            defer self.allocator.free(manifest_src);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, manifest_src, .{}) catch {
                progress.clear();
                std.debug.print("warning: invalid package.json for '{s}'\n", .{pkg_name});
                try self.c_modules.put(try self.allocator.dupe(u8, alias), bridge_sigs);
                return "";
            };
            defer parsed.deinit();

            if (parsed.value.object.get("functions")) |functions_arr| {
                for (functions_arr.array.items) |func_val| {
                    const obj = func_val.object;
                    const fname = obj.get("name").?.string;
                    const params_arr = obj.get("params").?.array;

                    const declared: u32 = @intCast(params_arr.items.len);
                    if (self.bob_modules.getPtr(alias)) |mod| {
                        try mod.arities.put(try self.allocator.dupe(u8, fname), .{ .declared = declared, .required = declared });
                    }

                    var params = std.ArrayList(c_parser.CParam).init(self.allocator);
                    for (params_arr.items) |param_val| {
                        const param_obj = param_val.object;
                        const type_str = if (param_obj.get("type")) |t| t.string else "ptr";
                        const param_type = package_builder.cTypeStringToEnum(type_str);
                        const pname = if (param_obj.get("name")) |n| n.string else "";
                        try params.append(.{ .param_type = param_type, .name = pname });
                    }

                    const return_type_str = if (obj.get("return_type")) |rt| rt.string else "ptr";
                    const return_type = package_builder.cTypeStringToEnum(return_type_str);

                    const cfn = c_parser.CFunction{
                        .return_type = return_type,
                        .name = try self.allocator.dupe(u8, fname),
                        .params = try params.toOwnedSlice(),
                    };
                    try bridge_sigs.put(try self.allocator.dupe(u8, fname), cfn);
                }
            }

            if (parsed.value.object.get("exports")) |exports_arr| {
                if (self.bob_modules.getPtr(alias)) |mod| {
                    for (exports_arr.array.items) |exp_val| {
                        const exp_obj = exp_val.object;
                        const from_source = exp_obj.get("from").?.string;
                        const alias_name = exp_obj.get("as").?.string;

                        var found = false;
                        const dot_idx = std.mem.indexOfScalar(u8, from_source, '.');
                        if (dot_idx) |di| {
                            const source_mod = from_source[0..di];
                            const source_name = from_source[di + 1 ..];
                            if (self.bob_modules.get(source_mod)) |bob_mod| {
                                if (bob_mod.exports.get(source_name)) |mangled| {
                                    try mod.exports.put(
                                        try self.allocator.dupe(u8, alias_name),
                                        try self.allocator.dupe(u8, mangled),
                                    );
                                    found = true;
                                }
                            }
                            if (!found) {
                                if (bridge_sigs.contains(source_name)) {
                                    try mod.exports.put(
                                        try self.allocator.dupe(u8, alias_name),
                                        try self.allocator.dupe(u8, source_name),
                                    );
                                    found = true;
                                }
                            }
                        }

                        if (!found) {
                            const export_target = if (dot_idx) |di| blk: {
                                const source_mod = from_source[0..di];
                                const source_name = from_source[di + 1 ..];
                                break :blk try std.fmt.allocPrint(self.allocator, "bob_mod_{s}_{s}", .{ source_mod, try self.junkName(source_name) });
                            } else if (bridge_sigs.get(from_source)) |cfn| blk: {
                                if (cfn.return_type == .boblang_ptr) {
                                    break :blk try self.allocator.dupe(u8, from_source);
                                }
                                break :blk try self.allocator.dupe(u8, from_source);
                            } else blk: {
                                break :blk try self.allocator.dupe(u8, from_source);
                            };
                            defer self.allocator.free(export_target);

                            try mod.exports.put(
                                try self.allocator.dupe(u8, alias_name),
                                try self.allocator.dupe(u8, export_target),
                            );
                        }
                    }
                }
            } else if (parsed.value.object.get("functions")) |functions_arr| {
                if (self.bob_modules.getPtr(alias)) |mod| {
                    for (functions_arr.array.items) |func_val| {
                        const obj = func_val.object;
                        const fname = obj.get("name").?.string;
                        if (std.mem.eql(u8, fname, "main")) continue;
                        try mod.exports.put(
                            try self.allocator.dupe(u8, fname),
                            try self.allocator.dupe(u8, fname),
                        );
                    }
                }
            }

            {
                var to_remove = std.ArrayList([]const u8).init(self.allocator);
                defer to_remove.deinit();
                var bit = bridge_sigs.iterator();
                while (bit.next()) |bentry| {
                    if (self.bob_modules.getPtr(alias)) |mod| {
                        if (mod.exports.get(bentry.key_ptr.*)) |export_target| {
                            if (std.mem.startsWith(u8, export_target, "bob_mod_")) {
                                try to_remove.append(bentry.key_ptr.*);
                            }
                        }
                    }
                }
                for (to_remove.items) |key| {
                    _ = bridge_sigs.remove(key);
                }
            }

            {
                var declared = std.StringHashMap(void).init(self.allocator);
                defer declared.deinit();
                var bit = bridge_sigs.iterator();
                while (bit.next()) |bentry| {
                    const bfn = bentry.value_ptr.*;
                    if (declared.contains(bfn.name)) continue;
                    if (std.mem.eql(u8, bfn.name, "main")) continue;
                    {
                        var skip = false;
                        var cmod_check = self.c_modules.iterator();
                        while (cmod_check.next()) |cmod_entry| {
                            if (cmod_entry.value_ptr.contains(bfn.name)) {
                                skip = true;
                                break;
                            }
                        }
                        if (skip) continue;
                    }
                    try declared.put(bfn.name, {});
                    const ret_llvm = c_parser.ctllvm(bfn.return_type);
                    try self.llvm.global_buffer.writer().print("declare {s} @{s}(", .{ ret_llvm, bfn.name });
                    for (bfn.params, 0..) |bparam, bidx| {
                        const param_llvm = c_parser.ctllvm(bparam.param_type);
                        try self.llvm.global_buffer.writer().print("{s}", .{param_llvm});
                        if (bidx < bfn.params.len - 1) try self.llvm.global_buffer.writer().print(", ", .{});
                    }
                    try self.llvm.global_buffer.writer().print(")\n", .{});
                }
            }

            if (bridge_sigs.count() > 0) {
                try self.c_modules.put(try self.allocator.dupe(u8, alias), bridge_sigs);
            }
        } else {
            progress.clear();
            std.debug.print("warning: no package.json found for '{s}'\n", .{pkg_name});
        }

        return "";
    }

    fn emitTopLevelObject(self: *Builder, name: []const u8, value_reg: []const u8) ![]const u8 {
        const global_name = try std.fmt.allocPrint(self.allocator, "@bob_global_{s}", .{try self.junkName(name)});
        try self.llvm.global_buffer.writer().print("{s} = global ptr null\n", .{global_name});
        try self.execAssign(name, global_name);
        try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ value_reg, global_name });
        return global_name;
    }

    fn emitRecursionPop(self: *Builder) !void {
        if (!self.current_func_recursion_checked) return;
        const a = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = load i32, ptr @boblang_recursion_depth\n", .{a});
        const b = try self.llvm.nextRegister();
        try self.getWriter().print("  {s} = sub i32 {s}, 1\n", .{ b, a });
        try self.getWriter().print("  store i32 {s}, ptr @boblang_recursion_depth\n", .{b});
    }

    fn collectAssignNames(self: *Builder, node: *AstNode, names: *std.StringHashMap(void), int_names: *std.StringHashMap(void)) !void {
        switch (node.node_type) {
            .func_def, .class_def => return,
            .assign, .aug_assign_add, .aug_assign_mul => {
                if (node.target == null and !std.mem.containsAtLeast(u8, node.name, 1, ".") and !std.mem.containsAtLeast(u8, node.name, 1, "[")) {
                    try names.put(node.name, {});
                }
            },
            .for_loop => {
                var is_range = false;
                if (node.args) |fargs| {
                    if (fargs.items.len > 0) {
                        const iter_node = fargs.items[0];
                        is_range = iter_node.node_type == .call and std.mem.eql(u8, iter_node.name, "range") and iter_node.args != null;
                    }
                }
                if (is_range) {
                    try int_names.put(node.name, {});
                } else {
                    try names.put(node.name, {});
                }
            },
            else => {},
        }
        if (node.subtree) |sub| {
            for (sub.items) |c| try self.collectAssignNames(c, names, int_names);
        }
        if (node.elifs) |elifs| {
            for (elifs.items) |el| try self.collectAssignNames(el, names, int_names);
        }
        if (node.else_tree) |et| {
            for (et.items) |c| try self.collectAssignNames(c, names, int_names);
        }
        if (node.except_tree) |et| {
            for (et.items) |c| try self.collectAssignNames(c, names, int_names);
        }
    }

    fn hoistFunctionLocals(self: *Builder, node: *AstNode) !void {
        var names = std.StringHashMap(void).init(self.allocator);
        defer names.deinit();
        var int_names = std.StringHashMap(void).init(self.allocator);
        defer int_names.deinit();
        if (node.subtree) |sub| {
            for (sub.items) |c| try self.collectAssignNames(c, &names, &int_names);
        }
        var it = names.keyIterator();
        while (it.next()) |k| {
            const name = k.*;
            if (std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "props")) continue;
            var is_arg = false;
            if (node.args) |args| {
                for (args.items) |arg| {
                    if (std.mem.eql(u8, arg.name, name)) {
                        is_arg = true;
                        break;
                    }
                }
            }
            if (is_arg) continue;
            if (self.execLookup(name) != null) continue;
            const slot = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = alloca ptr, align 8\n", .{slot});
            try self.getWriter().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{slot});
            try self.getWriter().print("  store ptr null, ptr {s}, align 8\n", .{slot});
            try self.execAssign(name, slot);
        }
        var iit = int_names.keyIterator();
        while (iit.next()) |k| {
            const name = k.*;
            if (std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "props")) continue;
            var is_arg = false;
            if (node.args) |args| {
                for (args.items) |arg| {
                    if (std.mem.eql(u8, arg.name, name)) {
                        is_arg = true;
                        break;
                    }
                }
            }
            if (is_arg) continue;
            if (self.execLookupInt(name) != null) continue;
            const slot = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = alloca i64, align 8\n", .{slot});
            try self.getWriter().print("  store i64 0, ptr {s}, align 8\n", .{slot});
            try self.execAssignInt(name, slot);
        }
    }

    fn stmtHasSelfTailCall(self: *Builder, node: *AstNode) bool {
        switch (node.node_type) {
            .return_stmt => {
                if (node.args) |args| {
                    if (args.items.len > 0) {
                        const e = args.items[0];
                        if (e.node_type == .call and e.target == null) {
                            if (self.current_func_name) |fname| {
                                if (std.mem.eql(u8, e.name, fname)) return true;
                            }
                        }
                    }
                }
            },
            .if_stmt => {
                if (node.subtree) |sub| {
                    for (sub.items) |c| if (self.stmtHasSelfTailCall(c)) return true;
                }
                if (node.elifs) |elifs| {
                    for (elifs.items) |el| {
                        if (el.subtree) |es| for (es.items) |c| if (self.stmtHasSelfTailCall(c)) return true;
                    }
                }
                if (node.else_tree) |et| {
                    for (et.items) |c| if (self.stmtHasSelfTailCall(c)) return true;
                }
            },
            .while_loop, .for_loop, .try_stmt => {
                if (node.subtree) |sub| {
                    for (sub.items) |c| if (self.stmtHasSelfTailCall(c)) return true;
                }
                if (node.except_tree) |et| {
                    for (et.items) |c| if (self.stmtHasSelfTailCall(c)) return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn hasSelfTailCall(self: *Builder, node: *AstNode) bool {
        if (node.subtree) |sub| {
            for (sub.items) |child| {
                if (self.stmtHasSelfTailCall(child)) return true;
            }
        }
        return false;
    }

    fn emitSelfTailCall(self: *Builder, call_node: *AstNode) !void {
        var arg_regs = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (arg_regs.items) |r| self.allocator.free(r);
            arg_regs.deinit();
        }
        if (call_node.args) |args| {
            for (args.items) |arg| {
                const r = try self.walkAstAndEmit(arg);
                try arg_regs.append(try self.allocator.dupe(u8, r));
            }
        }
        for (arg_regs.items, 0..) |reg, idx| {
            try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ reg, self.current_func_arg_slots.items[idx] });
        }
        if (self.current_func_recursion_checked) {
            const a = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = load i32, ptr @boblang_tail_iterations\n", .{a});
            const b = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = add i32 {s}, 1\n", .{ b, a });
            try self.getWriter().print("  store i32 {s}, ptr @boblang_tail_iterations\n", .{b});
            const lim = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = icmp sgt i32 {s}, {d}\n", .{ lim, b, RECURSION_LIMIT });
            const rid = self.llvm.reg_count;
            const exc_lbl = try std.fmt.allocPrint(self.allocator, "tc_exc_{d}", .{rid});
            defer self.allocator.free(exc_lbl);
            const ok_lbl = try std.fmt.allocPrint(self.allocator, "tc_ok_{d}", .{rid});
            defer self.allocator.free(ok_lbl);
            try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ lim, exc_lbl, ok_lbl });
            try self.getWriter().print("\n{s}:\n", .{exc_lbl});
            const wmsg = try self.llvm.buildGlobalString("warning: max recursion limit exceeded\n");
            const wreg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = call ptr @boblang_str_new(ptr {s})\n", .{ wreg, wmsg });
            try self.getWriter().print("  call void @boblang_print(ptr {s})\n", .{wreg});
            try self.emitRecursionPop();
            const nreg = try self.llvm.nextRegister();
            try self.getWriter().print("  {s} = inttoptr i64 0 to ptr\n", .{nreg});
            try self.getWriter().print("  ret ptr {s}\n", .{nreg});
            try self.getWriter().print("\n{s}:\n", .{ok_lbl});
        }
        try self.getWriter().print("  br label %{s}\n", .{self.current_func_loop_head.?});
    }

    fn applyDecorators(self: *Builder, decorators: std.ArrayList(*AstNode), var_name: []const u8) !void {
        var i: usize = decorators.items.len;
        while (i > 0) {
            i -= 1;
            const decorator_node = decorators.items[i];
            if (decorator_node.node_type == .var_ref and decorator_node.target == null and std.mem.eql(u8, decorator_node.name, "recursive")) continue;
            if (decorator_node.node_type == .var_ref and decorator_node.target != null) {
                const obj_reg = try self.walkAstAndEmit(decorator_node.target.?);
                const method_str_reg = try self.emitPropString(decorator_node.name);
                const val_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ val_reg, var_name });
                const result_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_method(ptr {s}, ptr {s}, i32 1, ptr {s})\n", .{ result_reg, obj_reg, method_str_reg, val_reg });
                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ result_reg, var_name });
            } else if (decorator_node.node_type == .var_ref and std.mem.containsAtLeast(u8, decorator_node.name, 1, ".")) {
                var it = std.mem.splitSequence(u8, decorator_node.name, ".");
                const root_name = it.next().?;
                const prop_name = it.next().?;
                const root_stack = self.execLookup(root_name) orelse {
                    try self.elookuperr(decorator_node.line);
                    return;
                };
                const obj_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ obj_reg, root_stack });
                const method_str_reg = try self.emitPropString(prop_name);
                const val_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ val_reg, var_name });
                const result_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_method(ptr {s}, ptr {s}, i32 1, ptr {s})\n", .{ result_reg, obj_reg, method_str_reg, val_reg });
                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ result_reg, var_name });
            } else {
                const decorator_reg = try self.walkAstAndEmit(decorator_node);
                const dnull = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = icmp eq ptr {s}, null\n", .{ dnull, decorator_reg });
                const lbl_id = self.llvm.reg_count;
                const skip_lbl = try std.fmt.allocPrint(self.allocator, ".dec_skip_{d}", .{lbl_id});
                defer self.allocator.free(skip_lbl);
                const cont_lbl = try std.fmt.allocPrint(self.allocator, ".dec_apply_{d}", .{lbl_id});
                defer self.allocator.free(cont_lbl);
                const end_lbl = try std.fmt.allocPrint(self.allocator, ".dec_end_{d}", .{lbl_id});
                defer self.allocator.free(end_lbl);
                try self.getWriter().print("  br i1 {s}, label %{s}, label %{s}\n", .{ dnull, skip_lbl, cont_lbl });
                try self.getWriter().print("\n{s}:\n", .{skip_lbl});
                try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                try self.getWriter().print("\n{s}:\n", .{cont_lbl});
                const val_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = load ptr, ptr {s}, align 8\n", .{ val_reg, var_name });
                const result_reg = try self.llvm.nextRegister();
                try self.getWriter().print("  {s} = call ptr @boblang_runtime_call_callable(ptr {s}, i32 1, ptr {s})\n", .{ result_reg, decorator_reg, val_reg });
                try self.getWriter().print("  store ptr {s}, ptr {s}, align 8\n", .{ result_reg, var_name });
                try self.getWriter().print("  br label %{s}\n", .{end_lbl});
                try self.getWriter().print("\n{s}:\n", .{end_lbl});
            }
        }
    }

    pub fn finalize(self: *Builder) !void {
        try self.llvm.finalize();
    }
};
