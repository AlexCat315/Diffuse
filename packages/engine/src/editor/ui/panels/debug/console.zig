const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const sdl = engine.platform.sdl.c;

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

        // 使用简单的 writeAll 而不是 writer
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
        // 格式化失败时的简单回退
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

    // 注意：不要更新 g_entry_read，这样日志会一直保留在缓冲区中
    // 直到被新的日志覆盖（环形缓冲区的特性）
    return index;
}

pub fn drawConsolePanel(state: *EditorState) !void {
    const width = gui.contentRegionAvail()[0];
    const clear_width = if (width >= 520.0) 82.0 else width;
    if (gui.buttonEx(state.text(.clear), clear_width, 0.0)) {
        clear();
    }
    if (width >= 520.0) {
        gui.sameLine();
    }

    const toggle_columns: usize = if (width >= 520.0)
        5
    else if (width >= 320.0)
        2
    else
        1;
    var toggle_index: usize = 0;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = gui.checkbox(state.text(.errors), &state.console_show_errors);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = gui.checkbox(state.text(.warnings), &state.console_show_warnings);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = gui.checkbox(state.text(.info), &state.console_show_info);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = gui.checkbox(state.text(.debug), &state.console_show_debug);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = gui.checkbox(state.text(.auto_scroll), &state.console_auto_scroll);
    gui.separator();

    _ = gui.beginChild("console_messages", 0.0, 0.0, true);
    defer gui.endChild();

    // 直接读取环形缓冲区，而不是使用 snapshot
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_entry_count > 0) {
        var cursor = g_entry_read;
        const end = g_entry_write;
        var displayed_count: usize = 0;

        while (displayed_count < max_entries and cursor != end) {
            const entry = g_entries[cursor];

            if (shouldDisplayEntry(state, entry.level)) {
                gui.pushStyleColor(.text, levelColor(entry.level));
                defer gui.popStyleColor(1);

                var line_buffer: [512]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &line_buffer,
                    "[{s}] {s}: {s}",
                    .{ levelLabel(entry.level), entry.scopeText(), entry.messageText() },
                ) catch continue;

                _ = gui.selectable(line, false, false, 0.0, 0.0);
                var popup_id_buf: [32]u8 = undefined;
                const popup_id = std.fmt.bufPrint(&popup_id_buf, "##console_ctx_{d}", .{displayed_count}) catch continue;
                if (gui.beginPopupContextItem(popup_id)) {
                    if (gui.menuItem(state.text(.copy), null, false, true)) {
                        copyTextToClipboard(line);
                    }
                    gui.endPopup();
                }
                displayed_count += 1;
            }

            cursor = (cursor + 1) % max_entries;
        }
    }

    if (state.console_auto_scroll) {
        gui.setScrollHereY(1.0);
    }
}

fn beginResponsiveToggle(index: usize, columns: usize) void {
    if (index == 0 or columns == 0) {
        return;
    }
    if (index % columns == 0) {
        gui.dummy(0.0, 4.0);
    } else {
        gui.sameLine();
    }
}

fn appendEntry(level: std.log.Level, scope: []const u8, message: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    // 分离的写入逻辑：防止读取时游标移动
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

fn shouldDisplayEntry(state: *const EditorState, level: std.log.Level) bool {
    return switch (level) {
        .err => state.console_show_errors,
        .warn => state.console_show_warnings,
        .info => state.console_show_info,
        .debug => state.console_show_debug,
    };
}

fn levelColor(level: std.log.Level) [4]f32 {
    return switch (level) {
        .err => .{ 0.96, 0.42, 0.37, 1.0 },
        .warn => .{ 0.98, 0.78, 0.36, 1.0 },
        .info => .{ 0.74, 0.84, 0.97, 1.0 },
        .debug => .{ 0.66, 0.70, 0.76, 1.0 },
    };
}

fn levelLabel(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "ERR",
        .warn => "WRN",
        .info => "INF",
        .debug => "DBG",
    };
}

fn copyTextToClipboard(text: []const u8) void {
    var buf: [512 + 1]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    _ = sdl.SDL_SetClipboardText(&buf);
}
