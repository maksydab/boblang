const std = @import("std");
// just cosmetic stuff so that you get some output when you compile a big programm, couldnt test it on big projects lol
var enabled: bool = false;
var total_steps: u32 = 0;
var file_name: []const u8 = "";

pub fn begin(total: u32, file: []const u8) void {
    enabled = std.posix.isatty(std.posix.STDERR_FILENO);
    total_steps = total;
    file_name = file;
}

pub fn advance(step: u32, phase: []const u8) void {
    if (!enabled) return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\r\x1b[2K[{d}/{d}] {s} - {s}", .{ step, total_steps, file_name, phase }) catch return;
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
}

pub fn clear() void {
    if (!enabled) return;
    _ = std.posix.write(std.posix.STDERR_FILENO, "\r\x1b[2K") catch {};
}
