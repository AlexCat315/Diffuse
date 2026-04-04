const std = @import("std");
const state_mod = @import("../../../core/state.zig");

const EditorState = state_mod.EditorState;
pub const AiProviderConfig = state_mod.AiProviderConfig;
pub const AiProviderType = state_mod.AiProviderType;

pub const ProviderDefaults = struct {
    endpoint: []const u8,
    model: []const u8,
};

pub const provider_defaults: [4]ProviderDefaults = .{
    .{ .endpoint = "https://api.openai.com/v1/responses", .model = "gpt-4o" },
    .{ .endpoint = "https://api.anthropic.com/v1/messages", .model = "claude-sonnet-4-20250514" },
    .{ .endpoint = "http://localhost:11434/api/chat", .model = "llama3.2" },
    .{ .endpoint = "", .model = "" },
};

pub const provider_types = [_]AiProviderType{
    .openai,
    .anthropic,
    .ollama,
    .custom,
};

pub const ProviderValidationError = enum {
    endpoint_empty,
    model_empty,
    api_key_empty,
};

pub fn fixedBufferSlice(buffer: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..len];
}

pub fn writeFixedBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    if (buffer.len == 0) return;
    const copy_len = @min(buffer.len - 1, value.len);
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
}

pub fn activeProvider(state: *const EditorState) *const AiProviderConfig {
    return &state.ai_providers[@min(state.ai_active_provider, state.ai_provider_count -| 1)];
}

pub fn activeProviderMut(state: *EditorState) *AiProviderConfig {
    return &state.ai_providers[@min(state.ai_active_provider, state.ai_provider_count -| 1)];
}

pub fn activeProviderType(state: *const EditorState) AiProviderType {
    if (state.ai_provider_count == 0) return state.ai_provider_type;
    return activeProvider(state).provider_type;
}

pub fn syncActiveProviderType(state: *EditorState) void {
    state.ai_provider_type = activeProviderType(state);
}

pub fn setActiveProviderType(state: *EditorState, provider_type: AiProviderType) void {
    if (state.ai_provider_count == 0) {
        state.ai_provider_type = provider_type;
        return;
    }
    activeProviderMut(state).provider_type = provider_type;
    state.ai_provider_type = provider_type;
}

pub fn providerNeedsApiKey(provider_type: AiProviderType) bool {
    return provider_type != .ollama;
}

pub fn providerTypeText(state: *const EditorState, provider_type: AiProviderType) []const u8 {
    return switch (provider_type) {
        .openai => state.text(.ai_chat_provider_type_openai),
        .anthropic => state.text(.ai_chat_provider_type_anthropic),
        .ollama => state.text(.ai_chat_provider_type_ollama),
        .custom => state.text(.ai_chat_provider_type_custom),
    };
}

pub fn providerDisplayNameForUi(state: *const EditorState, provider: *const AiProviderConfig) []const u8 {
    const name = fixedBufferSlice(provider.name[0..]);
    if (name.len > 0) return name;
    return state.text(.ai_chat_provider_default_name);
}

pub fn applyProviderDefaults(state: *EditorState) void {
    if (state.ai_provider_count == 0) return;

    const provider_type = activeProviderType(state);
    const defaults = provider_defaults[@intFromEnum(provider_type)];
    const provider = activeProviderMut(state);

    if (provider.endpoint[0] == 0 and defaults.endpoint.len > 0) {
        writeFixedBuffer(provider.endpoint[0..], defaults.endpoint);
    }
    if (provider.model[0] == 0 and defaults.model.len > 0) {
        writeFixedBuffer(provider.model[0..], defaults.model);
    }
    state.ai_provider_type = provider_type;
}

pub fn validationErrorForProvider(provider: *const AiProviderConfig, provider_type: AiProviderType) ?ProviderValidationError {
    const endpoint = fixedBufferSlice(provider.endpoint[0..]);
    const model = fixedBufferSlice(provider.model[0..]);
    const api_key = fixedBufferSlice(provider.api_key[0..]);

    if (endpoint.len == 0) return .endpoint_empty;
    if (model.len == 0) return .model_empty;
    if (providerNeedsApiKey(provider_type) and api_key.len == 0) return .api_key_empty;
    return null;
}

pub fn activeProviderValidationError(state: *const EditorState) ?ProviderValidationError {
    return validationErrorForProvider(activeProvider(state), activeProviderType(state));
}

pub fn providerValidationErrorText(state: *const EditorState, validation_error: ProviderValidationError) []const u8 {
    return switch (validation_error) {
        .endpoint_empty => state.text(.ai_chat_validation_endpoint_empty),
        .model_empty => state.text(.ai_chat_validation_model_empty),
        .api_key_empty => state.text(.ai_chat_validation_api_key_empty),
    };
}
