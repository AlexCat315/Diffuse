const std = @import("std");
const io_globals = @import("io_globals");

const max_entries = 256;
const max_scope_len = 48;
const max_message_len = 384;

/// Optional callback to forward log entries to external systems (e.g., RPC console).
/// Set by the editor RPC server on attach, cleared on detach.
pub var g_console_callback: ?*const fn (level: []const u8, message: []const u8, source: []const u8) void = null;

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

var g_mutex: std.Io.Mutex = std.Io.Mutex.init;
var g_entries: [max_entries]Entry = undefined;
var g_entry_count: usize = 0;
var g_entry_write: usize = 0; // Write head for ring buffer
var g_entry_read: usize = 0; // Read head for ring buffer

var g_log_file: ?std.Io.File = null;
var g_log_file_mutex: std.Io.Mutex = std.Io.Mutex.init;

pub fn initLogFile() !void {
    const io = io_globals.global_io;
    var log_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "logs", .{});
    defer log_dir.close(io);

    const timestamp = std.Io.Timestamp.now(io, .real);
    const ts_secs = timestamp.toSeconds();
    var time_buffer: [64]u8 = undefined;
    const time_str = std.fmt.bufPrint(&time_buffer, "{d}", .{ts_secs}) catch "unknown";

    var filename_buffer: [128]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buffer, "guava_{s}.log", .{time_str}) catch "guava.log";

    g_log_file = try log_dir.createFile(io, filename, .{});

    const header = "=== Guava Engine Log Started ===\n";
    try g_log_file.?.writeStreamingAll(io, header);
}

pub fn deinitLogFile() void {
    const io = io_globals.global_io;
    g_log_file_mutex.lockUncancelable(io);
    defer g_log_file_mutex.unlock(io);

    if (g_log_file) |*file| {
        file.writeStreamingAll(io, "=== Guava Engine Log Ended ===\n") catch {};
        file.sync(io) catch {};
        file.close(io);
        g_log_file = null;
    }
}

fn writeToLogFile(level: std.log.Level, scope: []const u8, message: []const u8) void {
    const io = io_globals.global_io;
    g_log_file_mutex.lockUncancelable(io);
    defer g_log_file_mutex.unlock(io);

    if (g_log_file) |file| {
        const level_str = levelLabel(level);

        // Format into a stack buffer to issue a single write() syscall
        // instead of 7 separate writeAll() calls.
        var buf: [max_scope_len + max_message_len + 16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("[{s}] {s}: {s}\n", .{ level_str, scope, message }) catch {
            // Fallback: single unformatted write
            file.writeStreamingAll(io, message) catch {};
            file.writeStreamingAll(io, "\n") catch {};
            return;
        };
        file.writeStreamingAll(io, w.buffered()) catch {};
    }
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = io_globals.global_io;

    // 对于 GPA 的错误,直接输出到 stderr 以避免格式化问题
    if (comptime std.mem.eql(u8, @tagName(scope), "gpa")) {
        var stderr_buffer: [2048]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
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

    // Forward to RPC console log buffer for editor UI
    if (g_console_callback) |cb| {
        cb(levelLabel(message_level), message_text, scope_text);
    }

    // Write to stderr using a single pre-formatted write() syscall.
    // No flush — the OS pipe buffer (64KB on macOS) auto-flushes on newline
    // or when full.  Removing per-message flush() eliminates ~100-200µs of
    // syscall overhead per log call, which is critical for frame budget.
    {
        var line_buf: [max_scope_len + max_message_len + 16]u8 = undefined;
        var w = std.Io.Writer.fixed(&line_buf);
        w.print("[{s}] {s}: {s}\n", .{ levelLabel(message_level), scope_text, message_text }) catch return;
        std.Io.File.stderr().writeStreamingAll(io, w.buffered()) catch return;
    }
}

pub fn clear() void {
    const io = io_globals.global_io;
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);
    g_entry_count = 0;
    g_entry_write = 0;
    g_entry_read = 0;
}

pub fn snapshot(buffer: []Entry) usize {
    const io = io_globals.global_io;
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);

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
    const io = io_globals.global_io;
    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);

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
