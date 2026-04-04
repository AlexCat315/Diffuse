const std = @import("std");

const max_entries = 256;
const max_scope_len = 48;
const max_message_len = 384;

pub const Entry = struct {
    level: std.log.Level,
    scope_len: usize = 0,
    message_len: usize = 0,
    scope: [max_scope_len]u8 = [_]u8{0} ** max_scope_len,
    message: [max_message_len]u8 = [_]u8{0} ** max_message_len,

    pub fn scopeText(self: *const Entry) []const u8 {
        return self.scope[0..self.scope_len];
    }

    pub fn messageText(self: *const Entry) []const u8 {
        return self.message[0..self.message_len];
    }
};

var g_mutex: std.Thread.Mutex = .{};
var g_entries: [max_entries]Entry = undefined;
var g_entry_count: usize = 0;
var g_entry_write: usize = 0; // Write head for ring buffer
var g_entry_read: usize = 0; // Read head for ring buffer

var g_log_file: ?std.fs.File = null;
var g_log_file_mutex: std.Thread.Mutex = .{};

pub fn initLogFile() !void {
    var log_dir = try std.fs.cwd().makeOpenPath("logs", .{});
    defer log_dir.close();

    const timestamp = std.time.timestamp();
    var time_buffer: [64]u8 = undefined;
    const time_str = std.fmt.bufPrint(&time_buffer, "{d}", .{timestamp}) catch "unknown";

    var filename_buffer: [128]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buffer, "guava_{s}.log", .{time_str}) catch "guava.log";

    g_log_file = try log_dir.createFile(filename, .{});

    const header = "=== Guava Engine Log Started ===\n";
    try g_log_file.?.writeAll(header);
}

pub fn deinitLogFile() void {
    g_log_file_mutex.lock();
    defer g_log_file_mutex.unlock();

    if (g_log_file) |*file| {
        file.writeAll("=== Guava Engine Log Ended ===\n") catch {};
        file.sync() catch {};
        file.close();
        g_log_file = null;
    }
}

fn writeToLogFile(level: std.log.Level, scope: []const u8, message: []const u8) void {
    g_log_file_mutex.lock();
    defer g_log_file_mutex.unlock();

    if (g_log_file) |file| {
        const level_str = levelLabel(level);

        file.writeAll("[") catch {};
        file.writeAll(level_str) catch {};
        file.writeAll("] ") catch {};
        file.writeAll(scope) catch {};
        file.writeAll(": ") catch {};
        file.writeAll(message) catch {};
        file.writeAll("\n") catch {};
    }
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // 对于 GPA 的错误,直接输出到 stderr 以避免格式化问题
    if (comptime std.mem.eql(u8, @tagName(scope), "gpa")) {
        var stderr_buffer: [2048]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        stderr.print("[{s}] {s}: ", .{ levelLabel(message_level), @tagName(scope) }) catch {};
        stderr.print(format, args) catch |err| {
            stderr.writeAll("GPA log formatting failed: ") catch {};
            stderr.print("{}", .{err}) catch {};
        };
        stderr.writeAll("\n") catch {};
        stderr.flush() catch {};
        return;
    }

    var scope_buffer: [max_scope_len]u8 = undefined;
    const scope_text = std.fmt.bufPrint(&scope_buffer, "{s}", .{@tagName(scope)}) catch "default";

    var message_buffer: [max_message_len]u8 = undefined;
    const message_text = std.fmt.bufPrint(&message_buffer, format, args) catch blk: {
        const fallback = "log formatting failed (buffer too small or invalid format)";
        const len = @min(fallback.len, message_buffer.len);
        @memcpy(message_buffer[0..len], fallback[0..len]);
        break :blk message_buffer[0..len];
    };

    appendEntry(message_level, scope_text, message_text);
    writeToLogFile(message_level, scope_text, message_text);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("[{s}] {s}: {s}\n", .{ levelLabel(message_level), scope_text, message_text }) catch {};
    stderr.flush() catch {};
}

pub fn clear() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_entry_count = 0;
    g_entry_write = 0;
    g_entry_read = 0;
}

pub fn snapshot(buffer: []Entry) usize {
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_entry_count == 0) {
        return 0;
    }

    var index: usize = 0;
    var cursor = g_entry_read;
    const end = g_entry_write;

    while (index < buffer.len and cursor != end) : (index += 1) {
        buffer[index] = g_entries[cursor];
        cursor = (cursor + 1) % max_entries;
    }

    return index;
}

pub fn levelLabel(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "ERR",
        .warn => "WRN",
        .info => "INF",
        .debug => "DBG",
    };
}

fn appendEntry(level: std.log.Level, scope: []const u8, message: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    const slot = if (g_entry_count < max_entries) blk: {
        const value = g_entry_count;
        g_entry_count += 1;
        g_entry_write = (g_entry_write + 1) % max_entries;
        break :blk value;
    } else blk: {
        const value = g_entry_write;
        g_entry_write = (g_entry_write + 1) % max_entries;
        if (g_entry_read == g_entry_write) {
            g_entry_read = (g_entry_read + 1) % max_entries;
        }
        break :blk value;
    };

    var entry = Entry{ .level = level };
    entry.scope_len = @min(scope.len, entry.scope.len);
    entry.message_len = @min(message.len, entry.message.len);
    @memcpy(entry.scope[0..entry.scope_len], scope[0..entry.scope_len]);
    @memcpy(entry.message[0..entry.message_len], message[0..entry.message_len]);
    g_entries[slot] = entry;
}
