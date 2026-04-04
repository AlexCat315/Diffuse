const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const layout = @import("../../layout.zig");
const theme = @import("../../theme.zig");
const ui_icons = @import("../../icons.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const history = @import("../../../actions/history.zig");
const state_mod = @import("../../../core/state.zig");
const preferences = @import("../../../core/preferences.zig");
const i18n = @import("../../../i18n/mod.zig");
const chat_view = @import("chat_view.zig");
const provider_client = @import("provider_client.zig");
const provider_support = @import("provider_support.zig");
const EditorState = state_mod.EditorState;
const AiProviderType = state_mod.AiProviderType;

const ai_chat_log = std.log.scoped(.ai_chat);

const max_messages = chat_view.max_messages;
const max_message_len = chat_view.max_message_len;
const max_input_len = chat_view.max_input_len;
pub const Role = chat_view.Role;
pub const Message = chat_view.Message;
const StreamState = chat_view.StreamPreview;

var g_messages: [max_messages]Message = undefined;
var g_message_count: usize = 0;
var g_input_buffer: [max_input_len]u8 = [_]u8{0} ** max_input_len;
var g_scroll_to_bottom: bool = false;
var g_connection_error: ?[]const u8 = null;
var g_meta_request_counter: u64 = 0;
var g_meta_session_id_len: usize = 0;
var g_meta_session_id_buffer: [64]u8 = [_]u8{0} ** 64;

const AsyncMessageRole = enum {
    assistant,
    system,
};

const AsyncTimelineEvent = struct {
    label: []u8,
    detail: []u8,
    command_kind: []u8,

    fn deinit(self: *AsyncTimelineEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.detail);
        allocator.free(self.command_kind);
        self.* = undefined;
    }
};

const AsyncResult = struct {
    role: AsyncMessageRole = .assistant,
    text: []u8,
    reasoning: ?[]u8 = null,
    snapshot_dirty: bool = false,
    timeline_event: ?AsyncTimelineEvent = null,

    fn deinit(self: *AsyncResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.reasoning) |value| allocator.free(value);
        if (self.timeline_event) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

const AsyncTaskKind = enum {
    tool_command,
    prompt_intent,
};

const AsyncTaskContext = struct {
    kind: AsyncTaskKind,
    language: i18n.Language = .en_us,
    tool_name: ?[]u8 = null,
    raw_arguments: ?[]u8 = null,
    prompt: ?[]u8 = null,
    provider_type: AiProviderType = .openai,
    provider_endpoint: ?[]u8 = null,
    provider_model: ?[]u8 = null,
    provider_api_key: ?[]u8 = null,
    tool_bridge: ?*engine.mcp.tools.Bridge = null,
    collaboration_bridge: ?*engine.mcp.collaboration.Bridge = null,
    snapshot_store: ?*engine.mcp.resources.SnapshotStore = null,
    command_meta: engine.core.CommandMeta = .{},

    fn deinit(self: *AsyncTaskContext, allocator: std.mem.Allocator) void {
        if (self.tool_name) |value| allocator.free(value);
        if (self.raw_arguments) |value| allocator.free(value);
        if (self.prompt) |value| allocator.free(value);
        if (self.provider_endpoint) |value| allocator.free(value);
        if (self.provider_model) |value| allocator.free(value);
        if (self.provider_api_key) |value| allocator.free(value);
        self.command_meta.deinit(allocator);
        self.* = undefined;
    }
};

const AsyncState = struct {
    mutex: std.Thread.Mutex = .{},
    running: bool = false,
    result: ?AsyncResult = null,
    stream: StreamState = .{},
};

var g_async_state: AsyncState = .{};

var g_stream_preview: StreamState = .{};

const max_provider_feedback_len = 256;

const ProviderPanelFeedbackKind = enum {
    none,
    success,
    failure,
};

const ProviderPanelFeedback = struct {
    kind: ProviderPanelFeedbackKind = .none,
    text_len: usize = 0,
    text: [max_provider_feedback_len]u8 = [_]u8{0} ** max_provider_feedback_len,

    fn clear(self: *ProviderPanelFeedback) void {
        self.* = .{};
    }

    fn set(self: *ProviderPanelFeedback, kind: ProviderPanelFeedbackKind, value: []const u8) void {
        self.kind = kind;
        self.text_len = @min(value.len, self.text.len);
        if (self.text_len > 0) {
            @memcpy(self.text[0..self.text_len], value[0..self.text_len]);
        }
        if (self.text_len < self.text.len) {
            @memset(self.text[self.text_len..], 0);
        }
    }

    fn slice(self: *const ProviderPanelFeedback) []const u8 {
        return self.text[0..self.text_len];
    }
};

var g_provider_feedback: ProviderPanelFeedback = .{};

fn roleLogText(role: Role) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .reasoning => "reasoning",
        .system => "system",
    };
}

pub fn appendMessage(role: Role, text: []const u8) void {
    if (g_message_count >= max_messages) {
        for (0..max_messages - 1) |i| {
            g_messages[i] = g_messages[i + 1];
        }
        g_message_count = max_messages - 1;
    }
    var msg = &g_messages[g_message_count];
    msg.role = role;
    msg.text_len = @min(text.len, max_message_len);
    if (msg.text_len > 0) {
        @memcpy(msg.text[0..msg.text_len], text[0..msg.text_len]);
    }
    msg.timestamp = std.time.timestamp();
    g_message_count += 1;
    g_scroll_to_bottom = true;

    const preview_len = @min(text.len, @as(usize, 320));
    ai_chat_log.info("Message[{s}]: {s}{s}", .{
        roleLogText(role),
        text[0..preview_len],
        if (text.len > preview_len) "..." else "",
    });
}

pub fn clearHistory() void {
    g_message_count = 0;
    g_stream_preview = .{};
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (g_async_state.result) |*result| {
        result.deinit(std.heap.page_allocator);
        g_async_state.result = null;
    }
    g_async_state.stream = .{};
    ai_chat_log.info("Chat history cleared", .{});
}

pub fn clearConnectionError() void {
    g_connection_error = null;
}

fn commandApprovalForTool(tool_name: []const u8) engine.core.CommandApprovalState {
    if (std.mem.eql(u8, tool_name, "stage_transaction")) return .previewed;
    if (std.mem.eql(u8, tool_name, "apply_staged_transaction")) return .user_approved;
    if (std.mem.eql(u8, tool_name, "discard_staged_transaction")) return .rejected;
    return .auto;
}

fn ensureMetaSessionId() []const u8 {
    if (g_meta_session_id_len != 0) {
        return g_meta_session_id_buffer[0..g_meta_session_id_len];
    }

    const timestamp = std.time.milliTimestamp();
    const generated = std.fmt.bufPrint(&g_meta_session_id_buffer, "ai-chat-{d}", .{timestamp}) catch {
        const fallback = "ai-chat";
        @memcpy(g_meta_session_id_buffer[0..fallback.len], fallback);
        g_meta_session_id_len = fallback.len;
        return g_meta_session_id_buffer[0..g_meta_session_id_len];
    };
    g_meta_session_id_len = generated.len;
    return g_meta_session_id_buffer[0..g_meta_session_id_len];
}

fn buildAiCommandMetaAlloc(
    allocator: std.mem.Allocator,
    tool_name: ?[]const u8,
    base_revision: ?u64,
) !engine.core.CommandMeta {
    g_meta_request_counter += 1;
    const request_id = g_meta_request_counter;
    const session_id = ensureMetaSessionId();

    var meta: engine.core.CommandMeta = .{};
    errdefer meta.deinit(allocator);

    meta.actor = try allocator.dupe(u8, "ai_chat");
    meta.client = try allocator.dupe(u8, "editor");
    meta.session = try allocator.dupe(u8, session_id);
    meta.request = try std.fmt.allocPrint(allocator, "req-{d}", .{request_id});
    meta.trace = if (tool_name) |resolved_tool_name|
        try std.fmt.allocPrint(allocator, "trace-{d}:{s}", .{ request_id, resolved_tool_name })
    else
        try std.fmt.allocPrint(allocator, "trace-{d}:intent", .{request_id});
    meta.approval = if (tool_name) |resolved_tool_name| commandApprovalForTool(resolved_tool_name) else .auto;
    meta.base_revision = base_revision;
    return meta;
}

fn deriveToolCommandMetaAlloc(
    allocator: std.mem.Allocator,
    base_meta: ?*const engine.core.CommandMeta,
    tool_name: []const u8,
) !engine.core.CommandMeta {
    if (base_meta) |resolved_base| {
        var meta = try resolved_base.cloneAlloc(allocator);
        errdefer meta.deinit(allocator);
        meta.approval = commandApprovalForTool(tool_name);
        if (meta.trace) |existing_trace| {
            allocator.free(existing_trace);
        }
        const request_text = meta.request orelse "req-0";
        meta.trace = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ request_text, tool_name });
        return meta;
    }
    return buildAiCommandMetaAlloc(allocator, tool_name, null);
}

fn providerTypeText(state: *const EditorState, provider_type: AiProviderType) []const u8 {
    return provider_support.providerTypeText(state, provider_type);
}

fn providerDisplayNameForUi(state: *const EditorState, provider: *const state_mod.AiProviderConfig) []const u8 {
    return provider_support.providerDisplayNameForUi(state, provider);
}

fn providerNameExists(state: *const EditorState, candidate: []const u8) bool {
    const trimmed_candidate = std.mem.trim(u8, candidate, " \t\r\n");
    if (trimmed_candidate.len == 0) return false;

    for (0..state.ai_provider_count) |index| {
        const existing = std.mem.trim(u8, fixedBufferSlice(state.ai_providers[index].name[0..]), " \t\r\n");
        if (existing.len == 0) continue;
        if (std.mem.eql(u8, existing, trimmed_candidate)) return true;
    }
    return false;
}

