const std = @import("std");

fn addRuntimeCFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) []const []const u8 {
    if (target.result.abi == .android) {
        const ndk = std.posix.getenv("ANDROID_NDK_ROOT") orelse
            @panic("ANDROID_NDK_ROOT must be set for Android builds");

        const sysroot = b.fmt(
            "{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot",
            .{ndk},
        );

        return b.dupeStrings(&.{
            b.fmt("--sysroot={s}", .{sysroot}),
            "-isystem",
            b.fmt("{s}/usr/include", .{sysroot}),
            "-isystem",
            b.fmt("{s}/usr/include/aarch64-linux-android", .{sysroot}),
            "--target=aarch64-linux-android24",
        });
    }

    return b.dupeStrings(&.{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cflags = addRuntimeCFlags(b, target);
    const copy_runtime = b.addSystemCommand(&.{ "cp", "-r", "runtime", "src/_runtime" });
    const rm_old = b.addSystemCommand(&.{ "rm", "-rf", "src/_runtime" });
    const copy_licenses = b.addSystemCommand(&.{ "sh", "-c", "mkdir -p src/_runtime && cp LICENSE THIRD_PARTY_NOTICES.md src/_runtime/" });

    // configure the main executable
    const exe = b.addExecutable(.{
        .name = "boblang",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.linkSystemLibrary("m"); // required for math functions like 'pow'

    if (target.result.abi == .android) {
        const ndk = std.posix.getenv("ANDROID_NDK_ROOT") orelse "";
        const lib_path = b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24", .{ndk});
        exe.addLibraryPath(.{ .cwd_relative = lib_path });
    }

    exe.addCSourceFile(.{
        .file = b.path("runtime/runtime.c"),
        .flags = cflags,
    });

    exe.addCSourceFile(.{
        .file = b.path("runtime/gc.c"),
        .flags = cflags,
    });

    copy_runtime.step.dependOn(&rm_old.step);
    copy_licenses.step.dependOn(&copy_runtime.step);
    exe.step.dependOn(&copy_runtime.step);
    exe.step.dependOn(&copy_licenses.step);
    b.installArtifact(exe);

    const install_step = b.getInstallStep();

    if (b.findProgram(&.{"zig"}, &.{})) |zig_exe| {
        const zig_root = std.fs.path.dirname(std.fs.realpathAlloc(b.allocator, zig_exe) catch zig_exe) orelse unreachable;

        const zlp: std.Build.LazyPath = .{ .cwd_relative = zig_exe };
        const zif = b.addInstallFileWithDir(zlp, .{ .custom = "lib/boblang/zig" }, "zig");
        install_step.dependOn(&zif.step);

        const copy_lib = b.addSystemCommand(&[_][]const u8{
            "cp", "-r", b.pathJoin(&.{ zig_root, "lib" }), b.getInstallPath(.{ .custom = "lib/boblang/zig" }, ""),
        });
        install_step.dependOn(&copy_lib.step);
    } else |_| {}

    const cleanup = b.addSystemCommand(&.{ "rm", "-rf", "src/_runtime" });
    cleanup.step.dependOn(&exe.step);
    install_step.dependOn(&cleanup.step);

    const builtin = @import("builtin");
    if (target.result.os.tag == builtin.os.tag and
        target.result.cpu.arch == builtin.cpu.arch)
    {
        const gpp = b.addSystemCommand(&[_][]const u8{
            "g++", "-std=c++17", "-O2",
        });
        gpp.addFileArg(b.path("src/daemon.cpp"));
        gpp.addArgs(&[_][]const u8{
            "-Wl,--rpath=$ORIGIN/lib",
            "-Wl,--disable-new-dtags",
            "-lLLVM",
            "-llldELF",
            "-llldCommon",
        });
        const daemon_bin = gpp.addPrefixedOutputFileArg("-o", "boblangd");
        b.getInstallStep().dependOn(&gpp.step);
        const install_daemon = b.addInstallFileWithDir(
            daemon_bin,
            .{ .custom = "bin" },
            "boblangd",
        );
        b.getInstallStep().dependOn(&install_daemon.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const test_runner = b.addExecutable(.{
        .name = "test_runner",
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_runner.linkLibC();
    test_runner.linkSystemLibrary("m");
    if (target.result.abi == .android) {
        const ndk = std.posix.getenv("ANDROID_NDK_ROOT") orelse "";
        const lib_path = b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24", .{ndk});
        test_runner.addLibraryPath(.{ .cwd_relative = lib_path });
    }

    test_runner.addCSourceFile(.{
        .file = b.path("runtime/runtime.c"),
        .flags = cflags,
    });

    test_runner.addCSourceFile(.{
        .file = b.path("runtime/gc.c"),
        .flags = cflags,
    });

    const test_run = b.addRunArtifact(test_runner);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);

    const run_step = b.step("run", "Run the compiler");
    run_step.dependOn(&run_cmd.step);
}
