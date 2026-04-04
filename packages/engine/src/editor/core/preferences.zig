const std = @import("std");
const engine = @import("guava");
const sdl = engine.platform.sdl;

const state_mod = @import("state.zig");

const EditorState = state_mod.EditorState;
const AiProviderType = state_mod.AiProviderType;
const FpsDisplayMode = state_mod.FpsDisplayMode;
const MeshShortcutBinding = state_mod.MeshShortcutBinding;
const MeshEditShortcutConfig = state_mod.MeshEditShortcutConfig;
const max_ai_providers = state_mod.max_ai_providers;

const ai_prefs_file_name = "ai_provider_settings.json";
const editor_prefs_file_name = "editor_preferences.json";
const max_prefs_file_size: usize = 256 * 1024;

const PersistedProvider = struct {
    provider_type: ?[]const u8 = null,
    name: []const u8 = "",
    endpoint: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
};

const PersistedPrefs = struct {
    version: u32 = 2,
    provider_type: []const u8 = "openai",
    active_provider: usize = 0,
    providers: []const PersistedProvider = &.{},
};

const PersistedEditorPrefs = struct {
    version: u32 = 2,
    fps_display_mode: ?[]const u8 = null,
    vsync_enabled: ?bool = null,
    mesh_modal_drag_sensitivity: ?f32 = null,
    mesh_modal_fine_scale: ?f32 = null,
    mesh_edit_shortcuts: ?PersistedMeshEditShortcutConfig = null,
};

const PersistedMeshShortcutBinding = struct {
    key: ?[]const u8 = null,
    ctrl: ?bool = null,
    shift: ?bool = null,
    alt: ?bool = null,
};

const PersistedMeshEditShortcutConfig = struct {
    extrude: ?PersistedMeshShortcutBinding = null,
    inset: ?PersistedMeshShortcutBinding = null,
    bevel: ?PersistedMeshShortcutBinding = null,
    loop_cut: ?PersistedMeshShortcutBinding = null,
    merge: ?PersistedMeshShortcutBinding = null,
    duplicate: ?PersistedMeshShortcutBinding = null,
    separate: ?PersistedMeshShortcutBinding = null,
    recalc_normals: ?PersistedMeshShortcutBinding = null,
    pivot_to_selection: ?PersistedMeshShortcutBinding = null,
};

const ProviderDefaults = struct {
    endpoint: []const u8,
    model: []const u8,
};

const provider_defaults = [_]ProviderDefaults{
    .{ .endpoint = "https://api.openai.com/v1/responses", .model = "gpt-4o" },
    .{ .endpoint = "https://api.anthropic.com/v1/messages", .model = "claude-sonnet-4-20250514" },
    .{ .endpoint = "http://localhost:11434/api/chat", .model = "llama3.2" },
    .{ .endpoint = "", .model = "" },
};

fn fixedBufferSlice(buffer: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..len];
}

fn persistedFieldSlice(value: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
    return value[0..len];
}

fn writeFixedBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    if (buffer.len == 0) return;
    const copy_len = @min(buffer.len - 1, value.len);
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
}

fn providerIsEmpty(provider: PersistedProvider) bool {
    return trimSpace(persistedFieldSlice(provider.name)).len == 0 and
        trimSpace(persistedFieldSlice(provider.endpoint)).len == 0 and
        trimSpace(persistedFieldSlice(provider.model)).len == 0 and
        trimSpace(persistedFieldSlice(provider.api_key)).len == 0;
}

fn trimSpace(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, " \t\r\n");
}

fn isFilteredControlByte(ch: u8) bool {
    return (ch < 0x20 and ch != '\t' and ch != '\n' and ch != '\r') or ch == 0x7f;
}

fn sanitizedTextAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    for (value) |ch| {
        if (ch == 0) break;
        if (isFilteredControlByte(ch)) continue;
        try output.append(allocator, ch);
    }

    const trimmed = trimSpace(output.items);
    return allocator.dupe(u8, trimmed);
}

fn looksLikeGeneratedProviderName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(name, "new provider")) return true;
    if (name.len >= 13 and std.ascii.eqlIgnoreCase(name[0..13], "new provider ")) return true;
    if (std.ascii.eqlIgnoreCase(name, "openai")) return true;
    if (std.ascii.eqlIgnoreCase(name, "anthropic")) return true;
    if (std.ascii.eqlIgnoreCase(name, "ollama")) return true;
    if (std.ascii.eqlIgnoreCase(name, "custom")) return true;
    if (name.len >= 9 and std.ascii.eqlIgnoreCase(name[0..9], "provider ")) return true;
    if (std.mem.eql(u8, name, "新代理")) return true;
    if (std.mem.startsWith(u8, name, "新代理 ")) return true;
    if (std.mem.startsWith(u8, name, "代理 ")) return true;
    return false;
}

