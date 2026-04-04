const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const layout = @import("../../layout.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const ScriptResource = engine.assets.ScriptResource;
const ScriptLanguage = engine.script.ScriptLanguage;

pub const ScriptEditorState = struct {
    allocator: std.mem.Allocator,
    selected_script_handle: ?engine.assets.ScriptHandle = null,
    source_buffer: std.ArrayList(u8),
    original_source: []const u8 = "",
    is_modified: bool = false,
    cursor_line: usize = 1,
    cursor_column: usize = 1,
    selection_start: usize = 0,
    selection_end: usize = 0,
    find_buffer: [256]u8 = [_]u8{0} ** 256,
    replace_buffer: [256]u8 = [_]u8{0} ** 256,
    show_find_panel: bool = false,
    find_cursor: usize = 0,
    show_console: bool = true,
    console_output: std.ArrayList(u8),
    breakpoints: std.ArrayList(usize),
    current_debug_line: ?usize = null,
    is_debugging: bool = false,
    auto_save_enabled: bool = true,
    tab_size: usize = 4,
    show_line_numbers: bool = true,
    word_wrap: bool = false,
    // File path currently open (owned, allocated by self.allocator)
    file_path: ?[]u8 = null,
    // Whether a build is currently running
    is_building: bool = false,

    pub fn init(allocator: std.mem.Allocator) ScriptEditorState {
        return .{
            .allocator = allocator,
            .source_buffer = .empty,
            .console_output = .empty,
            .breakpoints = .empty,
        };
    }

    pub fn deinit(self: *ScriptEditorState) void {
        self.source_buffer.deinit(self.allocator);
        self.console_output.deinit(self.allocator);
        self.breakpoints.deinit(self.allocator);
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
        }
        if (self.file_path) |fp| {
            self.allocator.free(fp);
        }
        self.* = undefined;
    }

    pub fn loadScript(self: *ScriptEditorState, resource: *const ScriptResource) !void {
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
        }
        self.original_source = try self.allocator.dupe(u8, resource.source);
        try self.source_buffer.resize(self.allocator, resource.source.len);
        @memcpy(self.source_buffer.items, resource.source);
        self.is_modified = false;
        self.cursor_line = 1;
        self.cursor_column = 1;
    }

    pub fn loadFromFile(self: *ScriptEditorState, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        const size = stat.size;
        try self.source_buffer.resize(self.allocator, size);
        const read = try file.readAll(self.source_buffer.items);
        try self.source_buffer.resize(self.allocator, read);
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
        }
        self.original_source = try self.allocator.dupe(u8, self.source_buffer.items);
        if (self.file_path) |fp| self.allocator.free(fp);
        self.file_path = try self.allocator.dupe(u8, path);
        self.is_modified = false;
        self.cursor_line = 1;
        self.cursor_column = 1;
        self.breakpoints.clearRetainingCapacity();
    }

    pub fn saveToFile(self: *ScriptEditorState) !void {
        const path = self.file_path orelse return error.NoFilePath;
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(self.source_buffer.items);
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
        }
        self.original_source = try self.allocator.dupe(u8, self.source_buffer.items);
        self.is_modified = false;
    }

    pub fn newFile(self: *ScriptEditorState, path: ?[]const u8, template: []const u8) !void {
        self.source_buffer.clearRetainingCapacity();
        try self.source_buffer.appendSlice(self.allocator, template);
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
            self.original_source = "";
        }
        if (self.file_path) |fp| self.allocator.free(fp);
        self.file_path = if (path) |p| try self.allocator.dupe(u8, p) else null;
        self.is_modified = path != null;
        self.cursor_line = 1;
        self.cursor_column = 1;
        self.breakpoints.clearRetainingCapacity();
    }

    pub fn getSource(self: *const ScriptEditorState) []const u8 {
        return self.source_buffer.items;
    }

    pub fn insertText(self: *ScriptEditorState, pos: usize, text: []const u8) !void {
        try self.source_buffer.insertSlice(self.allocator, pos, text);
        self.is_modified = true;
    }

    pub fn deleteRange(self: *ScriptEditorState, start: usize, end: usize) void {
        if (start >= end or end > self.source_buffer.items.len) return;
        _ = self.source_buffer.orderedRemove(start);
        self.is_modified = true;
    }

    pub fn toggleBreakpoint(self: *ScriptEditorState, line: usize) !void {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp == line) {
                _ = self.breakpoints.orderedRemove(i);
                return;
            }
        }
        try self.breakpoints.append(self.allocator, line);
    }

    pub fn hasBreakpoint(self: *const ScriptEditorState, line: usize) bool {
        for (self.breakpoints.items) |bp| {
            if (bp == line) return true;
        }
        return false;
    }

    pub fn appendConsole(self: *ScriptEditorState, text: []const u8) !void {
        try self.console_output.appendSlice(self.allocator, text);
        try self.console_output.append(self.allocator, '\n');
    }

    pub fn clearConsole(self: *ScriptEditorState) void {
        self.console_output.clearRetainingCapacity();
    }
};