fn nextGeneratedProviderNameAlloc(state: *const EditorState) ![]u8 {
    const allocator = std.heap.page_allocator;
    const base_name = state.text(.ai_chat_provider_default_name);
    if (!providerNameExists(state, base_name)) {
        return allocator.dupe(u8, base_name);
    }

    var ordinal: usize = 2;
    while (ordinal < 10_000) : (ordinal += 1) {
        const candidate = try i18n.allocPrintMessage(
            .ai_chat_provider_default_name_fmt,
            allocator,
            state.language,
            .{ordinal},
        );
        errdefer allocator.free(candidate);
        if (!providerNameExists(state, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }

    return allocator.dupe(u8, base_name);
}

fn applyProviderDefaults(state: *EditorState) void {
    provider_support.applyProviderDefaults(state);
}

fn testHttpConnectionAlloc(
    language: i18n.Language,
    provider_type: AiProviderType,
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
) ![]u8 {
    const endpoint_copy = try std.heap.page_allocator.dupe(u8, endpoint);
    defer std.heap.page_allocator.free(endpoint_copy);
    const model_copy = try std.heap.page_allocator.dupe(u8, model);
    defer std.heap.page_allocator.free(model_copy);
    const api_key_copy = try std.heap.page_allocator.dupe(u8, api_key);
    defer std.heap.page_allocator.free(api_key_copy);

    var task: AsyncTaskContext = .{
        .kind = .prompt_intent,
        .language = language,
        .provider_type = provider_type,
        .provider_endpoint = endpoint_copy,
        .provider_model = model_copy,
        .provider_api_key = api_key_copy,
    };
    const probe = "Connection probe. Return {\"type\":\"message\",\"message\":\"pong\"}.";
    var completion = try requestProviderCompletionAlloc(&task, probe);
    defer completion.deinit(std.heap.page_allocator);

    const trimmed = std.mem.trim(u8, completion.content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, i18n.text(language, .ai_chat_provider_request_failed_fallback))) {
        return std.heap.page_allocator.dupe(u8, trimmed);
    }
    return i18n.allocPrintMessage(
        .ai_chat_connection_test_succeeded_fmt,
        std.heap.page_allocator,
        language,
        .{clipped(trimmed, 220)},
    ) catch try std.heap.page_allocator.dupe(
        u8,
        i18n.text(language, .ai_chat_connection_test_succeeded_fallback),
    );
}

fn logProviderConfig(state: *EditorState) void {
    const p = provider_support.activeProvider(state);
    ai_chat_log.info("=== Provider Configuration ===", .{});
    ai_chat_log.info("Type: {s}", .{@tagName(provider_support.activeProviderType(state))});
    ai_chat_log.info("Name: {s}", .{providerDisplayNameForUi(state, p)});

    const endpoint_len = std.mem.indexOfScalar(u8, &p.endpoint, 0) orelse p.endpoint.len;
    const endpoint_slice = p.endpoint[0..endpoint_len];
    ai_chat_log.info("Endpoint: {s}", .{endpoint_slice});

    const model_len = std.mem.indexOfScalar(u8, &p.model, 0) orelse p.model.len;
    const model_slice = p.model[0..model_len];
    ai_chat_log.info("Model: {s}", .{model_slice});

    const apikey_len = std.mem.indexOfScalar(u8, &p.api_key, 0) orelse p.api_key.len;
    ai_chat_log.info("API Key length: {d} chars", .{apikey_len});
    ai_chat_log.info("============================", .{});
}

fn asyncTryBegin() bool {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (g_async_state.running) {
        return false;
    }
    g_async_state.running = true;
    g_async_state.stream = .{};
    g_async_state.stream.active = true;
    g_async_state.stream.dirty = true;
    return true;
}

fn asyncIsRunning() bool {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    return g_async_state.running;
}

fn asyncFinishWithoutResult() void {
    g_async_state.mutex.lock();
    g_async_state.running = false;
    g_async_state.stream.clear();
    g_async_state.mutex.unlock();
}

fn asyncPublishResult(result: AsyncResult) void {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (g_async_state.result) |*existing| {
        existing.deinit(std.heap.page_allocator);
    }
    g_async_state.result = result;
    g_async_state.running = false;
    g_async_state.stream.clear();
}

fn asyncTakeResult() ?AsyncResult {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    const result = g_async_state.result;
    g_async_state.result = null;
    return result;
}

fn asyncAppendStreamChunk(role: Role, chunk: []const u8) void {
    if (chunk.len == 0) return;

    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    g_async_state.stream.appendChunk(role, chunk);
}

fn asyncTakeStreamPreview() ?StreamState {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (!g_async_state.stream.dirty) return null;

    const snapshot = g_async_state.stream;
    g_async_state.stream.dirty = false;
    return snapshot;
}

fn allocMessage(comptime fmt: []const u8, args: anytype, fallback: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch try std.heap.page_allocator.dupe(u8, fallback);
}

fn fixedBufferSlice(buffer: []const u8) []const u8 {
    return provider_support.fixedBufferSlice(buffer);
}

fn isMcpBridgeReady(state: *const EditorState) bool {
    return state.ai_collaboration != null and state.ai_tool_bridge != null and state.ai_collaboration_bridge != null;
}

const ProviderValidationError = provider_support.ProviderValidationError;

fn activeProviderValidationError(state: *const EditorState) ?ProviderValidationError {
    return provider_support.activeProviderValidationError(state);
}

fn providerValidationErrorText(state: *const EditorState, validation_error: ProviderValidationError) []const u8 {
    return provider_support.providerValidationErrorText(state, validation_error);
}

fn clipped(slice: []const u8, max_len: usize) []const u8 {
    return if (slice.len <= max_len) slice else slice[0..max_len];
}

fn jsonObjectField(root: ?std.json.Value, key: []const u8) ?std.json.Value {
    const resolved_root = root orelse return null;
    if (resolved_root != .object) return null;
    return resolved_root.object.get(key);
}

fn jsonStringField(root: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = jsonObjectField(root, key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        .number_string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn jsonBoolField(root: ?std.json.Value, key: []const u8) ?bool {
    const value = jsonObjectField(root, key) orelse return null;
    return switch (value) {
        .bool => |resolved| resolved,
        else => null,
    };
}

fn sliceIsDigits(slice: []const u8) bool {
    if (slice.len == 0) return false;
    for (slice) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn allocReferenceText(value: std.json.Value) !?[]u8 {
    return switch (value) {
        .integer => |number| try std.fmt.allocPrint(std.heap.page_allocator, "#{d}", .{number}),
        .float => |number| blk: {
            if (!std.math.isFinite(number) or number < 0) break :blk null;
            const rounded = @round(number);
            if (@abs(number - rounded) > 0.0001) break :blk null;
            break :blk try std.fmt.allocPrint(std.heap.page_allocator, "#{d}", .{@as(u64, @intFromFloat(rounded))});
        },
        .number_string => |text| blk: {
            if (text.len == 0) break :blk null;
            if (sliceIsDigits(text)) {
                break :blk try std.fmt.allocPrint(std.heap.page_allocator, "#{s}", .{text});
            }
            break :blk try std.heap.page_allocator.dupe(u8, text);
        },
        .string => |text| blk: {
            if (text.len == 0) break :blk null;
            if (sliceIsDigits(text)) {
                break :blk try std.fmt.allocPrint(std.heap.page_allocator, "#{s}", .{text});
            }
            break :blk try std.heap.page_allocator.dupe(u8, text);
        },
        else => null,
    };
}

fn allocReferenceForKey(root: ?std.json.Value, key: []const u8) !?[]u8 {
    const value = jsonObjectField(root, key) orelse return null;
    if (value == .null) return null;
    return allocReferenceText(value);
}

fn allocLocalizedMessage(language: i18n.Language, id: i18n.MessageId) ![]u8 {
    return std.heap.page_allocator.dupe(u8, i18n.text(language, id));
}

fn makeAiTimelineLabelAlloc(language: i18n.Language, tool_name: []const u8, arguments_value: ?std.json.Value) ![]u8 {
    if (std.mem.eql(u8, tool_name, "create_entity")) {
        if (jsonStringField(arguments_value, "name")) |name| {
            return i18n.allocPrintMessage(
                .ai_chat_timeline_create_entity_named_fmt,
                std.heap.page_allocator,
                language,
                .{name},
            );
        }
        return allocLocalizedMessage(language, .ai_chat_timeline_create_entity);
    }

    if (std.mem.eql(u8, tool_name, "delete_entity")) {
        if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
            defer std.heap.page_allocator.free(entity_ref);
            return i18n.allocPrintMessage(
                .ai_chat_timeline_delete_entity_fmt,
                std.heap.page_allocator,
                language,
                .{entity_ref},
            );
        }
    }

    if (std.mem.eql(u8, tool_name, "rename_entity")) {
        const maybe_name = jsonStringField(arguments_value, "name");
        if (maybe_name) |name| {
            if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
                defer std.heap.page_allocator.free(entity_ref);
                return i18n.allocPrintMessage(
                    .ai_chat_timeline_rename_entity_fmt,
                    std.heap.page_allocator,
                    language,
                    .{ entity_ref, name },
                );
            }
        }
    }

    if (std.mem.eql(u8, tool_name, "set_parent")) {
        if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
            defer std.heap.page_allocator.free(entity_ref);

            if (jsonObjectField(arguments_value, "parent_id")) |parent_value| {
                if (parent_value == .null) {
                    return i18n.allocPrintMessage(
                        .ai_chat_timeline_unparent_entity_fmt,
                        std.heap.page_allocator,
                        language,
                        .{entity_ref},
                    );
                }
            }

            if (try allocReferenceForKey(arguments_value, "parent_id")) |parent_ref| {
                defer std.heap.page_allocator.free(parent_ref);
                return i18n.allocPrintMessage(
                    .ai_chat_timeline_reparent_entity_fmt,
                    std.heap.page_allocator,
                    language,
                    .{ entity_ref, parent_ref },
                );
            }
        }
    }

    if (std.mem.eql(u8, tool_name, "set_local_transform")) {
        if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
            defer std.heap.page_allocator.free(entity_ref);
            return i18n.allocPrintMessage(
                .ai_chat_timeline_set_local_transform_fmt,
                std.heap.page_allocator,
                language,
                .{entity_ref},
            );
        }
    }

    if (std.mem.eql(u8, tool_name, "set_world_transform")) {
        if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
            defer std.heap.page_allocator.free(entity_ref);
            return i18n.allocPrintMessage(
                .ai_chat_timeline_set_world_transform_fmt,
                std.heap.page_allocator,
                language,
                .{entity_ref},
            );
        }
    }

    if (std.mem.eql(u8, tool_name, "set_visible")) {
        if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
            defer std.heap.page_allocator.free(entity_ref);
            if (jsonBoolField(arguments_value, "visible")) |visible| {
                if (visible) {
                    return i18n.allocPrintMessage(
                        .ai_chat_timeline_show_entity_fmt,
                        std.heap.page_allocator,
                        language,
                        .{entity_ref},
                    );
                }
                return i18n.allocPrintMessage(
                    .ai_chat_timeline_hide_entity_fmt,
                    std.heap.page_allocator,
                    language,
                    .{entity_ref},
                );
            }
        }
    }

    if (std.mem.eql(u8, tool_name, "compile_script")) {
        if (try allocReferenceForKey(arguments_value, "entity_id")) |entity_ref| {
            defer std.heap.page_allocator.free(entity_ref);
            return i18n.allocPrintMessage(
                .ai_chat_timeline_compile_script_for_entity_fmt,
                std.heap.page_allocator,
                language,
                .{entity_ref},
            );
        }
        return allocLocalizedMessage(language, .ai_chat_timeline_compile_script);
    }

    if (std.mem.eql(u8, tool_name, "compile_editor_utility")) {
        if (jsonStringField(arguments_value, "utility_name")) |utility_name| {
            return i18n.allocPrintMessage(
                .ai_chat_timeline_compile_editor_utility_fmt,
                std.heap.page_allocator,
                language,
                .{utility_name},
            );
        }
        return allocLocalizedMessage(language, .ai_chat_timeline_compile_editor_utility);
    }

    if (std.mem.eql(u8, tool_name, "stage_transaction")) {
        return allocLocalizedMessage(language, .ai_chat_timeline_stage_transaction);
    }
    if (std.mem.eql(u8, tool_name, "apply_staged_transaction")) {
        return allocLocalizedMessage(language, .ai_chat_timeline_apply_staged_transaction);
    }
    if (std.mem.eql(u8, tool_name, "discard_staged_transaction")) {
        return allocLocalizedMessage(language, .ai_chat_timeline_discard_staged_transaction);
    }

    return allocLocalizedMessage(language, .history_timeline_label_ai_scene_edited);
}