fn endpointLooksLikeAnyDefault(endpoint: []const u8) bool {
    if (endpoint.len == 0) return true;
    for (provider_defaults) |defaults| {
        if (defaults.endpoint.len == 0) continue;
        if (std.mem.eql(u8, endpoint, defaults.endpoint)) return true;
    }
    return false;
}

fn modelLooksLikeAnyDefault(model: []const u8) bool {
    if (model.len == 0) return true;
    for (provider_defaults) |defaults| {
        if (defaults.model.len == 0) continue;
        if (std.mem.eql(u8, model, defaults.model)) return true;
    }
    return false;
}

fn providerLooksLikePlaceholder(provider: PersistedProvider, provider_type: AiProviderType) bool {
    if (providerIsEmpty(provider)) return true;

    const name = trimSpace(persistedFieldSlice(provider.name));
    const endpoint = trimSpace(persistedFieldSlice(provider.endpoint));
    const model = trimSpace(persistedFieldSlice(provider.model));
    const api_key = trimSpace(persistedFieldSlice(provider.api_key));

    // Only treat as placeholder when ALL fields are truly empty or auto-generated.
    // A provider with a custom endpoint or model is user-configured and must be preserved.
    if (!looksLikeGeneratedProviderName(name)) return false;
    if (endpoint.len > 0 and !endpointLooksLikeAnyDefault(endpoint)) return false;
    if (model.len > 0 and !modelLooksLikeAnyDefault(model)) return false;

    _ = provider_type;
    return endpoint.len == 0 and model.len == 0 and api_key.len == 0;
}

fn providerHasCompleteConfig(provider: *const state_mod.AiProviderConfig, provider_type: AiProviderType) bool {
    const endpoint = trimSpace(fixedBufferSlice(provider.endpoint[0..]));
    const model = trimSpace(fixedBufferSlice(provider.model[0..]));
    const api_key = trimSpace(fixedBufferSlice(provider.api_key[0..]));

    if (endpoint.len == 0 or model.len == 0) return false;
    if (provider_type != .ollama and api_key.len == 0) return false;
    return true;
}

fn persistedProviderType(provider: PersistedProvider, fallback: AiProviderType) AiProviderType {
    const resolved = provider.provider_type orelse return fallback;
    return std.meta.stringToEnum(AiProviderType, resolved) orelse fallback;
}

fn prefsPathAlloc(allocator: std.mem.Allocator, file_name: []const u8) ![]u8 {
    const pref_path = sdl.c.SDL_GetPrefPath("Guava", "Editor") orelse return error.PreferencePathUnavailable;
    defer sdl.c.SDL_free(pref_path);
    const pref_dir = std.mem.span(pref_path);
    return std.fs.path.join(allocator, &.{ pref_dir, file_name });
}

fn writeJsonFileAtomically(allocator: std.mem.Allocator, path: []const u8, payload: anytype) !void {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();

    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(output.items);
    file.sync() catch {};

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(tmp_path, path);
}

