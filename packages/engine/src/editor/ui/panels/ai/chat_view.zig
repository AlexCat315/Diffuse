const std = @import("std");
const gui = @import("../../gui.zig");
const theme = @import("../../theme.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

pub const max_messages = 128;
pub const max_message_len = 2048;
pub const max_input_len = 1024;

pub const Role = enum {
    user,
    assistant,
    reasoning,
    system,
};

pub const Message = struct {
    role: Role,
    text_len: usize = 0,
    text: [max_message_len]u8 = [_]u8{0} ** max_message_len,
    timestamp: i64 = 0,

    pub fn content(self: *const Message) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const StreamPreview = struct {
    active: bool = false,
    dirty: bool = false,
    assistant_len: usize = 0,
    assistant: [max_message_len]u8 = [_]u8{0} ** max_message_len,
    reasoning_len: usize = 0,
    reasoning: [max_message_len]u8 = [_]u8{0} ** max_message_len,

    pub fn clear(self: *StreamPreview) void {
        self.* = .{};
        self.dirty = true;
    }

    pub fn appendChunk(self: *StreamPreview, role: Role, chunk: []const u8) void {
        if (chunk.len == 0) return;

        const target: []u8 = switch (role) {
            .assistant => self.assistant[0..],
            .reasoning => self.reasoning[0..],
            else => return,
        };
        const target_len: *usize = switch (role) {
            .assistant => &self.assistant_len,
            .reasoning => &self.reasoning_len,
            else => return,
        };

        self.active = true;
        const available = target.len - target_len.*;
        const copy_len = @min(chunk.len, available);
        if (copy_len > 0) {
            @memcpy(target[target_len.* .. target_len.* + copy_len], chunk[0..copy_len]);
            target_len.* += copy_len;
        }
        self.dirty = true;
    }

    pub fn hasVisibleContent(self: *const StreamPreview) bool {
        return self.assistant_len > 0 or self.reasoning_len > 0;
    }
};

fn roleLabel(state: *EditorState, role: Role) []const u8 {
    return switch (role) {
        .user => state.text(.ai_chat_role_you),
        .assistant => state.text(.ai_chat_role_assistant),
        .reasoning => state.text(.ai_chat_role_reasoning),
        .system => "",
    };
}

fn roleAccent(role: Role) [4]f32 {
    return switch (role) {
        .user => theme.Palette.ai_chat.role_user_accent,
        .assistant => theme.Palette.ai_chat.role_assistant_accent,
        .reasoning => theme.Palette.ai_chat.role_reasoning_accent,
        .system => theme.Palette.ai_chat.role_system_accent,
    };
}

fn cardBackground(role: Role) [4]f32 {
    return switch (role) {
        .user => theme.Palette.ai_chat.user_card_bg,
        .assistant => theme.Palette.ai_chat.assistant_card_bg,
        .system => theme.Palette.ai_chat.system_card_bg,
        .reasoning => theme.Palette.ai_chat.reasoning_card_bg,
    };
}

fn bodyColor(role: Role) [4]f32 {
    return switch (role) {
        .user => theme.Palette.ai_chat.user_body_text,
        .assistant => theme.Palette.ai_chat.assistant_body_text,
        .system => theme.Palette.ai_chat.system_body_text,
        .reasoning => theme.Palette.ai_chat.reasoning_body_text,
    };
}

fn drawTextCard(state: *EditorState, role: Role, content_text: []const u8, card_id: u64) void {
    const available_width = gui.contentRegionAvail()[0];
    const wrap_width = @max(available_width - 28.0, 80.0);
    const label = roleLabel(state, role);
    const label_height = if (label.len > 0) gui.calcTextSize(label, false, 0.0)[1] else 0.0;
    const body_height = gui.calcTextSize(content_text, false, wrap_width)[1];
    const card_height = @max(48.0, label_height + body_height + 28.0);

    gui.pushIdU64(card_id);
    defer gui.popId();

    gui.pushStyleColor(.border, theme.Palette.ai_chat.message_card_border);
    gui.pushStyleVarVec2(.window_padding, theme.Spacing.ai_chat_message_padding);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(1);
    }

    _ = gui.beginChild("message_card", 0.0, card_height, true);
    defer gui.endChild();

    if (label.len > 0) {
        gui.pushStyleColor(.text, roleAccent(role));
        gui.text(label);
        gui.popStyleColor(1);
        gui.dummy(0.0, 2.0);
    }

    gui.pushStyleColor(.text, bodyColor(role));
    gui.textWrapped(content_text);
    gui.popStyleColor(1);
}

fn drawReasoningSection(state: *EditorState, content_text: []const u8, section_id: u64) void {
    gui.pushIdU64(section_id);
    defer gui.popId();

    gui.pushStyleColor(.text, roleAccent(.reasoning));
    if (gui.collapsingHeader(state.text(.ai_chat_role_reasoning), false)) {
        gui.popStyleColor(1);
        gui.indent(10.0);
        defer gui.unindent(10.0);
        gui.pushStyleColor(.text, bodyColor(.reasoning));
        gui.textWrapped(content_text);
        gui.popStyleColor(1);
    } else {
        gui.popStyleColor(1);
    }
}

pub fn drawMessages(state: *EditorState, messages: []const Message, message_count: usize, preview: *const StreamPreview) void {
    var rendered_any = false;

    for (messages[0..message_count], 0..) |msg, index| {
        const content_text = msg.content();
        if (content_text.len == 0) continue;

        if (rendered_any) {
            gui.dummy(0.0, 6.0);
        }

        if (msg.role == .reasoning) {
            drawReasoningSection(state, content_text, @intCast(index));
        } else {
            drawTextCard(state, msg.role, content_text, @intCast(index));
        }
        rendered_any = true;
    }

    if (preview.reasoning_len > 0) {
        if (rendered_any) gui.dummy(0.0, 6.0);
        drawReasoningSection(state, preview.reasoning[0..preview.reasoning_len], 10_001);
        rendered_any = true;
    }

    if (preview.assistant_len > 0) {
        if (rendered_any) gui.dummy(0.0, 6.0);
        drawTextCard(state, .assistant, preview.assistant[0..preview.assistant_len], 10_002);
        rendered_any = true;
    }

    if (!rendered_any) {
        gui.dummy(0.0, 8.0);
        gui.pushStyleColor(.text, theme.Palette.ai_chat.empty_text);
        gui.textWrapped(state.text(.ai_chat_empty));
        gui.popStyleColor(1);
    }
}