fn makeAiTimelineEventAlloc(
    language: i18n.Language,
    tool_name: []const u8,
    arguments_value: ?std.json.Value,
    detail: []const u8,
) !AsyncTimelineEvent {
    const label = try makeAiTimelineLabelAlloc(language, tool_name, arguments_value);
    errdefer std.heap.page_allocator.free(label);

    const trimmed_detail = std.mem.trim(u8, detail, " \t\r\n");
    const use_label_for_detail = trimmed_detail.len == 0 or
        std.mem.eql(u8, trimmed_detail, i18n.text(language, .ai_chat_tool_ok)) or
        std.mem.eql(u8, trimmed_detail, i18n.text(language, .ai_chat_collaboration_tool_ok));
    return .{
        .label = label,
        .detail = try std.heap.page_allocator.dupe(
            u8,
            if (use_label_for_detail) label else trimmed_detail,
        ),
        .command_kind = try std.heap.page_allocator.dupe(u8, tool_name),
    };
}

fn recordAiTimelineEvent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    event: *const AsyncTimelineEvent,
) void {
    history.captureSnapshotWithTimelineDetails(
        state,
        layer_context,
        .ai,
        event.label,
        event.detail,
        event.command_kind,
    ) catch |err| {
        ai_chat_log.warn("failed to capture AI timeline snapshot: {s}", .{@errorName(err)});
    };
}

const ProviderCompletion = provider_client.ProviderCompletion;

const LlmDecision = union(enum) {
    tool_call: struct {
        tool_name: []u8,
        arguments_json: ?[]u8 = null,
    },
    message: []u8,

    fn deinit(self: *LlmDecision, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tool_call => |*value| {
                allocator.free(value.tool_name);
                if (value.arguments_json) |arguments_json| {
                    allocator.free(arguments_json);
                }
            },
            .message => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

const llm_tool_system_prompt =
    \\You are Guava Engine's MCP tool planner.
    \\Return exactly one JSON object and nothing else (no markdown).
    \\Use one of:
    \\{"type":"mcp_tool_call","tool":"<tool_name>","arguments":{...}}
    \\{"type":"message","message":"<plain text reply>"}
    \\Prefer tool calls for actionable requests.
    \\Use the schema://tools context below to satisfy required arguments exactly.
    \\For create_entity, always include at least {"name":"<short name>"}.
    \\If the user wants a new entity but does not specify a name, invent a concise descriptive name.
    \\Available tools:
    \\create_entity, delete_entity, rename_entity, set_parent, set_local_transform, set_world_transform, set_visible,
    \\query_entities, compile_script, compile_editor_utility, screenshot_png,
    \\stage_transaction, apply_staged_transaction, discard_staged_transaction.
    \\If arguments are not needed, omit "arguments".
;

fn stringifyJsonValueAlloc(value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try std.heap.page_allocator.dupe(u8, out.written());
}

fn readResourceTextAlloc(store: ?*engine.mcp.resources.SnapshotStore, uri: []const u8, max_len: usize) ![]u8 {
    const snapshot_store = store orelse return std.heap.page_allocator.dupe(u8, "{}");
    const content = snapshot_store.readAlloc(std.heap.page_allocator, uri) catch return std.heap.page_allocator.dupe(u8, "{}");
    if (content == null) {
        return std.heap.page_allocator.dupe(u8, "{}");
    }
    defer engine.mcp.resources.freeTextResourceContents(std.heap.page_allocator, content.?);
    return std.heap.page_allocator.dupe(u8, clipped(content.?.text, max_len));
}

fn buildImplicitContextAlloc(store: ?*engine.mcp.resources.SnapshotStore) ![]u8 {
    const selection = try readResourceTextAlloc(store, "selection://current", 2 * 1024);
    defer std.heap.page_allocator.free(selection);
    const context = try readResourceTextAlloc(store, "editor://context", 6 * 1024);
    defer std.heap.page_allocator.free(context);
    const tool_schema = try readResourceTextAlloc(store, "schema://tools", 8 * 1024);
    defer std.heap.page_allocator.free(tool_schema);

    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "selection://current\n{s}\n\neditor://context\n{s}\n\nschema://tools\n{s}",
        .{ selection, context, tool_schema },
    );
}

fn providerStreamSinkAppend(_: ?*anyopaque, role: provider_client.StreamRole, chunk: []const u8) void {
    asyncAppendStreamChunk(switch (role) {
        .assistant => .assistant,
        .reasoning => .reasoning,
    }, chunk);
}

fn requestProviderCompletionAlloc(task: *const AsyncTaskContext, prompt: []const u8) !ProviderCompletion {
    const endpoint = task.provider_endpoint orelse return error.MissingProviderEndpoint;
    const model = task.provider_model orelse return error.MissingProviderModel;
    const api_key = task.provider_api_key orelse "";
    const implicit_context = try buildImplicitContextAlloc(task.snapshot_store);
    defer std.heap.page_allocator.free(implicit_context);
    const user_prompt = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "User request:\n{s}\n\nEditor context:\n{s}\n\nReturn JSON only.",
        .{ prompt, implicit_context },
    );
    defer std.heap.page_allocator.free(user_prompt);

    return provider_client.requestCompletionAlloc(&.{
        .language = task.language,
        .provider_type = task.provider_type,
        .endpoint_raw = endpoint,
        .model = model,
        .api_key = api_key,
        .system_prompt = llm_tool_system_prompt,
        .user_prompt = user_prompt,
        .stream_sink = .{
            .append_fn = providerStreamSinkAppend,
        },
    });
}

fn stripCodeFence(text: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) {
        return trimmed;
    }

    const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    trimmed = std.mem.trim(u8, trimmed[first_newline + 1 ..], " \t\r\n");
    if (std.mem.endsWith(u8, trimmed, "```")) {
        return std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t\r\n");
    }
    return trimmed;
}

fn extractJsonCandidate(text: []const u8) []const u8 {
    const cleaned = stripCodeFence(text);
    if (cleaned.len == 0) return cleaned;
    if (cleaned[0] == '{') return cleaned;

    const start = std.mem.indexOfScalar(u8, cleaned, '{') orelse return cleaned;
    const end = std.mem.lastIndexOfScalar(u8, cleaned, '}') orelse return cleaned;
    if (end <= start) return cleaned;
    return cleaned[start .. end + 1];
}

fn parseLlmDecisionAlloc(raw_text: []const u8) !LlmDecision {
    const candidate = extractJsonCandidate(raw_text);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, candidate, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        return .{
            .message = try std.heap.page_allocator.dupe(u8, std.mem.trim(u8, raw_text, " \t\r\n")),
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{
            .message = try std.heap.page_allocator.dupe(u8, std.mem.trim(u8, raw_text, " \t\r\n")),
        };
    }

    const root = parsed.value.object;
    const type_value = root.get("type");
    const is_message = if (type_value) |value|
        value == .string and std.ascii.eqlIgnoreCase(value.string, "message")
    else
        false;

    if (!is_message) {
        const tool_field = root.get("tool") orelse root.get("name");
        if (tool_field != null and tool_field.? == .string and tool_field.?.string.len != 0) {
            const arguments_value = root.get("arguments");
            const arguments_json = if (arguments_value) |value|
                if (value == .null) null else try stringifyJsonValueAlloc(value)
            else
                null;
            return .{
                .tool_call = .{
                    .tool_name = try std.heap.page_allocator.dupe(u8, tool_field.?.string),
                    .arguments_json = arguments_json,
                },
            };
        }
    }

    if (root.get("message")) |value| {
        if (value == .string) {
            return .{
                .message = try std.heap.page_allocator.dupe(u8, value.string),
            };
        }
    }
    if (root.get("text")) |value| {
        if (value == .string) {
            return .{
                .message = try std.heap.page_allocator.dupe(u8, value.string),
            };
        }
    }

    return .{
        .message = try std.heap.page_allocator.dupe(u8, std.mem.trim(u8, raw_text, " \t\r\n")),
    };
}

fn touchImplicitContext(store: ?*engine.mcp.resources.SnapshotStore) void {
    const snapshot_store = store orelse return;

    const context = snapshot_store.readAlloc(std.heap.page_allocator, "editor://context") catch return;
    if (context) |resolved| {
        engine.mcp.resources.freeTextResourceContents(std.heap.page_allocator, resolved);
    }
}