fn saveAiProviderSettingsToPath(state: *const EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;

    const provider_count = @max(@as(usize, 1), @min(state.ai_provider_count, max_ai_providers));
    const persisted_providers = try allocator.alloc(PersistedProvider, provider_count);
    defer allocator.free(persisted_providers);
    var owned_fields = std.ArrayList([]u8).empty;
    defer {
        for (owned_fields.items) |field| allocator.free(field);
        owned_fields.deinit(allocator);
    }

    var has_meaningful_provider = false;
    for (persisted_providers, 0..) |*provider, index| {
        const source = state.ai_providers[index];
        const sanitized_name = try sanitizedTextAlloc(allocator, fixedBufferSlice(source.name[0..]));
        errdefer allocator.free(sanitized_name);
        try owned_fields.append(allocator, sanitized_name);
        const sanitized_endpoint = try sanitizedTextAlloc(allocator, fixedBufferSlice(source.endpoint[0..]));
        errdefer allocator.free(sanitized_endpoint);
        try owned_fields.append(allocator, sanitized_endpoint);
        const sanitized_model = try sanitizedTextAlloc(allocator, fixedBufferSlice(source.model[0..]));
        errdefer allocator.free(sanitized_model);
        try owned_fields.append(allocator, sanitized_model);
        const sanitized_api_key = try sanitizedTextAlloc(allocator, fixedBufferSlice(source.api_key[0..]));
        errdefer allocator.free(sanitized_api_key);
        try owned_fields.append(allocator, sanitized_api_key);
        provider.* = .{
            .provider_type = @tagName(source.provider_type),
            .name = sanitized_name,
            .endpoint = sanitized_endpoint,
            .model = sanitized_model,
            .api_key = sanitized_api_key,
        };
        if (!providerLooksLikePlaceholder(provider.*, source.provider_type)) {
            has_meaningful_provider = true;
        }
    }

    if (!has_meaningful_provider) {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const active_provider_index = @min(state.ai_active_provider, provider_count - 1);
    const active_provider_type = state.ai_providers[active_provider_index].provider_type;

    const payload = PersistedPrefs{
        .provider_type = @tagName(active_provider_type),
        .active_provider = active_provider_index,
        .providers = persisted_providers,
    };
    try writeJsonFileAtomically(allocator, path, payload);
}

fn loadAiProviderSettingsFromPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_prefs_file_size);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(PersistedPrefs, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const doc = parsed.value;
    const parsed_type = std.meta.stringToEnum(AiProviderType, doc.provider_type) orelse .openai;

    @memset(&state.ai_providers, .{});
    state.ai_provider_count = 0;

    const persisted_count = @min(doc.providers.len, max_ai_providers);
    var meaningful_count: usize = 0;
    for (doc.providers[0..persisted_count]) |provider| {
        const provider_type = persistedProviderType(provider, parsed_type);
        if (!providerLooksLikePlaceholder(provider, provider_type)) {
            meaningful_count += 1;
        }
    }
    const collapse_placeholder_tail = meaningful_count == 0 and persisted_count > 1;

    var resolved_active_provider: usize = 0;
    var resolved_active_found = false;
    for (doc.providers[0..persisted_count], 0..) |provider, source_index| {
        const provider_type = persistedProviderType(provider, parsed_type);
        if (collapse_placeholder_tail and providerLooksLikePlaceholder(provider, provider_type) and state.ai_provider_count > 0) {
            continue;
        }
        if (state.ai_provider_count >= max_ai_providers) break;
        const index = state.ai_provider_count;
        state.ai_providers[index].provider_type = provider_type;
        const sanitized_name = try sanitizedTextAlloc(allocator, persistedFieldSlice(provider.name));
        defer allocator.free(sanitized_name);
        const sanitized_endpoint = try sanitizedTextAlloc(allocator, persistedFieldSlice(provider.endpoint));
        defer allocator.free(sanitized_endpoint);
        const sanitized_model = try sanitizedTextAlloc(allocator, persistedFieldSlice(provider.model));
        defer allocator.free(sanitized_model);
        const sanitized_api_key = try sanitizedTextAlloc(allocator, persistedFieldSlice(provider.api_key));
        defer allocator.free(sanitized_api_key);
        writeFixedBuffer(state.ai_providers[index].name[0..], sanitized_name);
        writeFixedBuffer(state.ai_providers[index].endpoint[0..], sanitized_endpoint);
        writeFixedBuffer(state.ai_providers[index].model[0..], sanitized_model);
        writeFixedBuffer(state.ai_providers[index].api_key[0..], sanitized_api_key);
        if (source_index == doc.active_provider) {
            resolved_active_provider = index;
            resolved_active_found = true;
        }
        state.ai_provider_count += 1;
    }

    if (state.ai_provider_count == 0) {
        state.ai_provider_count = 1;
        state.ai_providers[0].provider_type = parsed_type;
    } else if (meaningful_count == 0) {
        @memset(&state.ai_providers, .{});
        state.ai_provider_count = 1;
        state.ai_providers[0].provider_type = parsed_type;
        resolved_active_found = false;
    }
    if (resolved_active_found) {
        state.ai_active_provider = resolved_active_provider;
    } else {
        state.ai_active_provider = @min(doc.active_provider, state.ai_provider_count - 1);
    }

    if (!providerHasCompleteConfig(
        &state.ai_providers[state.ai_active_provider],
        state.ai_providers[state.ai_active_provider].provider_type,
    )) {
        for (0..state.ai_provider_count) |index| {
            if (providerHasCompleteConfig(&state.ai_providers[index], state.ai_providers[index].provider_type)) {
                state.ai_active_provider = index;
                break;
            }
        }
    }

    state.ai_provider_type = state.ai_providers[state.ai_active_provider].provider_type;
}

pub fn loadAiProviderSettings(state: *EditorState) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const path = try prefsPathAlloc(allocator, ai_prefs_file_name);
    defer allocator.free(path);
    try loadAiProviderSettingsFromPath(state, path);
}

pub fn saveAiProviderSettings(state: *const EditorState) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const path = try prefsPathAlloc(allocator, ai_prefs_file_name);
    defer allocator.free(path);
    try saveAiProviderSettingsToPath(state, path);
}

fn loadEditorPreferencesFromPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_prefs_file_size);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(PersistedEditorPrefs, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.fps_display_mode) |fps_mode_name| {
        state.fps_display_mode = std.meta.stringToEnum(FpsDisplayMode, fps_mode_name) orelse state.fps_display_mode;
    }
    if (parsed.value.vsync_enabled) |enabled| {
        state.vsync_enabled = enabled;
    }
    if (parsed.value.mesh_modal_drag_sensitivity) |value| {
        state.mesh_modal_drag_sensitivity = std.math.clamp(value, 0.0005, 0.05);
    }
    if (parsed.value.mesh_modal_fine_scale) |value| {
        state.mesh_modal_fine_scale = std.math.clamp(value, 0.05, 1.0);
    }
    if (parsed.value.mesh_edit_shortcuts) |shortcut_config| {
        applyMeshEditShortcutConfig(&state.mesh_edit_shortcuts, shortcut_config);
    }
}

fn saveEditorPreferencesToPath(state: *const EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const payload = PersistedEditorPrefs{
        .fps_display_mode = @tagName(state.fps_display_mode),
        .vsync_enabled = state.vsync_enabled,
        .mesh_modal_drag_sensitivity = state.mesh_modal_drag_sensitivity,
        .mesh_modal_fine_scale = state.mesh_modal_fine_scale,
        .mesh_edit_shortcuts = toPersistedMeshEditShortcutConfig(state.mesh_edit_shortcuts),
    };
    try writeJsonFileAtomically(allocator, path, payload);
}

fn applyMeshEditShortcutConfig(target: *MeshEditShortcutConfig, persisted: PersistedMeshEditShortcutConfig) void {
    if (persisted.extrude) |binding| applyMeshShortcutBinding(&target.extrude, binding);
    if (persisted.inset) |binding| applyMeshShortcutBinding(&target.inset, binding);
    if (persisted.bevel) |binding| applyMeshShortcutBinding(&target.bevel, binding);
    if (persisted.loop_cut) |binding| applyMeshShortcutBinding(&target.loop_cut, binding);
    if (persisted.merge) |binding| applyMeshShortcutBinding(&target.merge, binding);
    if (persisted.duplicate) |binding| applyMeshShortcutBinding(&target.duplicate, binding);
    if (persisted.separate) |binding| applyMeshShortcutBinding(&target.separate, binding);
    if (persisted.recalc_normals) |binding| applyMeshShortcutBinding(&target.recalc_normals, binding);
    if (persisted.pivot_to_selection) |binding| applyMeshShortcutBinding(&target.pivot_to_selection, binding);
}

fn applyMeshShortcutBinding(target: *MeshShortcutBinding, persisted: PersistedMeshShortcutBinding) void {
    if (persisted.key) |key_name| {
        if (std.meta.stringToEnum(engine.core.InputKey, key_name)) |parsed_key| {
            target.key = parsed_key;
        }
    }
    if (persisted.ctrl) |value| {
        target.ctrl = value;
    }
    if (persisted.shift) |value| {
        target.shift = value;
    }
    if (persisted.alt) |value| {
        target.alt = value;
    }
}

fn toPersistedMeshEditShortcutConfig(config: MeshEditShortcutConfig) PersistedMeshEditShortcutConfig {
    return .{
        .extrude = toPersistedMeshShortcutBinding(config.extrude),
        .inset = toPersistedMeshShortcutBinding(config.inset),
        .bevel = toPersistedMeshShortcutBinding(config.bevel),
        .loop_cut = toPersistedMeshShortcutBinding(config.loop_cut),
        .merge = toPersistedMeshShortcutBinding(config.merge),
        .duplicate = toPersistedMeshShortcutBinding(config.duplicate),
        .separate = toPersistedMeshShortcutBinding(config.separate),
        .recalc_normals = toPersistedMeshShortcutBinding(config.recalc_normals),
        .pivot_to_selection = toPersistedMeshShortcutBinding(config.pivot_to_selection),
    };
}

fn toPersistedMeshShortcutBinding(binding: MeshShortcutBinding) PersistedMeshShortcutBinding {
    return .{
        .key = @tagName(binding.key),
        .ctrl = binding.ctrl,
        .shift = binding.shift,
        .alt = binding.alt,
    };
}

pub fn loadEditorPreferences(state: *EditorState) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const path = try prefsPathAlloc(allocator, editor_prefs_file_name);
    defer allocator.free(path);
    try loadEditorPreferencesFromPath(state, path);
}

pub fn saveEditorPreferences(state: *const EditorState) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const path = try prefsPathAlloc(allocator, editor_prefs_file_name);
    defer allocator.free(path);
    try saveEditorPreferencesToPath(state, path);
}