pub fn drawScriptEditorWindow(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *ScriptEditorState,
) !void {
    _ = layer_context;

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .script_editor, "script_editor_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("script_editor_panel");

    drawScriptToolbar(state, editor_state);

    // Keyboard shortcuts (Cmd+S save, Cmd+F find)
    handleKeyboardShortcuts(state, editor_state);

    gui.separator();

    const content_region = gui.contentRegionAvail();
    const editor_height = if (editor_state.show_console) content_region[1] * 0.7 else content_region[1];

    drawScriptSourceArea(editor_state, editor_height);

    if (editor_state.show_console) {
        gui.separator();
        drawConsolePanel(editor_state);
    }
}

fn drawScriptToolbar(state: *EditorState, editor_state: *ScriptEditorState) void {
    // New button with sub-menu for C# / Zig
    if (gui.button(state.text(.new_script))) {
        gui.openPopup("##new_script_popup");
    }
    if (gui.beginPopup("##new_script_popup")) {
        if (gui.selectable(state.text(.new_cs_script), false, false, 0.0, 0.0)) {
            const cs_template = "using System;\n\nnamespace Game\n{\n    public class NewScript\n    {\n        public void Update(float deltaTime)\n        {\n        }\n    }\n}\n";
            editor_state.newFile(null, cs_template) catch {};
        }
        if (gui.selectable(state.text(.new_zig_script), false, false, 0.0, 0.0)) {
            const zig_template = "const std = @import(\"std\");\nconst engine = @import(\"guava\");\n\npub fn update(delta_time: f32) void {\n    _ = delta_time;\n}\n";
            editor_state.newFile(null, zig_template) catch {};
        }
        gui.endPopup();
    }
    gui.sameLine();

    // Open button — use macOS native file picker
    if (gui.button(state.text(.open_script))) {
        openScriptFilePicker(editor_state);
    }
    gui.sameLine();

    // Save button — write to file
    if (gui.button(state.text(.save_script))) {
        if (editor_state.file_path == null) {
            // No file path yet — use Save As dialog
            saveScriptWithPicker(editor_state);
        } else {
            editor_state.saveToFile() catch |err| {
                const msg = std.fmt.allocPrint(editor_state.allocator, "Save failed: {}", .{err}) catch return;
                defer editor_state.allocator.free(msg);
                editor_state.appendConsole(msg) catch {};
            };
        }
    }
    gui.sameLine();

    // Modified indicator
    if (editor_state.is_modified) {
        gui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "*");
        gui.sameLine();
    }

    // File name display
    if (editor_state.file_path) |fp| {
        const name = if (std.mem.lastIndexOfScalar(u8, fp, '/')) |idx| fp[idx + 1 ..] else fp;
        gui.text(name);
    } else {
        gui.text(state.text(.script_untitled));
    }

    gui.sameLine();
    gui.dummy(20.0, 1.0);
    gui.sameLine();

    // Build button (for .cs files with .csproj in same directory)
    if (gui.button(state.text(.build_script))) {
        buildCurrentScript(state, editor_state);
    }

    gui.sameLine();
    gui.dummy(10.0, 1.0);
    gui.sameLine();

    if (gui.button("Find")) {
        editor_state.show_find_panel = !editor_state.show_find_panel;
    }
    gui.sameLine();

    if (gui.button(if (editor_state.show_console) "Hide Console" else "Show Console")) {
        editor_state.show_console = !editor_state.show_console;
    }
    gui.sameLine();

    if (gui.button(if (editor_state.is_debugging) "Stop" else "Debug")) {
        editor_state.is_debugging = !editor_state.is_debugging;
    }
}