fn executeToolCallAsync(
    language: i18n.Language,
    tool_bridge: ?*engine.mcp.tools.Bridge,
    collaboration_bridge: ?*engine.mcp.collaboration.Bridge,
    tool_name: []const u8,
    raw_arguments: []const u8,
    command_meta: ?*const engine.core.CommandMeta,
) !AsyncResult {
    var parsed_args: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_args) |*parsed| parsed.deinit();

    const arguments_value: ?std.json.Value = blk: {
        if (raw_arguments.len == 0) {
            break :blk null;
        }
        parsed_args = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw_arguments, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            return .{
                .role = .system,
                .text = try std.heap.page_allocator.dupe(u8, i18n.text(language, .ai_chat_json_parse_failed_example)),
            };
        };
        break :blk parsed_args.?.value;
    };

    var tool_meta = try deriveToolCommandMetaAlloc(std.heap.page_allocator, command_meta, tool_name);
    defer tool_meta.deinit(std.heap.page_allocator);

    if (engine.mcp.collaboration.isToolName(tool_name)) {
        const bridge = collaboration_bridge orelse {
            return .{
                .role = .system,
                .text = try std.heap.page_allocator.dupe(u8, i18n.text(language, .ai_chat_disconnected)),
            };
        };
        var response = bridge.submitJsonWithMeta(tool_name, arguments_value, &tool_meta) catch |err| {
            return .{
                .role = .system,
                .text = try allocMessage(
                    "{s}: {s}",
                    .{ i18n.text(language, .ai_chat_collaboration_tool_call_failed_fallback), @errorName(err) },
                    i18n.text(language, .ai_chat_collaboration_tool_call_failed_fallback),
                ),
            };
        };
        defer response.deinit(bridge.allocator);

        const summary = engine.mcp.collaboration.buildSummaryAlloc(std.heap.page_allocator, response) catch
            try std.heap.page_allocator.dupe(u8, i18n.text(language, .ai_chat_collaboration_tool_ok));
        var result: AsyncResult = .{
            .role = .assistant,
            .text = summary,
            .snapshot_dirty = switch (response.outcome) {
                .applied => |result| result.had_transaction,
                else => false,
            },
        };
        if (result.snapshot_dirty) {
            result.timeline_event = try makeAiTimelineEventAlloc(language, tool_name, arguments_value, summary);
        }
        return result;
    }

    const bridge = tool_bridge orelse {
        return .{
            .role = .system,
            .text = try std.heap.page_allocator.dupe(u8, i18n.text(language, .ai_chat_disconnected)),
        };
    };
    var response = bridge.submitJsonWithMeta(tool_name, arguments_value, &tool_meta) catch |err| {
        return .{
            .role = .system,
            .text = try allocMessage(
                "{s}: {s}",
                .{ i18n.text(language, .ai_chat_tool_call_failed_fallback), @errorName(err) },
                i18n.text(language, .ai_chat_tool_call_failed_fallback),
            ),
        };
    };
    defer response.deinit(bridge.allocator);

    const summary = engine.mcp.tools.buildSummaryAlloc(std.heap.page_allocator, response) catch
        try std.heap.page_allocator.dupe(u8, i18n.text(language, .ai_chat_tool_ok));
    var result: AsyncResult = .{
        .role = .assistant,
        .text = summary,
        .snapshot_dirty = switch (response.result.kind) {
            .command => response.result.changed,
            .compile_script, .compile_editor_utility => true,
            .screenshot, .query => false,
        },
    };
    if (result.snapshot_dirty) {
        result.timeline_event = try makeAiTimelineEventAlloc(language, tool_name, arguments_value, summary);
    }
    return result;
}

fn executePromptIntentAsync(task: *const AsyncTaskContext) !AsyncResult {
    const prompt = task.prompt orelse "";
    touchImplicitContext(task.snapshot_store);

    var completion = requestProviderCompletionAlloc(task, prompt) catch |err| {
        return .{
            .role = .system,
            .text = i18n.allocPrintMessage(
                .ai_chat_provider_request_failed_error_fmt,
                std.heap.page_allocator,
                task.language,
                .{@errorName(err)},
            ) catch try std.heap.page_allocator.dupe(
                u8,
                i18n.text(task.language, .ai_chat_provider_request_failed_fallback),
            ),
        };
    };
    defer completion.deinit(std.heap.page_allocator);

    const reasoning_copy = if (completion.reasoning) |value|
        try std.heap.page_allocator.dupe(u8, value)
    else
        null;
    errdefer if (reasoning_copy) |value| std.heap.page_allocator.free(value);

    const trimmed_completion = std.mem.trim(u8, completion.content, " \t\r\n");
    if (trimmed_completion.len == 0) {
        ai_chat_log.warn("Provider returned empty final content for prompt intent", .{});
        return .{
            .role = .system,
            .text = try std.heap.page_allocator.dupe(u8, i18n.text(task.language, .ai_chat_provider_no_final_content)),
            .reasoning = reasoning_copy,
        };
    }

    var decision = try parseLlmDecisionAlloc(completion.content);
    defer decision.deinit(std.heap.page_allocator);

    return switch (decision) {
        .tool_call => |tool_call| blk: {
            ai_chat_log.info("Parsed AI tool call: tool={s} args={s}", .{
                tool_call.tool_name,
                if (tool_call.arguments_json) |arguments_json| clipped(arguments_json, 320) else "{}",
            });
            var result = try executeToolCallAsync(
                task.language,
                task.tool_bridge,
                task.collaboration_bridge,
                tool_call.tool_name,
                if (tool_call.arguments_json) |arguments_json| arguments_json else "",
                &task.command_meta,
            );
            result.reasoning = reasoning_copy;
            break :blk result;
        },
        .message => |message| .{
            .reasoning = reasoning_copy,
            .role = if (std.mem.startsWith(u8, std.mem.trim(u8, message, " \t\r\n"), "Provider request failed"))
                .system
            else
                .assistant,
            .text = try std.heap.page_allocator.dupe(u8, message),
        },
    };
}

fn runAsyncTaskMain(context: ?*anyopaque) void {
    const raw = context orelse {
        asyncFinishWithoutResult();
        return;
    };
    const task: *AsyncTaskContext = @ptrCast(@alignCast(raw));
    defer {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
    }

    const result = switch (task.kind) {
        .tool_command => executeToolCallAsync(
            task.language,
            task.tool_bridge,
            task.collaboration_bridge,
            task.tool_name orelse "",
            task.raw_arguments orelse "",
            &task.command_meta,
        ) catch |err| blk: {
            const text = allocMessage("AI background task failed: {s}", .{@errorName(err)}, "AI background task failed.") catch {
                asyncFinishWithoutResult();
                return;
            };
            break :blk AsyncResult{ .role = .system, .text = text };
        },
        .prompt_intent => executePromptIntentAsync(task) catch |err| blk: {
            const text = allocMessage("AI intent parse failed: {s}", .{@errorName(err)}, "AI intent parse failed.") catch {
                asyncFinishWithoutResult();
                return;
            };
            break :blk AsyncResult{ .role = .system, .text = text };
        },
    };
    asyncPublishResult(result);
}

fn runAsyncTaskCleanup(context: ?*anyopaque) void {
    if (context) |raw| {
        const task: *AsyncTaskContext = @ptrCast(@alignCast(raw));
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
    }
    asyncFinishWithoutResult();
}

fn startAsyncTask(layer_context: *engine.core.LayerContext, task: *AsyncTaskContext) bool {
    const job_system = layer_context.world.job_system orelse {
        ai_chat_log.warn("failed to start async task: no job system", .{});
        return false;
    };
    if (!asyncTryBegin()) {
        ai_chat_log.warn("failed to start async task: another task is already running", .{});
        return false;
    }

    var handle = job_system.enqueueWithCleanup(
        runAsyncTaskMain,
        task,
        runAsyncTaskCleanup,
        .normal,
    ) catch {
        ai_chat_log.warn("failed to enqueue async task", .{});
        asyncFinishWithoutResult();
        return false;
    };
    ai_chat_log.info("Async task started: kind={s}", .{@tagName(task.kind)});
    handle.deinit();
    return true;
}

fn pumpAsyncResults(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (asyncTakeStreamPreview()) |preview| {
        g_stream_preview = preview;
        if (preview.hasVisibleContent()) {
            g_scroll_to_bottom = true;
        }
    }

    var maybe_result = asyncTakeResult();
    if (maybe_result) |*result| {
        defer result.deinit(std.heap.page_allocator);
        g_stream_preview = .{};
        if (result.reasoning) |reasoning| {
            appendMessage(.reasoning, reasoning);
        }
        switch (result.role) {
            .assistant => appendMessage(.assistant, result.text),
            .system => appendMessage(.system, result.text),
        }
        if (result.snapshot_dirty) {
            if (result.timeline_event) |*event| {
                recordAiTimelineEvent(state, layer_context, event);
            } else {
                history.captureSnapshotWithSource(state, layer_context, .ai) catch |err| {
                    ai_chat_log.warn("failed to capture AI snapshot history: {s}", .{@errorName(err)});
                };
            }
            refreshMcpSnapshot(state, layer_context);
        }
    }
}

const ToolCommand = struct {
    name: []const u8,
    raw_arguments: []const u8,
};

fn parseToolCommand(input: []const u8) ?ToolCommand {
    if (!std.mem.startsWith(u8, input, "/mcp")) {
        return null;
    }

    var rest = std.mem.trimLeft(u8, input["/mcp".len..], " \t");
    if (rest.len == 0) {
        return null;
    }
    const tool_end = std.mem.indexOfAny(u8, rest, " \t");
    if (tool_end) |index| {
        return .{
            .name = rest[0..index],
            .raw_arguments = std.mem.trim(u8, rest[index..], " \t"),
        };
    }
    return .{
        .name = rest,
        .raw_arguments = "",
    };
}

fn refreshMcpSnapshot(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const store = state.ai_snapshot_store orelse return;
    layer_context.world.updateHierarchy();
    store.replaceFromRenderer(layer_context.world, layer_context.renderer) catch |err| {
        ai_chat_log.warn("failed to refresh MCP snapshot after chat tool call: {s}", .{@errorName(err)});
    };
}

