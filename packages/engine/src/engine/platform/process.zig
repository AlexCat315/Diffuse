const std = @import("std");
const builtin = @import("builtin");

pub fn residentMemoryBytes() ?usize {
    return switch (builtin.os.tag) {
        .macos => macosResidentMemoryBytes(),
        .linux => linuxResidentMemoryBytes(),
        else => null,
    };
}

fn macosResidentMemoryBytes() ?usize {
    const task_port = std.c.mach_task_self();
    if (task_port == std.c.TASK_NULL) {
        return null;
    }

    var info: std.c.mach_task_basic_info = undefined;
    var info_count: std.c.mach_msg_type_number_t = std.c.MACH_TASK_BASIC_INFO_COUNT;
    const result = std.c.task_info(
        task_port,
        std.c.MACH_TASK_BASIC_INFO,
        @as(std.c.task_info_t, @ptrCast(&info)),
        &info_count,
    );
    if (result != 0) {
        return null;
    }
    return @intCast(info.resident_size);
}

fn linuxResidentMemoryBytes() ?usize {
    const file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return null;
    defer file.close();

    var buffer: [128]u8 = undefined;
    const len = file.readAll(&buffer) catch return null;
    const resident_pages = parseLinuxResidentPages(buffer[0..len]) orelse return null;
    return std.math.mul(usize, resident_pages, std.heap.pageSize()) catch null;
}

fn parseLinuxResidentPages(statm: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, statm, " \r\n\t");
    var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
    _ = tokens.next() orelse return null;
    const resident_pages_text = tokens.next() orelse return null;
    return std.fmt.parseInt(usize, resident_pages_text, 10) catch null;
}

test "parse linux resident pages from statm" {
    try std.testing.expectEqual(@as(?usize, 456), parseLinuxResidentPages("123 456 789\n"));
}