fn drawScriptSourceArea(editor_state: *ScriptEditorState, height: f32) void {
    if (editor_state.show_find_panel) {
        drawFindPanel(editor_state);
        gui.separator();
    }

    // Ensure buffer has room for ImGui editing (null-terminated C string)
    const content_len = editor_state.source_buffer.items.len;
    const buffer_size = @max(content_len + 8192, 65536);
    editor_state.source_buffer.resize(editor_state.allocator, buffer_size) catch return;
    // Null-terminate at content boundary for ImGui
    editor_state.source_buffer.items[content_len] = 0;

    const changed = gui.inputTextMultiline("##script_source", editor_state.source_buffer.items, -1.0, height);

    if (changed) {
        // Find null terminator to determine new content length
        const new_len = std.mem.indexOfScalar(u8, editor_state.source_buffer.items, 0) orelse content_len;
        editor_state.source_buffer.items.len = new_len;
        editor_state.is_modified = true;
    } else {
        // Restore original content length
        editor_state.source_buffer.items.len = content_len;
    }
}

fn drawFindPanel(editor_state: *ScriptEditorState) void {
    gui.text("Find:");
    gui.sameLine();
    _ = gui.inputText("##find", &editor_state.find_buffer);
    gui.sameLine();

    gui.text("Replace:");
    gui.sameLine();
    _ = gui.inputText("##replace", &editor_state.replace_buffer);
    gui.sameLine();

    if (gui.button("Find Next")) {
        const find_str = std.mem.sliceTo(&editor_state.find_buffer, 0);
        if (find_str.len > 0) {
            const source = editor_state.source_buffer.items;
            const start = @min(editor_state.find_cursor, source.len);
            if (start < source.len) {
                if (std.mem.indexOf(u8, source[start..], find_str)) |rel| {
                    editor_state.find_cursor = start + rel + find_str.len;
                } else if (start > 0) {
                    // Wrap around from beginning
                    if (std.mem.indexOf(u8, source, find_str)) |pos| {
                        editor_state.find_cursor = pos + find_str.len;
                    }
                }
            } else {
                // Cursor past end, wrap around
                if (std.mem.indexOf(u8, source, find_str)) |pos| {
                    editor_state.find_cursor = pos + find_str.len;
                }
            }
        }
    }
    gui.sameLine();

    if (gui.button("Replace")) {
        const find_str = std.mem.sliceTo(&editor_state.find_buffer, 0);
        const replace_str = std.mem.sliceTo(&editor_state.replace_buffer, 0);
        if (find_str.len > 0) {
            replaceInSource(editor_state, find_str, replace_str, false);
        }
    }
    gui.sameLine();

    if (gui.button("Replace All")) {
        const find_str = std.mem.sliceTo(&editor_state.find_buffer, 0);
        const replace_str = std.mem.sliceTo(&editor_state.replace_buffer, 0);
        if (find_str.len > 0) {
            replaceInSource(editor_state, find_str, replace_str, true);
        }
    }
}

// ImGui key codes for keyboard shortcuts
const ImGuiKey_S: i32 = 564;
const ImGuiKey_F: i32 = 551;

fn handleKeyboardShortcuts(state: *EditorState, editor_state: *ScriptEditorState) void {
    _ = state;
    if (gui.keyCtrl()) {
        // Cmd+S: Save
        if (gui.isKeyPressed(ImGuiKey_S, false)) {
            if (editor_state.file_path == null) {
                saveScriptWithPicker(editor_state);
            } else {
                editor_state.saveToFile() catch {};
            }
        }
        // Cmd+F: Toggle find panel
        if (gui.isKeyPressed(ImGuiKey_F, false)) {
            editor_state.show_find_panel = !editor_state.show_find_panel;
        }
    }
}