fn handleMcpToolCommandImmediate(state: *EditorState, layer_context: *engine.core.LayerContext, command: ToolCommand) bool {
    if (command.name.len == 0) {
        appendMessage(.system, state.text(.ai_chat_missing_tool_name_example));
        return true;
    }

    var parsed_args: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_args) |*parsed| parsed.deinit();

    const args_value: ?std.json.Value = blk: {
        if (command.raw_arguments.len == 0) {
            break :blk null;
        }
        parsed_args = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, command.raw_arguments, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            appendMessage(.system, state.text(.ai_chat_json_parse_failed_example));
            return true;
        };
        break :blk parsed_args.?.value;
    };

    var command_meta = buildAiCommandMetaAlloc(
        std.heap.page_allocator,
        command.name,
        layer_context.world.sceneRevision(),
    ) catch {
        appendMessage(.system, state.text(.ai_chat_meta_alloc_failed));
        return true;
    };
    defer command_meta.deinit(std.heap.page_allocator);

    if (engine.mcp.collaboration.isToolName(command.name)) {
        const bridge = state.ai_collaboration_bridge orelse {
            appendMessage(.system, state.text(.ai_chat_disconnected));
            return true;
        };
        var outcome = bridge.executeJsonImmediateWithMeta(layer_context, command.name, args_value, &command_meta) catch |err| {
            var message_buffer: [160]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s}: {s}",
                .{ state.text(.ai_chat_collaboration_tool_call_failed_fallback), @errorName(err) },
            ) catch state.text(.ai_chat_collaboration_tool_call_failed_fallback);
            appendMessage(.system, message);
            return true;
        };
        defer outcome.response.deinit(bridge.allocator);

        const summary = engine.mcp.collaboration.buildSummaryAlloc(std.heap.page_allocator, outcome.response) catch null;
        if (summary) |resolved_summary| {
            defer std.heap.page_allocator.free(resolved_summary);
            appendMessage(.assistant, resolved_summary);
            if (outcome.world_changed) {
                var event = makeAiTimelineEventAlloc(state.language, command.name, args_value, resolved_summary) catch null;
                if (event) |*resolved_event| {
                    defer resolved_event.deinit(std.heap.page_allocator);
                    recordAiTimelineEvent(state, layer_context, resolved_event);
                } else {
                    history.captureSnapshotWithSource(state, layer_context, .ai) catch |err| {
                        ai_chat_log.warn("failed to capture AI snapshot history: {s}", .{@errorName(err)});
                    };
                }
            }
        } else {
            appendMessage(.assistant, state.text(.ai_chat_collaboration_tool_ok));
            if (outcome.world_changed) {
                var event = makeAiTimelineEventAlloc(state.language, command.name, args_value, "") catch null;
                if (event) |*resolved_event| {
                    defer resolved_event.deinit(std.heap.page_allocator);
                    recordAiTimelineEvent(state, layer_context, resolved_event);
                } else {
                    history.captureSnapshotWithSource(state, layer_context, .ai) catch |err| {
                        ai_chat_log.warn("failed to capture AI snapshot history: {s}", .{@errorName(err)});
                    };
                }
            }
        }

        if (outcome.world_changed) {
            refreshMcpSnapshot(state, layer_context);
        }
        return true;
    }

    const bridge = state.ai_tool_bridge orelse {
        appendMessage(.system, state.text(.ai_chat_disconnected));
        return true;
    };
    var outcome = bridge.executeJsonImmediateWithMeta(layer_context, command.name, args_value, &command_meta) catch |err| {
        var message_buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "{s}: {s}",
            .{ state.text(.ai_chat_tool_call_failed_fallback), @errorName(err) },
        ) catch state.text(.ai_chat_tool_call_failed_fallback);
        appendMessage(.system, message);
        return true;
    };
    defer outcome.response.deinit(bridge.allocator);

    const summary = engine.mcp.tools.buildSummaryAlloc(std.heap.page_allocator, outcome.response) catch null;
    if (summary) |resolved_summary| {
        defer std.heap.page_allocator.free(resolved_summary);
        appendMessage(.assistant, resolved_summary);
        if (outcome.snapshot_dirty) {
            var event = makeAiTimelineEventAlloc(state.language, command.name, args_value, resolved_summary) catch null;
            if (event) |*resolved_event| {
                defer resolved_event.deinit(std.heap.page_allocator);
                recordAiTimelineEvent(state, layer_context, resolved_event);
            } else {
                history.captureSnapshotWithSource(state, layer_context, .ai) catch |err| {
                    ai_chat_log.warn("failed to capture AI snapshot history: {s}", .{@errorName(err)});
                };
            }
        }
    } else {
        appendMessage(.assistant, state.text(.ai_chat_tool_ok));
        if (outcome.snapshot_dirty) {
            var event = makeAiTimelineEventAlloc(state.language, command.name, args_value, "") catch null;
            if (event) |*resolved_event| {
                defer resolved_event.deinit(std.heap.page_allocator);
                recordAiTimelineEvent(state, layer_context, resolved_event);
            } else {
                history.captureSnapshotWithSource(state, layer_context, .ai) catch |err| {
                    ai_chat_log.warn("failed to capture AI snapshot history: {s}", .{@errorName(err)});
                };
            }
        }
    }

    if (outcome.snapshot_dirty) {
        refreshMcpSnapshot(state, layer_context);
    }
    return true;
}

fn enqueueToolCommand(state: *EditorState, layer_context: *engine.core.LayerContext, command: ToolCommand) bool {
    if (command.name.len == 0) {
        appendMessage(.system, state.text(.ai_chat_missing_tool_name_example));
        return true;
    }

    const task = std.heap.page_allocator.create(AsyncTaskContext) catch {
        appendMessage(.system, state.text(.ai_chat_failed_create_background_task));
        return false;
    };
    task.* = .{
        .kind = .tool_command,
        .language = state.language,
        .tool_bridge = state.ai_tool_bridge,
        .collaboration_bridge = state.ai_collaboration_bridge,
        .snapshot_store = state.ai_snapshot_store,
    };
    task.tool_name = std.heap.page_allocator.dupe(u8, command.name) catch {
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_tool_name));
        return false;
    };
    task.raw_arguments = std.heap.page_allocator.dupe(u8, command.raw_arguments) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_arguments));
        return false;
    };
    task.command_meta = buildAiCommandMetaAlloc(
        std.heap.page_allocator,
        command.name,
        layer_context.world.sceneRevision(),
    ) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_meta_alloc_failed));
        return false;
    };

    if (!startAsyncTask(layer_context, task)) {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_create_background_task));
        return false;
    }
    return true;
}

fn enqueuePromptIntent(state: *EditorState, layer_context: *engine.core.LayerContext, input_text: []const u8) bool {
    applyProviderDefaults(state);
    if (activeProviderValidationError(state)) |validation_error| {
        const validation_error_text = providerValidationErrorText(state, validation_error);
        var message_buffer: [384]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "{s} {s} ({s})",
            .{
                state.text(.ai_chat_provider_setup_incomplete_prefix),
                state.text(.ai_chat_provider_setup_open_config_hint),
                validation_error_text,
            },
        ) catch state.text(.ai_chat_provider_setup_incomplete_prefix);
        appendMessage(.system, message);
        state.ai_provider_settings_open = true;
        requestAiFocus(.provider_name);
        return false;
    }
    const provider = &state.ai_providers[state.ai_active_provider];
    const endpoint = fixedBufferSlice(provider.endpoint[0..]);
    const model = fixedBufferSlice(provider.model[0..]);
    const api_key = fixedBufferSlice(provider.api_key[0..]);

    const task = std.heap.page_allocator.create(AsyncTaskContext) catch {
        appendMessage(.system, state.text(.ai_chat_failed_create_background_task));
        return false;
    };
    task.* = .{
        .kind = .prompt_intent,
        .language = state.language,
        .provider_type = provider_support.activeProviderType(state),
        .tool_bridge = state.ai_tool_bridge,
        .collaboration_bridge = state.ai_collaboration_bridge,
        .snapshot_store = state.ai_snapshot_store,
    };

    task.prompt = std.heap.page_allocator.dupe(u8, input_text) catch {
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_input));
        return false;
    };
    task.provider_endpoint = std.heap.page_allocator.dupe(u8, endpoint) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_endpoint));
        return false;
    };
    task.provider_model = std.heap.page_allocator.dupe(u8, model) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_model));
        return false;
    };
    task.provider_api_key = std.heap.page_allocator.dupe(u8, api_key) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_api_key));
        return false;
    };
    task.command_meta = buildAiCommandMetaAlloc(
        std.heap.page_allocator,
        null,
        layer_context.world.sceneRevision(),
    ) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_meta_alloc_failed));
        return false;
    };

    if (!startAsyncTask(layer_context, task)) {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_create_background_task));
        return false;
    }
    return true;
}

fn submitInput(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    pumpAsyncResults(state, layer_context);

    if (asyncIsRunning()) {
        appendMessage(.system, state.text(.ai_chat_previous_request_running));
        return;
    }

    const input_len = std.mem.indexOfScalar(u8, &g_input_buffer, 0) orelse max_input_len;
    if (input_len == 0) return;

    const input_text = std.mem.trim(u8, g_input_buffer[0..input_len], " \t\r\n");
    if (input_text.len == 0) {
        @memset(&g_input_buffer, 0);
        return;
    }
    ai_chat_log.info("User input: {s}", .{input_text});
    appendMessage(.user, input_text);

    if (parseToolCommand(input_text)) |command| {
        refreshMcpSnapshot(state, layer_context);
        if (!enqueueToolCommand(state, layer_context, command)) {
            _ = handleMcpToolCommandImmediate(state, layer_context, command);
        }
    } else if (isMcpBridgeReady(state)) {
        const store = state.ai_collaboration.?;
        store.recordIntent(.human, "chat_prompt", input_text) catch {};
        refreshMcpSnapshot(state, layer_context);
        _ = enqueuePromptIntent(state, layer_context, input_text);
    } else {
        appendMessage(.system, state.text(.ai_chat_mcp_local_bridge_not_ready));
    }

    @memset(&g_input_buffer, 0);
}

const StatusChipPalette = theme.ChipPalette;

fn drawStatusDot(id: u64, color: [4]f32) void {
    gui.pushIdU64(id);
    defer gui.popId();

    gui.pushStyleColor(.button, color);
    gui.pushStyleColor(.button_hovered, color);
    gui.pushStyleColor(.button_active, color);
    gui.pushStyleColor(.border, theme.transparent);
    gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.pill);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(4);
    }

    _ = gui.buttonEx("##status_dot", 10.0, 10.0);
    gui.sameLine();
}

fn drawStatusChip(label: []const u8, palette: StatusChipPalette) void {
    const text_size = gui.calcTextSize(label, false, 0.0);
    const chip_width = text_size[0] + 22.0;

    gui.pushStyleColor(.button, palette.background);
    gui.pushStyleColor(.button_hovered, palette.background);
    gui.pushStyleColor(.button_active, palette.background);
    gui.pushStyleColor(.border, palette.border);
    gui.pushStyleColor(.text, palette.text);
    gui.pushStyleVarVec2(.frame_padding, theme.Spacing.ai_chat_chip_padding);
    gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.pill);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(5);
    }

    _ = gui.buttonEx(label, chip_width, 0.0);
}

fn chatHasVisibleContent(preview: *const StreamState) bool {
    for (g_messages[0..g_message_count]) |msg| {
        if (msg.text_len != 0) return true;
    }
    return preview.hasVisibleContent();
}

