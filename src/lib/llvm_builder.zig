const std = @import("std");

pub const LlvmBuilder = struct {
    allocator: std.mem.Allocator,
    global_buffer: std.ArrayList(u8),
    functions_buffer: std.ArrayList(u8),
    closures_buffer: std.ArrayList(u8),
    code_buffer: std.ArrayList(u8),
    reg_count: u32 = 0,
    reg_names: std.ArrayList([]const u8),
    str_count: u32 = 0,
    str_names: std.ArrayList([]const u8),
    str_prefix: []const u8 = "",
    entry_scratch: []const u8 = "",
    scratch_pool: std.ArrayList([]const u8),
    scratch_index: usize = 0,
    int_slot_pool: std.ArrayList([]const u8),
    int_slot_index: usize = 0,
    float_slot_pool: std.ArrayList([]const u8),
    float_slot_index: usize = 0,
    obfuscate: bool = false,

    pub fn init(allocator: std.mem.Allocator) LlvmBuilder {
        return LlvmBuilder{
            .allocator = allocator,
            .global_buffer = std.ArrayList(u8).init(allocator),
            .functions_buffer = std.ArrayList(u8).init(allocator),
            .closures_buffer = std.ArrayList(u8).init(allocator),
            .code_buffer = std.ArrayList(u8).init(allocator),
            .scratch_pool = std.ArrayList([]const u8).init(allocator),
            .int_slot_pool = std.ArrayList([]const u8).init(allocator),
            .float_slot_pool = std.ArrayList([]const u8).init(allocator),
            .reg_names = std.ArrayList([]const u8).init(allocator),
            .str_names = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *LlvmBuilder) void {
        for (self.reg_names.items) |s| self.allocator.free(s);
        self.reg_names.deinit();
        for (self.str_names.items) |s| self.allocator.free(s);
        self.str_names.deinit();
        self.global_buffer.deinit();
        self.functions_buffer.deinit();
        self.closures_buffer.deinit();
        self.code_buffer.deinit();
        self.scratch_pool.deinit();
        self.int_slot_pool.deinit();
        self.float_slot_pool.deinit();
    }

    pub fn nextRegister(self: *LlvmBuilder) ![]const u8 {
        self.reg_count += 1;
        const idx = self.reg_count;
        if (idx <= self.reg_names.items.len) return self.reg_names.items[idx - 1];
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "%t{d}", .{idx});
        const owned = try self.allocator.dupe(u8, name);
        try self.reg_names.append(owned);
        return owned;
    }

    fn emitRuntimeDecls(_: *LlvmBuilder, w: anytype, comment: []const u8) !void {
        try w.print("target triple = \"x86_64-unknown-linux-gnu\"\n\n", .{});
        try w.print("; {s}\n\n", .{comment});
        const decls = [_][]const u8{
            "declare ptr @boblang_int_new(i64)",
            "declare ptr @boblang_float_new(double)",
            "declare ptr @boblang_bool_new(i32)",
            "declare ptr @boblang_str_new(ptr)",
            "declare ptr @boblang_str_new_x(ptr, i32, i32)",
            "declare ptr @boblang_unbox_str(ptr)",
            "declare ptr @boblang_lister_new()",
            "declare void @boblang_lister_append(ptr, ptr)",
            "declare ptr @boblang_dict_new()",
            "declare void @boblang_dict_set(ptr, ptr, ptr)",
            "declare ptr @badd(ptr, ptr)",
            "declare ptr @bsub(ptr, ptr)",
            "declare ptr @bmul(ptr, ptr)",
            "declare ptr @bdiv(ptr, ptr)",
            "declare ptr @bmod(ptr, ptr)",
            "declare ptr @beq(ptr, ptr)",
            "declare ptr @bneq(ptr, ptr)",
            "declare ptr @blt(ptr, ptr)",
            "declare ptr @bgt(ptr, ptr)",
            "declare ptr @bge(ptr, ptr)",
            "declare ptr @ble(ptr, ptr)",
            "declare i32 @boblang_is_truthy(ptr)",
            "declare i32 @boblang_list_size_raw(ptr)",
            "declare ptr @boblang_list_items(ptr)",
            "declare ptr @boblang_range(ptr, ptr, ptr)",
            "declare ptr @boblang_get_property(ptr, ptr)",
            "declare ptr @boblang_get_length(ptr)",
            "declare ptr @boblang_get_index(ptr, ptr)",
            "declare ptr @boblang_get_index_int_key(ptr, i64)",
            "declare ptr @boblang_slice(ptr, ptr, ptr)",
            "declare void @boblang_set_slice(ptr, ptr, ptr, ptr)",
            "declare ptr @bpow(ptr, ptr)",
            "declare ptr @bidiv(ptr, ptr)",
            "declare ptr @boblang_runtime_call_method(ptr, ptr, i32, ptr)",
            "declare void @boblang_print(ptr)",
            "@current_line = external global i32",
            "@boblang_recursion_depth = external global i32",
            "@boblang_tail_iterations = external global i32",
            "declare void @boblang_assert_type(ptr, ptr, ptr, i32)",
            "declare ptr @boblang_dict_get(ptr, ptr)",
            "declare void @boblang_set_property(ptr, ptr, ptr)",
            "declare void @boblang_set_index(ptr, ptr, ptr)",
            "declare ptr @boblang_class_new(ptr, ptr, ptr)",
            "declare ptr @boblang_instance_new(ptr)",
            "declare ptr @boblang_null_new()",
            "declare ptr @boblang_func_new(ptr, i32, i32, ptr, ptr, ptr, ptr, i32)",
            "declare ptr @boblang_runtime_call_callable(ptr, i32, ...)",
            "declare void @boblang_runtime_error(i32, ptr, i32)",
            "declare void @boblang_raise_error(i32, ptr, i32)",
            "declare ptr @boblang_error_object()",
            "declare ptr @boblang_foreign_new(i32, ptr, ptr)",
            "declare i32 @boblang_foreign_type_id(ptr)",
            "@boblang_cli_argc = external global i32",
            "@boblang_cli_argv = external global ptr",
            "declare void @boblang_set_file(ptr)",
            "declare void @boblang_set_stack_top()",
            "declare void @boblang_gc_frame_begin()",
            "declare void @boblang_gc_frame_end()",
            "declare void @boblang_gc_register_slot(ptr)",
            "declare void @boblang_push_frame(ptr)",
            "declare void @boblang_pop_frame()",
            "declare i32 @boblang_is_null(ptr)",
            "declare ptr @boblang_contains(ptr, ptr)",
            "declare ptr @boblang_js_call(ptr, i32, ...)",
            "declare ptr @boblang_js_alloc(i32)",
            "declare ptr @boblang_str_from_js(ptr, i32)",
            "declare void @boblang_set_index_int_key(ptr, i64, ptr)",
            "declare i32 @boblang_try_list_append(ptr, ptr)",
            "declare ptr @boblang_int_list_new()",
            "declare void @boblang_int_list_append(ptr, i64)",
            "declare i64 @boblang_int_list_get(ptr, i64)",
            "declare void @boblang_int_list_set(ptr, i64, i64)",
            "declare i32 @boblang_int_list_len(ptr)",
            "declare ptr @boblang_float_list_new()",
            "declare void @boblang_float_list_append(ptr, double)",
            "declare double @boblang_float_list_get(ptr, i64)",
            "declare void @boblang_float_list_set(ptr, i64, double)",
            "declare ptr @boblang_bool_list_new()",
            "declare void @boblang_bool_list_append(ptr, i64)",
            "declare i64 @boblang_bool_list_get(ptr, i64)",
            "declare void @boblang_bool_list_set(ptr, i64, i64)",
            "declare ptr @boblang_raw_int_new(i64)",
            "declare ptr @boblang_raw_float_new(i64)",
            "declare ptr @boblang_raw_bool_new(i64)",
            "declare ptr @boblang_i64_list_new()",
            "declare void @boblang_i64_list_grow_append(ptr, i64)",
            "declare ptr @bob_print(ptr)",
            "declare ptr @bob_input(ptr)",
            "declare ptr @bob_int(ptr)",
            "declare ptr @bob_float(ptr)",
            "declare ptr @bob_str(ptr)",
            "declare ptr @bob_bool(ptr)",
            "declare ptr @bob_type(ptr)",
            "declare ptr @bob_len(ptr)",
            "declare ptr @bob_range(ptr, ptr, ptr)",
            "declare ptr @bob_min(ptr, ptr)",
            "declare ptr @bob_max(ptr, ptr)",
            "declare ptr @bob_clamp(ptr, ptr, ptr)",
            "declare ptr @bob_ascii(ptr)",
            "declare ptr @bob_chr(ptr)",
            "declare ptr @bob_get_args()",
            "declare i64 @boblang_unbox_int(ptr)",
            "declare double @boblang_unbox_float(ptr)",
            "declare ptr @boblang_bigf_new(ptr)",
            "declare ptr @boblang_bigi_new(ptr)",
            "declare ptr @boblang_to_bigi(ptr)",
            "declare ptr @boblang_to_bigf(ptr)",
            "declare ptr @boblang_runtime_call_method_va(ptr, ptr, i32, ...)",
            "@STR_CLASS = external global ptr",
            "@STR_BASES = external global ptr",
            "@STR_LENGTH = external global ptr",
            "@STR_NAME = external global ptr",
            "@STR_INIT = external global ptr",
            "@STR_CALL = external global ptr",
            "@STR_SPACE = external global ptr",
            "@STR_NEWLINE = external global ptr",
            "@FUNC_PRINT = external global ptr",
            "@FUNC_INPUT = external global ptr",
            "@FUNC_INT = external global ptr",
            "@FUNC_FLOAT = external global ptr",
            "@FUNC_STR = external global ptr",
            "@FUNC_BOOL = external global ptr",
            "@FUNC_TYPE = external global ptr",
            "@FUNC_LEN = external global ptr",
            "@FUNC_RANGE = external global ptr",
            "@FUNC_MIN = external global ptr",
            "@FUNC_MAX = external global ptr",
            "@FUNC_CLAMP = external global ptr",
            "@FUNC_ASCII = external global ptr",
            "@FUNC_CHR = external global ptr",

            "@FUNC_GET_ARGS = external global ptr",
            "@boblang_error_occurred = external global i32",
            "@boblang_error_protect = external global i32",
        };
        for (decls) |d| try w.print("{s}\n", .{d});
    }

    pub fn emitPackageHeader(self: *LlvmBuilder) !void {
        try self.emitRuntimeDecls(self.global_buffer.writer(), "Package module: runtime declarations");
    }

    pub fn emitHeader(self: *LlvmBuilder, filename: []const u8) !void {
        try self.emitRuntimeDecls(self.global_buffer.writer(), "Runtime declarations");
        const file_addr = if (self.obfuscate) blk: {
            const tok = LlvmBuilder.obfuscatedFileToken(filename);
            break :blk try self.buildGlobalString(tok[0..16]);
        } else try self.buildGlobalString(filename);
        try self.code_buffer.writer().print("define i32 @main(i32 %argc, ptr %argv) {{\nentry:\n", .{});
        try self.code_buffer.writer().print("  store i32 %argc, ptr @boblang_cli_argc\n", .{});
        try self.code_buffer.writer().print("  store ptr %argv, ptr @boblang_cli_argv\n", .{});
        try self.code_buffer.writer().print("  call void @boblang_set_file(ptr {s})\n", .{file_addr});
        try self.code_buffer.writer().print("  call void @boblang_set_stack_top()\n", .{});
        try self.code_buffer.writer().print("  call void @boblang_gc_frame_begin()\n", .{});
        {
            const main_str = try self.buildGlobalString("main");
            try self.code_buffer.writer().print("  call void @boblang_push_frame(ptr {s})\n", .{main_str});
        }
        {
            self.reg_count += 1;
            try self.code_buffer.writer().print("  %t{d} = alloca ptr, align 8\n", .{self.reg_count});
            self.entry_scratch = try std.fmt.allocPrint(self.allocator, "%t{d}", .{self.reg_count});
            try self.reg_names.append(self.entry_scratch);
            try self.code_buffer.writer().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{self.entry_scratch});
            try self.code_buffer.writer().print("  store ptr null, ptr {s}, align 8\n", .{self.entry_scratch});
        }
        for (0..8) |_| {
            self.reg_count += 1;
            try self.code_buffer.writer().print("  %t{d} = alloca ptr, align 8\n", .{self.reg_count});
            const slot = try std.fmt.allocPrint(self.allocator, "%t{d}", .{self.reg_count});
            try self.reg_names.append(slot);
            try self.code_buffer.writer().print("  call void @boblang_gc_register_slot(ptr {s})\n", .{slot});
            try self.code_buffer.writer().print("  store ptr null, ptr {s}, align 8\n", .{slot});
            try self.scratch_pool.append(slot);
        }
        for (0..4) |_| {
            self.reg_count += 1;
            try self.code_buffer.writer().print("  %t{d} = alloca i64, align 8\n", .{self.reg_count});
            const slot = try std.fmt.allocPrint(self.allocator, "%t{d}", .{self.reg_count});
            try self.reg_names.append(slot);
            try self.int_slot_pool.append(slot);
        }
        for (0..4) |_| {
            self.reg_count += 1;
            try self.code_buffer.writer().print("  %t{d} = alloca double, align 8\n", .{self.reg_count});
            const slot = try std.fmt.allocPrint(self.allocator, "%t{d}", .{self.reg_count});
            try self.reg_names.append(slot);
            try self.float_slot_pool.append(slot);
        }
    }

    pub fn saveScratchState(self: *LlvmBuilder) usize {
        const saved = self.scratch_index;
        self.scratch_index = self.scratch_pool.items.len;
        return saved;
    }

    pub fn restoreScratchState(self: *LlvmBuilder, saved: usize) void {
        self.scratch_index = saved;
    }

    pub fn allocScratchPtr(self: *LlvmBuilder, w: anytype) ![]const u8 {
        if (self.scratch_index >= self.scratch_pool.items.len) {
            const slot = try self.nextRegister();
            try w.print("  {s} = alloca ptr, align 8\n", .{slot});
            return slot;
        }
        const slot = self.scratch_pool.items[self.scratch_index];
        self.scratch_index += 1;
        return slot;
    }

    pub fn saveIntSlotState(self: *LlvmBuilder) usize {
        const saved = self.int_slot_index;
        self.int_slot_index = self.int_slot_pool.items.len;
        return saved;
    }

    pub fn restoreIntSlotState(self: *LlvmBuilder, saved: usize) void {
        self.int_slot_index = saved;
    }

    pub fn allocIntSlot(self: *LlvmBuilder, w: anytype) ![]const u8 {
        if (self.int_slot_index >= self.int_slot_pool.items.len) {
            const slot = try self.nextRegister();
            try w.print("  {s} = alloca i64, align 8\n", .{slot});
            return slot;
        }
        const slot = self.int_slot_pool.items[self.int_slot_index];
        self.int_slot_index += 1;
        return slot;
    }

    pub fn saveFloatSlotState(self: *LlvmBuilder) usize {
        const saved = self.float_slot_index;
        self.float_slot_index = self.float_slot_pool.items.len;
        return saved;
    }

    pub fn restoreFloatSlotState(self: *LlvmBuilder, saved: usize) void {
        self.float_slot_index = saved;
    }

    pub fn allocFloatSlot(self: *LlvmBuilder, w: anytype) ![]const u8 {
        if (self.float_slot_index >= self.float_slot_pool.items.len) {
            const slot = try self.nextRegister();
            try w.print("  {s} = alloca double, align 8\n", .{slot});
            return slot;
        }
        const slot = self.float_slot_pool.items[self.float_slot_index];
        self.float_slot_index += 1;
        return slot;
    }

    pub fn buildGlobalString(self: *LlvmBuilder, str: []const u8) ![]const u8 {
        self.str_count += 1;
        const name = try std.fmt.allocPrint(self.allocator, "@.str_{s}{d}", .{ self.str_prefix, self.str_count });
        try self.str_names.append(name);

        try self.global_buffer.writer().print("{s} = private unnamed_addr constant [{d} x i8] c\"", .{ name, str.len + 1 });
        for (str) |c| {
            switch (c) {
                '\n' => try self.global_buffer.writer().print("\\0A", .{}),
                '"' => try self.global_buffer.writer().print("\\22", .{}),
                '\\' => try self.global_buffer.writer().print("\\\\", .{}),
                else => try self.global_buffer.writer().print("{c}", .{c}),
            }
        }
        try self.global_buffer.writer().print("\\00\", align 1\n", .{});
        return name;
    }

    pub fn obfuscatedKey(str: []const u8) u8 {
        var h: u64 = 1469598103934665603;
        for (str) |c| {
            h ^= c;
            h = h *% 1099511628211;
        }
        var k: u8 = @truncate(h);
        if (k == 0) k = 0x5a;
        return k;
    }

    // 16 lowercase hex chars of the FNV-1a hash of a filename basename, used in obfuscated builds instead of the real source path so that evil hackers dont reverse engineer entire project lool
    pub fn obfuscatedFileToken(file: []const u8) [17]u8 {
        const base = std.fs.path.basename(file);
        var h: u64 = 1469598103934665603;
        for (base) |c| {
            h ^= c;
            h = h *% 1099511628211;
        }
        var out: [17]u8 = undefined;
        const digits = "0123456789abcdef";
        for (0..16) |i| {
            const shift: u6 = @intCast(60 - 4 * i);
            out[i] = digits[@as(u4, @intCast((h >> shift) & 0xf))];
        }
        out[16] = 0;
        return out;
    }

    // OBFUSCATION YIPEEEEE
    pub fn buildObfuscatedString(self: *LlvmBuilder, str: []const u8, key: u8) ![]const u8 {
        self.str_count += 1;
        const name = try std.fmt.allocPrint(self.allocator, "@.str_{s}{d}", .{ self.str_prefix, self.str_count });
        try self.str_names.append(name);
        try self.global_buffer.writer().print("{s} = private unnamed_addr constant [{d} x i8] c\"", .{ name, str.len });
        for (str) |c| {
            try self.global_buffer.writer().print("\\{x:0>2}", .{c ^ key});
        }
        try self.global_buffer.writer().print("\", align 1\n", .{});
        return name;
    }

    pub fn finalize(self: *LlvmBuilder) !void {
        try self.code_buffer.writer().print("  call void @boblang_pop_frame()\n", .{});
        try self.code_buffer.writer().print("  call void @boblang_gc_frame_end()\n", .{});
        try self.code_buffer.writer().print("  ret i32 0\n}}\n", .{});
        try self.code_buffer.writer().print("!0 = !{{!1}}\n!1 = !{{!\"raw\", !2}}\n!2 = !{{!\"boblang\"}}\n!3 = !{{}}\n", .{});
    }
};