fn replaceInSource(editor_state: *ScriptEditorState, find_str: []const u8, replace_str: []const u8, replace_all: bool) void {
    if (find_str.len == 0) return;
    const allocator = editor_state.allocator;
    const source = editor_state.source_buffer.items;

    var new_buf: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var count: usize = 0;

    while (pos < source.len) {
        if (std.mem.indexOf(u8, source[pos..], find_str)) |rel| {
            new_buf.appendSlice(allocator, source[pos .. pos + rel]) catch {
                new_buf.deinit(allocator);
                return;
            };
            new_buf.appendSlice(allocator, replace_str) catch {
                new_buf.deinit(allocator);
                return;
            };
            pos = pos + rel + find_str.len;
            count += 1;
            if (!replace_all) {
                new_buf.appendSlice(allocator, source[pos..]) catch {
                    new_buf.deinit(allocator);
                    return;
                };
                break;
            }
        } else {
            new_buf.appendSlice(allocator, source[pos..]) catch {
                new_buf.deinit(allocator);
                return;
            };
            break;
        }
    }

    if (count > 0) {
        editor_state.source_buffer.clearRetainingCapacity();
        editor_state.source_buffer.appendSlice(allocator, new_buf.items) catch {
            new_buf.deinit(allocator);
            return;
        };
        new_buf.deinit(allocator);
        editor_state.is_modified = true;
        editor_state.find_cursor = 0;
    } else {
        new_buf.deinit(allocator);
    }
}

fn drawConsolePanel(editor_state: *ScriptEditorState) void {
    if (gui.beginChild("console", -1.0, -1.0, true)) {
        gui.text("Console Output:");
        gui.separator();

        if (editor_state.console_output.items.len > 0) {
            gui.textWrapped(editor_state.console_output.items);
        } else {
            gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "No output");
        }
    }
    gui.endChild();

    if (gui.button("Clear")) {
        editor_state.clearConsole();
    }
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn getLine(text: []const u8, line_num: usize) []const u8 {
    if (line_num == 0) return "";

    var current_line: usize = 1;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (current_line == line_num) {
            line_start = i;
            break;
        }
        if (c == '\n') {
            current_line += 1;
        }
    }

    if (current_line != line_num) return "";

    for (text[line_start..], 0..) |c, i| {
        if (c == '\n') {
            return text[line_start .. line_start + i];
        }
    }

    return text[line_start..];
}

fn openScriptFilePicker(editor_state: *ScriptEditorState) void {
    const result = std.process.Child.run(.{
        .allocator = editor_state.allocator,
        .argv = &.{
            "/usr/bin/osascript",
            "-e",
            "POSIX path of (choose file of type {\"cs\", \"zig\", \"csproj\"} with prompt \"Open Script\")",
        },
    }) catch return;
    defer editor_state.allocator.free(result.stdout);
    defer editor_state.allocator.free(result.stderr);

    if (result.term.Exited != 0) return;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return;

    editor_state.loadFromFile(trimmed) catch |err| {
        const msg = std.fmt.allocPrint(editor_state.allocator, "Open failed: {}", .{err}) catch return;
        defer editor_state.allocator.free(msg);
        editor_state.appendConsole(msg) catch {};
    };
}

fn saveScriptWithPicker(editor_state: *ScriptEditorState) void {
    const result = std.process.Child.run(.{
        .allocator = editor_state.allocator,
        .argv = &.{
            "/usr/bin/osascript",
            "-e",
            "POSIX path of (choose file name with prompt \"Save Script\" default name \"NewScript.cs\")",
        },
    }) catch return;
    defer editor_state.allocator.free(result.stdout);
    defer editor_state.allocator.free(result.stderr);

    if (result.term.Exited != 0) return;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return;

    if (editor_state.file_path) |fp| editor_state.allocator.free(fp);
    editor_state.file_path = editor_state.allocator.dupe(u8, trimmed) catch return;
    editor_state.saveToFile() catch |err| {
        const msg = std.fmt.allocPrint(editor_state.allocator, "Save failed: {}", .{err}) catch return;
        defer editor_state.allocator.free(msg);
        editor_state.appendConsole(msg) catch {};
    };
}