fn drawProviderSetupGuideCard(state: *EditorState) void {
    const provider_error = activeProviderValidationError(state) orelse {
        gui.pushStyleColor(.text, theme.Palette.ai_chat.empty_text);
        gui.textWrapped(state.text(.ai_chat_empty));
        gui.popStyleColor(1);
        return;
    };

    const card_height: f32 = 208.0;
    gui.pushStyleColor(.border, theme.Palette.ai_chat.setup_card_border);
    gui.pushStyleVarVec2(.window_padding, theme.Spacing.ai_chat_setup_padding);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(1);
    }

    _ = gui.beginChild("ai_provider_setup_guide##jt", 0.0, card_height, true);
    defer gui.endChild();
    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    gui.pushStyleColor(.text, theme.Palette.ai_chat.setup_title);
    gui.text(state.text(.ai_chat_provider_not_configured));
    gui.popStyleColor(1);

    gui.dummy(0.0, 6.0);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.setup_body);
    gui.textWrapped(state.text(.ai_chat_provider_setup_incomplete_prefix));
    gui.popStyleColor(1);

    gui.dummy(0.0, 4.0);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.setup_hint);
    gui.textWrapped(providerValidationErrorText(state, provider_error));
    gui.popStyleColor(1);

    gui.dummy(0.0, 8.0);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.setup_hint);
    gui.textWrapped(state.text(.ai_chat_provider_setup_open_config_hint));
    gui.popStyleColor(1);

    gui.dummy(0.0, 18.0);
    gui.pushStyleColor(.button, theme.Palette.ai_chat.primary_button_strong.bg);
    gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.primary_button_strong.hovered);
    gui.pushStyleColor(.button_active, theme.Palette.ai_chat.primary_button_strong.active);
    if (gui.buttonEx(state.text(.ai_chat_configure), 120.0, 34.0)) {
        state.ai_provider_settings_open = true;
        requestAiFocus(.provider_name);
    }
    gui.popStyleColor(3);
}

fn providerFeedbackColor(kind: ProviderPanelFeedbackKind) [4]f32 {
    return switch (kind) {
        .success => theme.Palette.ai_chat.status_dot_ready,
        .failure => theme.Palette.ai_chat.status_dot_error,
        .none => theme.Palette.text_secondary,
    };
}

fn drawHeaderBar(state: *EditorState) void {
    const mcp_ready = isMcpBridgeReady(state);
    const provider_error = activeProviderValidationError(state);
    const provider_ready = provider_error == null;
    const header_height: f32 = if (provider_error != null) 136.0 else 106.0;
    gui.pushStyleColor(.border, theme.Palette.ai_chat.card_border);
    gui.pushStyleVarVec2(.window_padding, theme.Spacing.ai_chat_message_padding);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(1);
    }

    _ = gui.beginChild("ai_header_card##jt", 0.0, header_height, true);
    defer gui.endChild();
    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    drawStatusChip(
        if (mcp_ready) state.text(.ai_chat_mcp_ready_builtin) else state.text(.ai_chat_mcp_not_ready),
        if (mcp_ready) theme.Palette.ai_chat.status_ready else theme.Palette.ai_chat.status_error,
    );

    gui.sameLine();
    drawStatusChip(
        if (provider_ready) state.text(.ai_chat_provider_configured) else state.text(.ai_chat_provider_not_configured),
        if (provider_ready) theme.Palette.ai_chat.status_ready else theme.Palette.ai_chat.status_warning,
    );

    if (mcp_ready and provider_ready) {
        if (state.ai_collaboration) |store| {
            gui.sameLine();
            if (asyncIsRunning()) {
                drawStatusChip(
                    state.text(.ai_chat_running),
                    theme.Palette.ai_chat.status_warning,
                );
            } else {
                const ai_status = store.aiStatusSnapshot();
                const stage_label = switch (ai_status.stage) {
                    .ready => state.text(.ai_chat_stage_ready),
                    .analyzing_screenshot => state.text(.ai_chat_stage_analyzing_screenshot),
                    .compiling_shader => state.text(.ai_chat_stage_compiling_shader),
                    .waiting_approval => state.text(.ai_chat_stage_waiting_approval),
                };
                const stage_palette: StatusChipPalette = switch (ai_status.stage) {
                    .ready => theme.Palette.ai_chat.status_neutral,
                    .analyzing_screenshot, .compiling_shader => theme.Palette.ai_chat.status_warning,
                    .waiting_approval => theme.Palette.ai_chat.status_waiting,
                };
                drawStatusChip(stage_label, stage_palette);
            }
        }
    }

    gui.dummy(0.0, 10.0);
    if (provider_error) |validation_error| {
        gui.pushStyleColor(.text, theme.Palette.ai_chat.provider_error_text);
        gui.textWrapped(providerValidationErrorText(state, validation_error));
        gui.popStyleColor(1);
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    const clear_w: f32 = 52.0;
    const config_w: f32 = 62.0;
    const btn_gap: f32 = 6.0;
    const total_btns = clear_w + config_w + btn_gap;
    if (gui.contentRegionAvail()[0] > total_btns + 8.0) {
        gui.sameLineEx(@max(0.0, gui.contentRegionAvail()[0] - total_btns), 0.0);
        gui.pushStyleColor(.button, theme.Palette.ai_chat.secondary_header_button.bg);
        gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.secondary_header_button.hovered);
        gui.pushStyleColor(.button_active, theme.Palette.ai_chat.secondary_header_button.active);
        if (gui.buttonEx(state.text(.ai_chat_clear), clear_w, 30.0)) {
            clearHistory();
        }
        gui.sameLine();
        if (gui.buttonEx(state.text(.ai_chat_configure), config_w, 30.0)) {
            state.ai_provider_settings_open = !state.ai_provider_settings_open;
            requestAiFocus(if (state.ai_provider_settings_open) .provider_name else .chat_input);
            ai_chat_log.info("Provider settings panel toggled: {s}", .{if (state.ai_provider_settings_open) "open" else "closed"});
        }
        gui.popStyleColor(3);
    }
}

fn drawStagedTransactionBanner(state: *EditorState) void {
    const store = state.ai_collaboration orelse return;
    const ai_status = store.aiStatusSnapshot();
    if (ai_status.stage != .waiting_approval) return;

    gui.dummy(0.0, 2.0);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.staged_banner_text);
    gui.text(state.text(.ai_chat_staged_banner));
    gui.popStyleColor(1);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.staged_banner_hint);
    gui.text(state.text(.ai_chat_staged_hint));
    gui.popStyleColor(1);
    gui.dummy(0.0, 2.0);
}

fn drawStageDetail(state: *EditorState) void {
    if (asyncIsRunning()) {
        gui.pushStyleColor(.text, theme.Palette.ai_chat.stage_detail_text);
        gui.textWrapped(state.text(.ai_chat_background_job_running));
        gui.popStyleColor(1);
        return;
    }

    const store = state.ai_collaboration orelse return;
    const ai_status = store.aiStatusSnapshot();
    if (ai_status.stage == .ready) return;

    const detail = if (ai_status.detail.len > 0)
        ai_status.detail.slice()
    else
        return;

    ai_chat_log.debug("AI stage detail: {s}", .{detail});
    gui.pushStyleColor(.text, theme.Palette.ai_chat.stage_detail_text);
    gui.textWrapped(detail);
    gui.popStyleColor(1);
}

fn drawMessages(state: *EditorState) void {
    chat_view.drawMessages(state, g_messages[0..], g_message_count, &g_stream_preview);
}

const provider_action_icon_size: f32 = 16.0;

fn providerActionPalette(enabled: bool) ui_icons.ButtonPalette {
    if (!enabled) {
        return .{
            .button = theme.Palette.ai_chat.provider_action_disabled.bg,
            .hovered = theme.Palette.ai_chat.provider_action_disabled.hovered,
            .active = theme.Palette.ai_chat.provider_action_disabled.active,
        };
    }
    return .{
        .button = theme.Palette.ai_chat.provider_action_enabled.bg,
        .hovered = theme.Palette.ai_chat.provider_action_enabled.hovered,
        .active = theme.Palette.ai_chat.provider_action_enabled.active,
    };
}

fn providerActionTint(enabled: bool) [4]u8 {
    if (!enabled) return .{ 110, 115, 124, 255 };
    return .{ 220, 228, 236, 255 };
}

fn drawProviderActionIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    enabled: bool,
) !bool {
    const clicked = try ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        provider_action_icon_size,
        providerActionTint(enabled),
        providerActionPalette(enabled),
    );
    return clicked and enabled;
}

fn pushAiInputWidgetStyle() void {
    gui.pushStyleColor(.frame_bg, theme.Palette.ai_chat.input_frame_bg);
    gui.pushStyleColor(.frame_bg_hovered, theme.Palette.ai_chat.input_frame_hovered);
    gui.pushStyleColor(.frame_bg_active, theme.Palette.ai_chat.input_frame_active);
    gui.pushStyleColor(.border, theme.Palette.ai_chat.input_border);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.input_text);
    gui.pushStyleColor(.input_text_cursor, theme.Palette.ai_chat.input_text_cursor);
    gui.pushStyleColor(.nav_cursor, theme.Palette.ai_chat.input_nav_cursor);
    gui.pushStyleColor(.text_selected_bg, theme.Palette.ai_chat.input_text_selected_bg);
    gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.ai_input);
}

fn popAiInputWidgetStyle() void {
    gui.popStyleVar(1);
    gui.popStyleColor(8);
}

fn inputTextWithHintStyledFlags(label: []const u8, hint: []const u8, buffer: []u8, flags: u32) bool {
    pushAiInputWidgetStyle();
    defer popAiInputWidgetStyle();
    return gui.inputTextWithHintFlags(label, hint, buffer, flags);
}

fn inputTextWithHintStyled(label: []const u8, hint: []const u8, buffer: []u8) bool {
    return inputTextWithHintStyledFlags(label, hint, buffer, gui.InputTextFlags.none);
}

fn inputTextPasswordStyled(label: []const u8, buffer: []u8) bool {
    pushAiInputWidgetStyle();
    defer popAiInputWidgetStyle();
    return gui.inputTextPassword(label, buffer);
}

fn inputTextMultilineStyled(label: []const u8, buffer: []u8, width: f32, height: f32) bool {
    pushAiInputWidgetStyle();
    defer popAiInputWidgetStyle();
    return gui.inputTextMultiline(label, buffer, width, height);
}

fn drawProviderSettings(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.ai_provider_settings_open) return;
    var provider_prefs_dirty = false;

    gui.separator();
    const settings_height = gui.contentRegionAvail()[1];
    gui.pushStyleColor(.border, theme.Palette.ai_chat.card_border);
    _ = gui.beginChild("ai_provider_settings##jt", 0.0, settings_height, true);
    defer {
        gui.endChild();
        gui.popStyleColor(1);
    }
    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    const content_width = gui.contentRegionAvail()[0];
    const form_width = @min(content_width, 820.0);
    const side_padding = @max(0.0, (content_width - form_width) * 0.5);
    if (side_padding > 0.0) gui.indent(side_padding);
    defer if (side_padding > 0.0) gui.unindent(side_padding);

    gui.pushStyleColor(.text, theme.Palette.ai_chat.settings_title);
    gui.text(state.text(.ai_chat_provider_settings_title));
    gui.popStyleColor(1);
    gui.pushStyleColor(.text, theme.Palette.ai_chat.settings_description);
    gui.textWrapped(state.text(.ai_chat_provider_settings_desc));
    gui.popStyleColor(1);
    gui.dummy(0.0, 8.0);

    const mcp_ready = isMcpBridgeReady(state);
    const provider_error = activeProviderValidationError(state);
    const provider_ready = provider_error == null;

    drawStatusDot(1, if (mcp_ready) theme.Palette.ai_chat.status_dot_ready else theme.Palette.ai_chat.status_dot_error);
    gui.pushStyleColor(.text, if (mcp_ready) theme.Palette.ai_chat.status_ready.text else theme.Palette.ai_chat.status_error.text);
    gui.text(if (mcp_ready) state.text(.ai_chat_provider_status_ready_builtin) else state.text(.ai_chat_provider_status_not_ready));
    gui.popStyleColor(1);

    drawStatusDot(2, if (provider_ready) theme.Palette.ai_chat.status_dot_ready else theme.Palette.ai_chat.status_dot_warning);
    gui.pushStyleColor(.text, if (provider_ready) theme.Palette.ai_chat.status_ready.text else theme.Palette.ai_chat.status_warning.text);
    gui.text(if (provider_ready) state.text(.ai_chat_provider_status_configured) else state.text(.ai_chat_provider_not_configured));
    gui.popStyleColor(1);
    if (provider_error) |validation_error| {
        gui.sameLine();
        gui.pushStyleColor(.text, theme.Palette.ai_chat.settings_description);
        gui.text(providerValidationErrorText(state, validation_error));
        gui.popStyleColor(1);
    }

    gui.dummy(0.0, 10.0);
    gui.pushIdU64(@intCast(state.ai_active_provider));
    defer gui.popId();

    const action_gap: f32 = 6.0;
    const action_btn_span = provider_action_icon_size + ui_icons.compact_icon_button_padding[0] * 2.0;
    const type_popup_id = "ai_provider_type_popup##jt";
    const provider_popup_id = "ai_provider_select_popup##jt";
    const active_type = provider_support.activeProviderType(state);

    if (layout.beginInspectorPropertyTable("ai_provider_config_grid##jt", 0.28)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow(state.text(.ai_chat_type), null);
        {
            const cell_width = gui.contentRegionAvail()[0];
            const preview_width = @max(140.0, cell_width - action_btn_span - action_gap);

            var type_preview_label_buffer: [96]u8 = undefined;
            const type_preview_label = std.fmt.bufPrint(
                &type_preview_label_buffer,
                "{s}##ai_provider_type_preview",
                .{providerTypeText(state, active_type)},
            ) catch "##ai_provider_type_preview";

            gui.pushStyleColor(.button, theme.Palette.ai_chat.dropdown_button.bg);
            gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.dropdown_button.hovered);
            gui.pushStyleColor(.button_active, theme.Palette.ai_chat.dropdown_button.active);
            if (gui.buttonEx(type_preview_label, preview_width, 0.0)) {
                gui.openPopup(type_popup_id);
            }
            gui.popStyleColor(3);

            gui.sameLine();
            if (try drawProviderActionIconButton(
                state,
                layer_context,
                "ai_provider_type_open##jt",
                ui_icons.paths.toolbar.chevron_down,
                true,
            )) {
                gui.openPopup(type_popup_id);
            }

            if (gui.beginPopup(type_popup_id)) {
                defer gui.endPopup();
                for (provider_support.provider_types, 0..) |provider_type, i| {
                    gui.pushIdU64(@intCast(i));
                    defer gui.popId();
                    const is_selected = provider_type == active_type;
                    if (gui.selectable(providerTypeText(state, provider_type), is_selected, false, 0.0, 0.0)) {
                        provider_support.setActiveProviderType(state, provider_type);
                        applyProviderDefaults(state);
                        provider_prefs_dirty = true;
                        g_provider_feedback.clear();
                    }
                    if (is_selected) gui.setItemDefaultFocus();
                }
            }
        }

        layout.drawInspectorPropertyRow(state.text(.ai_chat_provider_list), null);
        {
            const cell_width = gui.contentRegionAvail()[0];
            const preview_width = @max(140.0, cell_width - action_btn_span * 3.0 - action_gap * 3.0);
            const active_provider = provider_support.activeProvider(state);
            var provider_preview_label_buffer: [160]u8 = undefined;
            const provider_preview_label = std.fmt.bufPrint(
                &provider_preview_label_buffer,
                "{s}##ai_provider_select_preview",
                .{providerDisplayNameForUi(state, active_provider)},
            ) catch "##ai_provider_select_preview";

            gui.pushStyleColor(.button, theme.Palette.ai_chat.dropdown_button.bg);
            gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.dropdown_button.hovered);
            gui.pushStyleColor(.button_active, theme.Palette.ai_chat.dropdown_button.active);
            if (gui.buttonEx(provider_preview_label, preview_width, 0.0)) {
                gui.openPopup(provider_popup_id);
            }
            gui.popStyleColor(3);

            gui.sameLine();
            if (try drawProviderActionIconButton(
                state,
                layer_context,
                "ai_provider_select_open##jt",
                ui_icons.paths.toolbar.chevron_down,
                true,
            )) {
                gui.openPopup(provider_popup_id);
            }
            gui.sameLine();
            if (try drawProviderActionIconButton(
                state,
                layer_context,
                "ai_provider_add##jt",
                ui_icons.paths.toolbar.plus,
                state.ai_provider_count < state.ai_providers.len,
            )) {
                if (state.ai_provider_count < state.ai_providers.len) {
                    const new_provider_index = state.ai_provider_count;
                    const current_type = provider_support.activeProviderType(state);
                    state.ai_providers[new_provider_index] = .{};
                    state.ai_providers[new_provider_index].provider_type = current_type;

                    const allocated_default_name = nextGeneratedProviderNameAlloc(state) catch null;
                    const default_name = allocated_default_name orelse state.text(.ai_chat_provider_default_name);
                    defer if (allocated_default_name) |value| std.heap.page_allocator.free(value);
                    provider_support.writeFixedBuffer(state.ai_providers[new_provider_index].name[0..], default_name);

                    state.ai_provider_count += 1;
                    state.ai_active_provider = new_provider_index;
                    provider_support.syncActiveProviderType(state);
                    applyProviderDefaults(state);
                    provider_prefs_dirty = true;
                    g_provider_feedback.clear();
                    requestAiFocus(.provider_name);
                }
            }
            gui.sameLine();
            const can_delete = state.ai_provider_count > 1;
            if (try drawProviderActionIconButton(
                state,
                layer_context,
                "ai_provider_delete##jt",
                ui_icons.paths.toolbar.x_mark,
                can_delete,
            )) {
                if (can_delete) {
                    var i = state.ai_active_provider;
                    while (i + 1 < state.ai_provider_count) : (i += 1) {
                        state.ai_providers[i] = state.ai_providers[i + 1];
                    }
                    state.ai_provider_count -= 1;
                    if (state.ai_active_provider >= state.ai_provider_count) {
                        state.ai_active_provider = state.ai_provider_count - 1;
                    }
                    provider_support.syncActiveProviderType(state);
                    provider_prefs_dirty = true;
                    g_provider_feedback.clear();
                }
            }

            if (gui.beginPopup(provider_popup_id)) {
                defer gui.endPopup();
                for (0..state.ai_provider_count) |provider_index| {
                    gui.pushIdU64(@intCast(provider_index));
                    defer gui.popId();
                    const is_selected = provider_index == state.ai_active_provider;
                    const provider_item = &state.ai_providers[provider_index];
                    if (gui.selectable(providerDisplayNameForUi(state, provider_item), is_selected, false, 0.0, 0.0)) {
                        state.ai_active_provider = provider_index;
                        provider_support.syncActiveProviderType(state);
                        applyProviderDefaults(state);
                        provider_prefs_dirty = true;
                        g_provider_feedback.clear();
                    }
                    if (is_selected) gui.setItemDefaultFocus();
                }
            }
        }

        const provider = provider_support.activeProviderMut(state);

        layout.drawInspectorPropertyRow(state.text(.ai_chat_display_name), null);
        applyAiFocusIfRequested(.provider_name);
        if (inputTextWithHintStyled("##name", state.text(.ai_chat_hint_provider_name), provider.name[0..])) {
            provider_prefs_dirty = true;
        }
        requestAiFocusIfClicked(layer_context, .provider_name);

        layout.drawInspectorPropertyRow(state.text(.ai_chat_api_endpoint), null);
        applyAiFocusIfRequested(.provider_endpoint);
        if (inputTextWithHintStyled("##endpoint", state.text(.ai_chat_hint_endpoint), provider.endpoint[0..])) {
            provider_prefs_dirty = true;
        }
        requestAiFocusIfClicked(layer_context, .provider_endpoint);

        layout.drawInspectorPropertyRow(state.text(.ai_chat_model), null);
        applyAiFocusIfRequested(.provider_model);
        if (inputTextWithHintStyled("##model", state.text(.ai_chat_hint_model), provider.model[0..])) {
            provider_prefs_dirty = true;
        }
        requestAiFocusIfClicked(layer_context, .provider_model);

        layout.drawInspectorPropertyRow(state.text(.ai_chat_api_key), null);
        {
            const toggle_width: f32 = 54.0;
            const key_gap: f32 = 6.0;
            const field_width = @max(60.0, gui.contentRegionAvail()[0] - toggle_width - key_gap);
            gui.setNextItemWidth(field_width);
            applyAiFocusIfRequested(.provider_api_key);
            if (state.ai_provider_api_key_visible) {
                if (inputTextWithHintStyled("##apikey", state.text(.ai_chat_hint_api_key), provider.api_key[0..])) {
                    provider_prefs_dirty = true;
                }
            } else {
                if (inputTextPasswordStyled("##apikey", provider.api_key[0..])) {
                    provider_prefs_dirty = true;
                }
            }
            requestAiFocusIfClicked(layer_context, .provider_api_key);
            gui.sameLine();
            if (gui.buttonEx(
                if (state.ai_provider_api_key_visible) state.text(.ai_chat_hide) else state.text(.ai_chat_show),
                toggle_width,
                0.0,
            )) {
                state.ai_provider_api_key_visible = !state.ai_provider_api_key_visible;
                requestAiFocus(.provider_api_key);
            }
        }
    }

    gui.dummy(0.0, 12.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    const button_width: f32 = 96.0;
    const button_gap: f32 = 8.0;
    const action_row_width = button_width * 2.0 + button_gap;
    gui.sameLineEx(@max(0.0, form_width - action_row_width), 0.0);

    gui.pushStyleColor(.button, theme.Palette.ai_chat.primary_button.bg);
    gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.primary_button.hovered);
    gui.pushStyleColor(.button_active, theme.Palette.ai_chat.primary_button.active);
    if (gui.buttonEx(state.text(.ai_chat_apply_config), button_width, 0.0)) {
        applyProviderDefaults(state);
        logProviderConfig(state);
        if (activeProviderValidationError(state)) |validation_error| {
            const validation_error_text = providerValidationErrorText(state, validation_error);
            g_connection_error = validation_error_text;
            g_provider_feedback.set(.failure, validation_error_text);
            var message_buffer: [224]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s}: {s}",
                .{ state.text(.ai_chat_provider_apply_incomplete_fallback), validation_error_text },
            ) catch state.text(.ai_chat_provider_apply_incomplete_fallback);
            appendMessage(.system, message);
        } else {
            g_connection_error = null;
            preferences.saveAiProviderSettings(state) catch |err| {
                ai_chat_log.warn("failed to persist AI provider settings: {s}", .{@errorName(err)});
            };
            g_provider_feedback.set(.success, state.text(.ai_chat_provider_apply_success));
            appendMessage(.system, state.text(.ai_chat_provider_apply_success));
        }
    }
    gui.popStyleColor(3);

    gui.sameLine();
    gui.pushStyleColor(.button, theme.Palette.ai_chat.secondary_button.bg);
    gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.secondary_button.hovered);
    gui.pushStyleColor(.button_active, theme.Palette.ai_chat.secondary_button.active);
    if (gui.buttonEx(state.text(.ai_chat_test_connection), button_width, 0.0)) {
        const provider = provider_support.activeProvider(state);
        const provider_type = provider_support.activeProviderType(state);
        logProviderConfig(state);
        appendMessage(.system, state.text(.ai_chat_testing_connection));

        const endpoint = fixedBufferSlice(provider.endpoint[0..]);
        const model = fixedBufferSlice(provider.model[0..]);
        const api_key = fixedBufferSlice(provider.api_key[0..]);

        if (endpoint.len == 0) {
            g_provider_feedback.set(.failure, state.text(.ai_chat_error_input_endpoint));
            appendMessage(.system, state.text(.ai_chat_error_input_endpoint));
        } else if (model.len == 0) {
            g_provider_feedback.set(.failure, state.text(.ai_chat_error_input_model));
            appendMessage(.system, state.text(.ai_chat_error_input_model));
        } else if (provider_support.providerNeedsApiKey(provider_type) and api_key.len == 0) {
            g_provider_feedback.set(.failure, state.text(.ai_chat_error_input_api_key));
            appendMessage(.system, state.text(.ai_chat_error_input_api_key));
        } else {
            const summary = testHttpConnectionAlloc(state.language, provider_type, endpoint, api_key, model) catch |err| blk: {
                break :blk allocMessage(
                    "{s}: {s}",
                    .{ state.text(.ai_chat_connection_test_failed_fallback), @errorName(err) },
                    state.text(.ai_chat_connection_test_failed_fallback),
                ) catch null;
            };
            if (summary) |resolved_summary| {
                defer std.heap.page_allocator.free(resolved_summary);
                const is_failure = std.mem.startsWith(u8, resolved_summary, state.text(.ai_chat_provider_request_failed_fallback)) or
                    std.mem.startsWith(u8, resolved_summary, state.text(.ai_chat_connection_test_failed_fallback));
                g_provider_feedback.set(if (is_failure) .failure else .success, resolved_summary);
                appendMessage(.system, resolved_summary);
            } else {
                g_provider_feedback.set(.failure, state.text(.ai_chat_connection_test_failed_fallback));
                appendMessage(.system, state.text(.ai_chat_connection_test_failed_fallback));
            }
        }
    }
    gui.popStyleColor(3);

    if (g_provider_feedback.kind != .none) {
        gui.dummy(0.0, 8.0);
        gui.pushStyleColor(.text, providerFeedbackColor(g_provider_feedback.kind));
        gui.textWrapped(g_provider_feedback.slice());
        gui.popStyleColor(1);
    } else if (g_connection_error) |err| {
        gui.dummy(0.0, 8.0);
        gui.pushStyleColor(.text, theme.Palette.ai_chat.critical_text);
        gui.textWrapped(err);
        gui.popStyleColor(1);
    }

    if (provider_prefs_dirty) {
        g_connection_error = null;
        preferences.saveAiProviderSettings(state) catch |err| {
            ai_chat_log.warn("failed to auto-persist AI provider settings: {s}", .{@errorName(err)});
        };
    }
}