fn buildCurrentScript(state: *EditorState, editor_state: *ScriptEditorState) void {
    const fp = editor_state.file_path orelse {
        editor_state.appendConsole("No file open to build.") catch {};
        return;
    };

    // Auto-save before build
    if (editor_state.is_modified) {
        editor_state.saveToFile() catch |err| {
            const msg = std.fmt.allocPrint(editor_state.allocator, "Auto-save before build failed: {}", .{err}) catch return;
            defer editor_state.allocator.free(msg);
            editor_state.appendConsole(msg) catch {};
            return;
        };
    }

    // Find .csproj in the same directory (for C# files)
    if (std.mem.endsWith(u8, fp, ".cs")) {
        const dir = if (std.mem.lastIndexOfScalar(u8, fp, '/')) |idx| fp[0..idx] else ".";
        editor_state.appendConsole("Building C# project...") catch {};
        editor_state.is_building = true;

        const dotnet_result = std.process.Child.run(.{
            .allocator = editor_state.allocator,
            .argv = &.{ "dotnet", "publish", "-c", "Release", "-o", "bin/publish" },
            .cwd = dir,
        }) catch |err| {
            editor_state.is_building = false;
            const msg = std.fmt.allocPrint(editor_state.allocator, "dotnet publish failed to start: {}", .{err}) catch return;
            defer editor_state.allocator.free(msg);
            editor_state.appendConsole(msg) catch {};
            return;
        };
        defer editor_state.allocator.free(dotnet_result.stdout);
        defer editor_state.allocator.free(dotnet_result.stderr);
        editor_state.is_building = false;

        if (dotnet_result.stdout.len > 0) {
            editor_state.appendConsole(dotnet_result.stdout) catch {};
        }
        if (dotnet_result.stderr.len > 0) {
            editor_state.appendConsole(dotnet_result.stderr) catch {};
        }

        if (dotnet_result.term.Exited == 0) {
            editor_state.appendConsole(state.text(.script_build_success)) catch {};
        } else {
            editor_state.appendConsole(state.text(.script_build_failed)) catch {};
        }
    } else if (std.mem.endsWith(u8, fp, ".zig")) {
        editor_state.appendConsole("Building Zig script...") catch {};
        editor_state.is_building = true;

        const zig_result = std.process.Child.run(.{
            .allocator = editor_state.allocator,
            .argv = &.{ "zig", "build" },
            .cwd = if (std.mem.lastIndexOfScalar(u8, fp, '/')) |idx| fp[0..idx] else ".",
        }) catch |err| {
            editor_state.is_building = false;
            const msg = std.fmt.allocPrint(editor_state.allocator, "zig build failed to start: {}", .{err}) catch return;
            defer editor_state.allocator.free(msg);
            editor_state.appendConsole(msg) catch {};
            return;
        };
        defer editor_state.allocator.free(zig_result.stdout);
        defer editor_state.allocator.free(zig_result.stderr);
        editor_state.is_building = false;

        if (zig_result.stdout.len > 0) {
            editor_state.appendConsole(zig_result.stdout) catch {};
        }
        if (zig_result.stderr.len > 0) {
            editor_state.appendConsole(zig_result.stderr) catch {};
        }

        if (zig_result.term.Exited == 0) {
            editor_state.appendConsole(state.text(.script_build_success)) catch {};
        } else {
            editor_state.appendConsole(state.text(.script_build_failed)) catch {};
        }
    } else {
        editor_state.appendConsole("Build not supported for this file type.") catch {};
    }
}

pub fn openFileInEditor(editor_state: *ScriptEditorState, path: []const u8) void {
    editor_state.loadFromFile(path) catch |err| {
        const msg = std.fmt.allocPrint(editor_state.allocator, "Failed to open: {}", .{err}) catch return;
        defer editor_state.allocator.free(msg);
        editor_state.appendConsole(msg) catch {};
    };
}