var g_window_initialized = false;
var g_prev_ai_chat_open = false;

const AiFocusTarget = enum {
    none,
    chat_input,
    provider_name,
    provider_endpoint,
    provider_model,
    provider_api_key,
};

var g_focus_target_next_frame: AiFocusTarget = .chat_input;

fn pointInRect(point: [2]f32, min: [2]f32, max: [2]f32) bool {
    return point[0] >= min[0] and point[0] <= max[0] and
        point[1] >= min[1] and point[1] <= max[1];
}

fn requestAiFocus(target: AiFocusTarget) void {
    g_focus_target_next_frame = target;
}

fn applyAiFocusIfRequested(target: AiFocusTarget) void {
    if (g_focus_target_next_frame != target) return;
    gui.setKeyboardFocusHere(0);
    g_focus_target_next_frame = .none;
}

fn requestAiFocusIfClicked(layer_context: *engine.core.LayerContext, target: AiFocusTarget) void {
    const clicked = layer_context.input.wasMousePressed(.left) and
        pointInRect(gui.mousePos(), gui.getItemRectMin(), gui.getItemRectMax());
    if (clicked and !gui.isItemActive()) {
        requestAiFocus(target);
    }
}

pub fn drawAiChatPanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    pumpAsyncResults(state, layer_context);
    if (!state.ai_chat_open) {
        g_prev_ai_chat_open = false;
        return;
    }

    if (!g_prev_ai_chat_open) requestAiFocus(.chat_input);
    g_prev_ai_chat_open = true;

    var window_title_buffer: [96]u8 = undefined;
    const window_title = state.windowLabel(&window_title_buffer, .ai_chat, "ai_chat_floating") catch "AI Assistant###ai_chat_floating";

    if (!g_window_initialized) {
        gui.setNextWindowPos(.{ 50.0, 100.0 });
        gui.setNextWindowSize(.{ 620.0, 700.0 });
        g_window_initialized = true;
    }
    gui.setNextWindowBgAlpha(1.0);

    const window_flags = gui.WindowFlags.no_docking;

    const open = gui.beginWindowFlags(window_title, window_flags);
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("ai_chat_floating");

    if (!open) return;
    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    drawHeaderBar(state);
    gui.dummy(0.0, 8.0);
    try drawProviderSettings(state, layer_context);
    if (state.ai_provider_settings_open) return;
    drawStagedTransactionBanner(state);
    drawStageDetail(state);

    const avail = gui.contentRegionAvail();
    const composer_height: f32 = 80.0;
    const messages_height = avail[1] - composer_height - 8.0;

    if (messages_height > 10.0) {
        gui.pushStyleColor(.border, theme.Palette.ai_chat.messages_border);
        _ = gui.beginChild("ai_messages##jt", 0.0, messages_height, true);
        defer {
            gui.endChild();
            gui.popStyleColor(1);
        }
        if (gui.isWindowHovered()) {
            state.viewport_overlay_hovered = true;
        }

        if (!chatHasVisibleContent(&g_stream_preview) and activeProviderValidationError(state) != null) {
            drawProviderSetupGuideCard(state);
        } else {
            drawMessages(state);
        }

        if (g_scroll_to_bottom) {
            gui.setScrollHereY(1.0);
            g_scroll_to_bottom = false;
        }
    }

    gui.dummy(0.0, 8.0);
    gui.pushStyleColor(.border, theme.Palette.ai_chat.composer_border);
    gui.pushStyleVarVec2(.window_padding, theme.Spacing.ai_chat_composer_padding);
    _ = gui.beginChild("ai_composer##jt", 0.0, composer_height, true);
    defer {
        gui.endChild();
        gui.popStyleVar(1);
        gui.popStyleColor(1);
    }
    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    const total_width = gui.contentRegionAvail()[0];
    const send_btn_width: f32 = 70.0;
    const input_width = total_width - send_btn_width - 6.0;
    const busy = asyncIsRunning();
    const input_height: f32 = 40.0;

    if (input_width > 30.0) {
        if (!busy) applyAiFocusIfRequested(.chat_input);
        gui.pushStyleColor(.text, theme.Palette.ai_chat.input_hint_text);
        gui.text(if (busy) state.text(.ai_chat_background_processing) else state.text(.ai_chat_input_hint));
        gui.popStyleColor(1);
        gui.dummy(0.0, 4.0);

        _ = inputTextMultilineStyled("##ai_input", g_input_buffer[0..], input_width, input_height);
        if (!busy) requestAiFocusIfClicked(layer_context, .chat_input);

        gui.sameLine();
        gui.pushStyleColor(.button, theme.Palette.ai_chat.primary_button.bg);
        gui.pushStyleColor(.button_hovered, theme.Palette.ai_chat.primary_button.hovered);
        gui.pushStyleColor(.button_active, theme.Palette.ai_chat.primary_button.active);
        const send_pressed = gui.buttonEx(if (busy) state.text(.ai_chat_wait) else state.text(.ai_chat_send), send_btn_width, input_height);
        gui.popStyleColor(3);

        if (send_pressed) {
            submitInput(state, layer_context);
            requestAiFocus(.chat_input);
        }
    }
}
