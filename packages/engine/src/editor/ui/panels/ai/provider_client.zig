const std = @import("std");
const i18n = @import("../../../i18n/mod.zig");
const state_mod = @import("../../../core/state.zig");

const AiProviderType = state_mod.AiProviderType;

const provider_client_log = std.log.scoped(.ai_provider_client);

pub const StreamRole = enum {
    assistant,
    reasoning,
};

pub const StreamSink = struct {
    context: ?*anyopaque = null,
    append_fn: *const fn (?*anyopaque, StreamRole, []const u8) void,
};

pub const ProviderCompletion = struct {
    content: []u8,
    reasoning: ?[]u8 = null,

    pub fn deinit(self: *ProviderCompletion, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const RequestInput = struct {
    language: i18n.Language,
    provider_type: AiProviderType,
    endpoint_raw: []const u8,
    model: []const u8,
    api_key: []const u8 = "",
    system_prompt: []const u8,
    user_prompt: []const u8,
    stream_sink: ?StreamSink = null,
};

const ProviderRequestFlavor = enum {
    openai_chat_completions,
    openai_responses,
    anthropic_messages,
    ollama_chat,
};

const StreamAccumulator = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    stream_sink: ?StreamSink = null,

    fn deinit(self: *StreamAccumulator) void {
        self.content.deinit(std.heap.page_allocator);
        self.reasoning.deinit(std.heap.page_allocator);
        self.* = undefined;
    }

    fn appendRole(self: *StreamAccumulator, role: StreamRole, chunk: []const u8) !void {
        if (chunk.len == 0) return;

        switch (role) {
            .assistant => try self.content.appendSlice(std.heap.page_allocator, chunk),
            .reasoning => try self.reasoning.appendSlice(std.heap.page_allocator, chunk),
        }
        if (self.stream_sink) |sink| {
            sink.append_fn(sink.context, role, chunk);
        }
    }

    fn appendCompletionTail(self: *StreamAccumulator, role: StreamRole, full_text: []const u8) !void {
        if (full_text.len == 0) return;

        const existing = switch (role) {
            .assistant => self.content.items,
            .reasoning => self.reasoning.items,
        };

        if (existing.len == 0) {
            try self.appendRole(role, full_text);
            return;
        }
        if (full_text.len <= existing.len) return;
        if (!std.mem.startsWith(u8, full_text, existing)) return;
        try self.appendRole(role, full_text[existing.len..]);
    }

    fn appendResolvedCompletion(self: *StreamAccumulator, completion: *const ProviderCompletion) !void {
        try self.appendCompletionTail(.assistant, completion.content);
        if (completion.reasoning) |reasoning| {
            try self.appendCompletionTail(.reasoning, reasoning);
        }
    }

    fn finish(self: *const StreamAccumulator) !ProviderCompletion {
        return .{
            .content = try std.heap.page_allocator.dupe(u8, self.content.items),
            .reasoning = if (self.reasoning.items.len > 0)
                try std.heap.page_allocator.dupe(u8, self.reasoning.items)
            else
                null,
        };
    }
};

fn endpointPathSlice(endpoint: []const u8) []const u8 {
    if (std.mem.indexOf(u8, endpoint, "://")) |scheme_index| {
        const host_start = scheme_index + 3;
        if (std.mem.indexOfScalarPos(u8, endpoint, host_start, '/')) |path_start| {
            return endpoint[path_start..];
        }
        return "";
    }
    if (std.mem.indexOfScalar(u8, endpoint, '/')) |path_start| {
        return endpoint[path_start..];
    }
    return "";
}

fn endpointHostSlice(endpoint: []const u8) []const u8 {
    if (std.mem.indexOf(u8, endpoint, "://")) |scheme_index| {
        const host_start = scheme_index + 3;
        const path_start = std.mem.indexOfScalarPos(u8, endpoint, host_start, '/') orelse endpoint.len;
        return endpoint[host_start..path_start];
    }
    const path_start = std.mem.indexOfScalar(u8, endpoint, '/') orelse endpoint.len;
    return endpoint[0..path_start];
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    for (prefix, 0..) |needle_char, index| {
        if (std.ascii.toLower(haystack[index]) != std.ascii.toLower(needle_char)) {
            return false;
        }
    }
    return true;
}

fn modelSupportsAnthropicThinking(model: []const u8) bool {
    return asciiContainsIgnoreCase(model, "claude-3-7") or
        asciiContainsIgnoreCase(model, "claude-sonnet-4") or
        asciiContainsIgnoreCase(model, "claude-opus-4") or
        asciiContainsIgnoreCase(model, "claude-4");
}

fn endpointSupportsOpenAiResponses(provider_type: AiProviderType, endpoint_raw: []const u8, model: []const u8) bool {
    const endpoint = std.mem.trim(u8, endpoint_raw, " \t\r\n");
    const path = endpointPathSlice(endpoint);
    const host = endpointHostSlice(endpoint);

    if (asciiContainsIgnoreCase(path, "/chat/completions")) return false;
    if (asciiContainsIgnoreCase(path, "/responses")) return true;
    if (asciiContainsIgnoreCase(host, "deepseek.com") or asciiStartsWithIgnoreCase(model, "deepseek")) {
        return false;
    }
    if (asciiContainsIgnoreCase(host, "openai.com")) return true;
    return provider_type == .openai and endpoint.len == 0;
}

fn shouldRequestOpenAiReasoningSummary(provider_type: AiProviderType, endpoint: []const u8) bool {
    return endpointSupportsOpenAiResponses(provider_type, endpoint, "");
}

fn requestFlavorForProvider(provider_type: AiProviderType, endpoint_raw: []const u8, model: []const u8) ProviderRequestFlavor {
    const endpoint = std.mem.trim(u8, endpoint_raw, " \t\r\n");
    const path = endpointPathSlice(endpoint);
    const host = endpointHostSlice(endpoint);

    return switch (provider_type) {
        .openai => if (endpointSupportsOpenAiResponses(provider_type, endpoint_raw, model))
            .openai_responses
        else
            .openai_chat_completions,
        .anthropic => .anthropic_messages,
        .ollama => .ollama_chat,
        .custom => if (asciiContainsIgnoreCase(path, "/api/chat"))
            .ollama_chat
        else if (asciiContainsIgnoreCase(path, "/messages") or
            asciiContainsIgnoreCase(host, "anthropic.com") or
            asciiStartsWithIgnoreCase(model, "claude"))
            .anthropic_messages
        else if (asciiContainsIgnoreCase(path, "/responses") or
            asciiContainsIgnoreCase(host, "openai.com"))
            .openai_responses
        else
            .openai_chat_completions,
    };
}

fn replaceEndpointSuffixAlloc(endpoint: []const u8, old_suffix: []const u8, new_suffix: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, endpoint, old_suffix)) {
        return std.heap.page_allocator.dupe(u8, endpoint);
    }
    const base = endpoint[0 .. endpoint.len - old_suffix.len];
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ base, new_suffix });
}

fn normalizeProviderEndpointAlloc(flavor: ProviderRequestFlavor, endpoint_raw: []const u8) ![]u8 {
    const endpoint = std.mem.trim(u8, endpoint_raw, " \t\r\n");
    if (endpoint.len == 0) {
        return std.heap.page_allocator.dupe(u8, endpoint);
    }

    const path = endpointPathSlice(endpoint);
    const already_targeted = switch (flavor) {
        .openai_chat_completions => std.mem.indexOf(u8, path, "/chat/completions") != null,
        .openai_responses => std.mem.indexOf(u8, path, "/responses") != null,
        .anthropic_messages => std.mem.indexOf(u8, path, "/messages") != null,
        .ollama_chat => std.mem.indexOf(u8, path, "/api/chat") != null,
    };
    if (already_targeted) {
        return std.heap.page_allocator.dupe(u8, endpoint);
    }

    const should_append = switch (flavor) {
        .openai_chat_completions, .openai_responses => path.len == 0 or
            std.mem.eql(u8, path, "/") or
            std.mem.eql(u8, path, "/v1") or
            std.mem.eql(u8, path, "/v1/"),
        .anthropic_messages => path.len == 0 or
            std.mem.eql(u8, path, "/") or
            std.mem.eql(u8, path, "/v1") or
            std.mem.eql(u8, path, "/v1/"),
        .ollama_chat => path.len == 0 or std.mem.eql(u8, path, "/"),
    };

    const base = std.mem.trimRight(u8, endpoint, "/");
    if (should_append) {
        const suffix = switch (flavor) {
            .openai_chat_completions => if (std.mem.endsWith(u8, base, "/v1")) "/chat/completions" else "/v1/chat/completions",
            .openai_responses => if (std.mem.endsWith(u8, base, "/v1")) "/responses" else "/v1/responses",
            .anthropic_messages => "/v1/messages",
            .ollama_chat => "/api/chat",
        };
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ base, suffix });
    }

    return switch (flavor) {
        .openai_responses => if (std.mem.endsWith(u8, base, "/chat/completions"))
            replaceEndpointSuffixAlloc(base, "/chat/completions", "/responses")
        else
            std.heap.page_allocator.dupe(u8, endpoint),
        .openai_chat_completions => if (std.mem.endsWith(u8, base, "/responses"))
            replaceEndpointSuffixAlloc(base, "/responses", "/chat/completions")
        else
            std.heap.page_allocator.dupe(u8, endpoint),
        .anthropic_messages => if (std.mem.endsWith(u8, base, "/chat/completions"))
            replaceEndpointSuffixAlloc(base, "/chat/completions", "/messages")
        else if (std.mem.endsWith(u8, base, "/responses"))
            replaceEndpointSuffixAlloc(base, "/responses", "/messages")
        else
            std.heap.page_allocator.dupe(u8, endpoint),
        .ollama_chat => std.heap.page_allocator.dupe(u8, endpoint),
    };
}

fn stringifyJsonValueAlloc(value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try std.heap.page_allocator.dupe(u8, out.written());
}

fn appendStreamValueChunk(accumulator: *StreamAccumulator, role: StreamRole, value: std.json.Value) !void {
    if (try parseMessageTextValueAlloc(value)) |text| {
        defer std.heap.page_allocator.free(text);
        try accumulator.appendRole(role, text);
    }
}

fn appendStreamObjectFieldChunk(
    accumulator: *StreamAccumulator,
    role: StreamRole,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !bool {
    const value = object.get(field_name) orelse return false;
    try appendStreamValueChunk(accumulator, role, value);
    return true;
}

fn processOpenAiChatStreamPayload(data: []const u8, accumulator: *StreamAccumulator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const choices_value = parsed.value.object.get("choices") orelse return error.InvalidProviderResponse;
    if (choices_value != .array) return error.InvalidProviderResponse;

    for (choices_value.array.items) |choice| {
        if (choice != .object) continue;
        const delta_value = choice.object.get("delta") orelse continue;
        if (delta_value != .object) continue;

        _ = try appendStreamObjectFieldChunk(accumulator, .assistant, delta_value.object, "content");
        if (!(try appendStreamObjectFieldChunk(accumulator, .reasoning, delta_value.object, "reasoning_content"))) {
            _ = try appendStreamObjectFieldChunk(accumulator, .reasoning, delta_value.object, "reasoning");
        }
    }
}

fn processOpenAiResponsesStreamPayload(data: []const u8, accumulator: *StreamAccumulator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const event_type_value = parsed.value.object.get("type") orelse return;
    if (event_type_value != .string) return;
    const event_type = event_type_value.string;

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        _ = try appendStreamObjectFieldChunk(accumulator, .assistant, parsed.value.object, "delta");
        return;
    }

    if (asciiContainsIgnoreCase(event_type, "reasoning")) {
        if (!(try appendStreamObjectFieldChunk(accumulator, .reasoning, parsed.value.object, "delta"))) {
            if (!(try appendStreamObjectFieldChunk(accumulator, .reasoning, parsed.value.object, "text"))) {
                _ = try appendStreamObjectFieldChunk(accumulator, .reasoning, parsed.value.object, "summary");
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item_value = parsed.value.object.get("item") orelse return;
        if (item_value != .object) return;
        const item_type_value = item_value.object.get("type") orelse return;
        if (item_type_value != .string) return;

        if (std.mem.eql(u8, item_type_value.string, "message")) {
            if (item_value.object.get("content")) |content_value| {
                if (try parseMessageTextValueAlloc(content_value)) |text| {
                    defer std.heap.page_allocator.free(text);
                    try accumulator.appendCompletionTail(.assistant, text);
                }
            }
        } else if (std.mem.eql(u8, item_type_value.string, "reasoning")) {
            if (item_value.object.get("content")) |reasoning_value| {
                if (try parseMessageTextValueAlloc(reasoning_value)) |text| {
                    defer std.heap.page_allocator.free(text);
                    try accumulator.appendCompletionTail(.reasoning, text);
                }
            }
            if (item_value.object.get("summary")) |summary_value| {
                if (try parseMessageTextValueAlloc(summary_value)) |text| {
                    defer std.heap.page_allocator.free(text);
                    try accumulator.appendCompletionTail(.reasoning, text);
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "response.completed")) {
        const response_value = parsed.value.object.get("response") orelse return;
        var completion = try parseOpenAiResponsesCompletionValueAlloc(response_value);
        defer completion.deinit(std.heap.page_allocator);
        try accumulator.appendResolvedCompletion(&completion);
    }
}

fn processAnthropicStreamPayload(data: []const u8, accumulator: *StreamAccumulator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const event_type_value = parsed.value.object.get("type") orelse return;
    if (event_type_value != .string) return;
    const event_type = event_type_value.string;

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const delta_value = parsed.value.object.get("delta") orelse return;
        if (delta_value != .object) return;
        const delta_type_value = delta_value.object.get("type") orelse return;
        if (delta_type_value != .string) return;

        if (std.mem.eql(u8, delta_type_value.string, "text_delta")) {
            _ = try appendStreamObjectFieldChunk(accumulator, .assistant, delta_value.object, "text");
        } else if (std.mem.eql(u8, delta_type_value.string, "thinking_delta")) {
            _ = try appendStreamObjectFieldChunk(accumulator, .reasoning, delta_value.object, "thinking");
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const block_value = parsed.value.object.get("content_block") orelse return;
        if (block_value != .object) return;
        const block_type_value = block_value.object.get("type") orelse return;
        if (block_type_value != .string) return;

        if (std.mem.eql(u8, block_type_value.string, "text")) {
            _ = try appendStreamObjectFieldChunk(accumulator, .assistant, block_value.object, "text");
        } else if (std.mem.eql(u8, block_type_value.string, "thinking")) {
            if (!(try appendStreamObjectFieldChunk(accumulator, .reasoning, block_value.object, "thinking"))) {
                _ = try appendStreamObjectFieldChunk(accumulator, .reasoning, block_value.object, "text");
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "message_stop")) {
        return;
    }

    if (std.mem.eql(u8, event_type, "error")) {
        return error.ProviderStreamEventFailed;
    }
}

fn processOllamaStreamPayload(data: []const u8, accumulator: *StreamAccumulator) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    if (parsed.value.object.get("message")) |message_value| {
        if (message_value == .object) {
            _ = try appendStreamObjectFieldChunk(accumulator, .assistant, message_value.object, "content");
        }
    }

    if (parsed.value.object.get("done")) |done_value| {
        if (done_value == .bool) return done_value.bool;
    }
    return false;
}

fn processProviderStreamPayload(
    flavor: ProviderRequestFlavor,
    event_name: []const u8,
    data: []const u8,
    accumulator: *StreamAccumulator,
) !bool {
    _ = event_name;

    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "[DONE]")) return true;

    switch (flavor) {
        .openai_chat_completions => try processOpenAiChatStreamPayload(trimmed, accumulator),
        .openai_responses => try processOpenAiResponsesStreamPayload(trimmed, accumulator),
        .anthropic_messages => try processAnthropicStreamPayload(trimmed, accumulator),
        .ollama_chat => return try processOllamaStreamPayload(trimmed, accumulator),
    }
    return false;
}

fn flushSseEvent(
    flavor: ProviderRequestFlavor,
    event_name: *std.ArrayList(u8),
    event_data: *std.ArrayList(u8),
    accumulator: *StreamAccumulator,
) !bool {
    if (event_data.items.len == 0) {
        event_name.clearRetainingCapacity();
        event_data.clearRetainingCapacity();
        return false;
    }

    const finished = try processProviderStreamPayload(flavor, event_name.items, event_data.items, accumulator);
    event_name.clearRetainingCapacity();
    event_data.clearRetainingCapacity();
    return finished;
}

fn httpPostStreamAlloc(
    flavor: ProviderRequestFlavor,
    endpoint: []const u8,
    payload: []u8,
    extra_headers: []const std.http.Header,
    stream_sink: ?StreamSink,
) !ProviderCompletion {
    var accumulator: StreamAccumulator = .{ .stream_sink = stream_sink };
    defer accumulator.deinit();

    var client = std.http.Client{ .allocator = std.heap.page_allocator };
    defer client.deinit();

    const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;

    const accept_header = std.http.Header{
        .name = "accept",
        .value = if (flavor == .ollama_chat) "application/x-ndjson" else "text/event-stream",
    };
    var full_headers_buf: [4]std.http.Header = undefined;
    full_headers_buf[0] = accept_header;
    for (extra_headers, 0..) |h, i| {
        full_headers_buf[i + 1] = h;
    }
    const full_headers = full_headers_buf[0 .. extra_headers.len + 1];

    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = full_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    if (response.head.status.class() != .success) {
        return error.HttpError;
    }

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var buffer: [8192]u8 = undefined;
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(std.heap.page_allocator);
    var event_name = std.ArrayList(u8).empty;
    defer event_name.deinit(std.heap.page_allocator);
    var event_data = std.ArrayList(u8).empty;
    defer event_data.deinit(std.heap.page_allocator);

    while (true) {
        const bytes_read = reader.readSliceShort(buffer[0..]) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
        };
        if (bytes_read == 0) break;
        var i: usize = 0;
        while (i < bytes_read) {
            if (buffer[i] == '\n') {
                const line = std.mem.trimRight(u8, line_buf.items, "\r");
                if (flavor == .ollama_chat) {
                    if (line.len > 0 and try processProviderStreamPayload(flavor, "", line, &accumulator)) {
                        return accumulator.finish();
                    }
                } else if (line.len == 0) {
                    if (try flushSseEvent(flavor, &event_name, &event_data, &accumulator)) {
                        return accumulator.finish();
                    }
                } else if (std.mem.startsWith(u8, line, "event:")) {
                    event_name.clearRetainingCapacity();
                    try event_name.appendSlice(std.heap.page_allocator, std.mem.trimLeft(u8, line["event:".len..], " "));
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    if (event_data.items.len > 0) {
                        try event_data.append(std.heap.page_allocator, '\n');
                    }
                    try event_data.appendSlice(std.heap.page_allocator, std.mem.trimLeft(u8, line["data:".len..], " "));
                } else if (line[0] != ':') {
                    if (try processProviderStreamPayload(flavor, "", line, &accumulator)) {
                        return accumulator.finish();
                    }
                }
                line_buf.clearRetainingCapacity();
            } else {
                if (line_buf.items.len < 16 * 1024) {
                    try line_buf.append(std.heap.page_allocator, buffer[i]);
                }
            }
            i += 1;
        }
    }

    if (line_buf.items.len > 0) {
        const line = std.mem.trimRight(u8, line_buf.items, "\r");
        if (flavor == .ollama_chat) {
            _ = try processProviderStreamPayload(flavor, "", line, &accumulator);
        } else if (line.len > 0 and std.mem.startsWith(u8, line, "data:")) {
            if (event_data.items.len > 0) {
                try event_data.append(std.heap.page_allocator, '\n');
            }
            try event_data.appendSlice(std.heap.page_allocator, std.mem.trimLeft(u8, line["data:".len..], " "));
        }
    }
    if (flavor != .ollama_chat) {
        _ = try flushSseEvent(flavor, &event_name, &event_data, &accumulator);
    }
    return accumulator.finish();
}

fn parseMessageTextValueAlloc(value: std.json.Value) !?[]u8 {
    switch (value) {
        .string => |content| return try std.heap.page_allocator.dupe(u8, content),
        .array => |parts| {
            var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
            defer out.deinit();
            for (parts.items) |part| {
                switch (part) {
                    .string => |text| try out.writer.writeAll(text),
                    .object => |obj| {
                        if (obj.get("text")) |text_value| {
                            if (text_value == .string) {
                                try out.writer.writeAll(text_value.string);
                            }
                        }
                    },
                    else => {},
                }
            }
            if (out.written().len == 0) return null;
            return try std.heap.page_allocator.dupe(u8, out.written());
        },
        .null => return null,
        else => return error.InvalidProviderResponse,
    }
}

fn appendJoinedText(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    if (buffer.items.len > 0) {
        try buffer.appendSlice(allocator, "\n\n");
    }
    try buffer.appendSlice(allocator, trimmed);
}

fn parseOpenAiCompletionValueAlloc(root: std.json.Value) !ProviderCompletion {
    if (root != .object) return error.InvalidProviderResponse;
    const choices_value = root.object.get("choices") orelse return error.InvalidProviderResponse;
    if (choices_value != .array or choices_value.array.items.len == 0) return error.InvalidProviderResponse;

    const choice = choices_value.array.items[0];
    if (choice != .object) return error.InvalidProviderResponse;

    const message_value = choice.object.get("message") orelse return error.InvalidProviderResponse;
    if (message_value != .object) return error.InvalidProviderResponse;

    const content = if (message_value.object.get("content")) |content_value|
        if (try parseMessageTextValueAlloc(content_value)) |resolved|
            resolved
        else
            try std.heap.page_allocator.dupe(u8, "")
    else
        try std.heap.page_allocator.dupe(u8, "");
    errdefer std.heap.page_allocator.free(content);

    const reasoning = if (message_value.object.get("reasoning_content")) |value|
        try parseMessageTextValueAlloc(value)
    else if (message_value.object.get("reasoning")) |value|
        try parseMessageTextValueAlloc(value)
    else
        null;

    return .{ .content = content, .reasoning = reasoning };
}

fn parseOpenAiResponsesCompletionValueAlloc(root: std.json.Value) !ProviderCompletion {
    if (root != .object) return error.InvalidProviderResponse;
    var content_parts = std.ArrayList(u8).empty;
    defer content_parts.deinit(std.heap.page_allocator);
    var reasoning_parts = std.ArrayList(u8).empty;
    defer reasoning_parts.deinit(std.heap.page_allocator);

    if (root.object.get("output")) |output_value| {
        if (output_value != .array) return error.InvalidProviderResponse;
        for (output_value.array.items) |item| {
            if (item != .object) continue;
            const type_value = item.object.get("type") orelse continue;
            if (type_value != .string) continue;

            if (std.mem.eql(u8, type_value.string, "message")) {
                if (item.object.get("content")) |content_value| {
                    if (try parseMessageTextValueAlloc(content_value)) |text| {
                        defer std.heap.page_allocator.free(text);
                        try appendJoinedText(&content_parts, std.heap.page_allocator, text);
                    }
                }
            } else if (std.mem.eql(u8, type_value.string, "reasoning")) {
                if (item.object.get("content")) |reasoning_value| {
                    if (try parseMessageTextValueAlloc(reasoning_value)) |text| {
                        defer std.heap.page_allocator.free(text);
                        try appendJoinedText(&reasoning_parts, std.heap.page_allocator, text);
                    }
                }
                if (item.object.get("summary")) |summary_value| {
                    if (try parseMessageTextValueAlloc(summary_value)) |text| {
                        defer std.heap.page_allocator.free(text);
                        try appendJoinedText(&reasoning_parts, std.heap.page_allocator, text);
                    }
                }
            }
        }
    }

    if (reasoning_parts.items.len == 0) {
        if (root.object.get("reasoning")) |reasoning_value| {
            if (reasoning_value == .object) {
                if (reasoning_value.object.get("content")) |content_value| {
                    if (try parseMessageTextValueAlloc(content_value)) |text| {
                        defer std.heap.page_allocator.free(text);
                        try appendJoinedText(&reasoning_parts, std.heap.page_allocator, text);
                    }
                }
                if (reasoning_value.object.get("summary")) |summary_value| {
                    if (try parseMessageTextValueAlloc(summary_value)) |text| {
                        defer std.heap.page_allocator.free(text);
                        try appendJoinedText(&reasoning_parts, std.heap.page_allocator, text);
                    }
                }
            }
        }
    }

    if (content_parts.items.len == 0) {
        if (root.object.get("output_text")) |output_text| {
            if (output_text == .string) {
                try appendJoinedText(&content_parts, std.heap.page_allocator, output_text.string);
            }
        }
    }

    return .{
        .content = try std.heap.page_allocator.dupe(u8, content_parts.items),
        .reasoning = if (reasoning_parts.items.len > 0)
            try std.heap.page_allocator.dupe(u8, reasoning_parts.items)
        else
            null,
    };
}

fn parseAnthropicCompletionAlloc(body: []const u8) !ProviderCompletion {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const content_value = parsed.value.object.get("content") orelse return error.InvalidProviderResponse;
    if (content_value != .array) return error.InvalidProviderResponse;

    var final_text = std.ArrayList(u8).empty;
    defer final_text.deinit(std.heap.page_allocator);
    var reasoning_text = std.ArrayList(u8).empty;
    defer reasoning_text.deinit(std.heap.page_allocator);
    for (content_value.array.items) |item| {
        if (item != .object) continue;
        const type_value = item.object.get("type") orelse continue;
        if (type_value != .string) continue;
        if (std.mem.eql(u8, type_value.string, "text")) {
            const text_value = item.object.get("text") orelse continue;
            if (text_value != .string) continue;
            try appendJoinedText(&final_text, std.heap.page_allocator, text_value.string);
        } else if (std.mem.eql(u8, type_value.string, "thinking")) {
            const text_value = item.object.get("thinking") orelse item.object.get("text") orelse continue;
            if (text_value != .string) continue;
            try appendJoinedText(&reasoning_text, std.heap.page_allocator, text_value.string);
        }
    }
    return .{
        .content = try std.heap.page_allocator.dupe(u8, final_text.items),
        .reasoning = if (reasoning_text.items.len > 0)
            try std.heap.page_allocator.dupe(u8, reasoning_text.items)
        else
            null,
    };
}

fn parseOpenAiCompletionAlloc(body: []const u8) !ProviderCompletion {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parseOpenAiCompletionValueAlloc(parsed.value);
}

fn parseOpenAiResponsesCompletionAlloc(body: []const u8) !ProviderCompletion {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parseOpenAiResponsesCompletionValueAlloc(parsed.value);
}

fn parseOllamaCompletionAlloc(body: []const u8) !ProviderCompletion {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const message_value = parsed.value.object.get("message") orelse return error.InvalidProviderResponse;
    if (message_value != .object) return error.InvalidProviderResponse;
    const content_value = message_value.object.get("content") orelse return error.InvalidProviderResponse;
    if (content_value != .string) return error.InvalidProviderResponse;
    return .{
        .content = try std.heap.page_allocator.dupe(u8, content_value.string),
    };
}

fn parseProviderCompletionAlloc(body: []const u8) !ProviderCompletion {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    if (parsed.value.object.get("output") != null) return parseOpenAiResponsesCompletionAlloc(body);
    if (parsed.value.object.get("choices") != null) return parseOpenAiCompletionAlloc(body);
    if (parsed.value.object.get("message") != null) return parseOllamaCompletionAlloc(body);
    if (parsed.value.object.get("content") != null) return parseAnthropicCompletionAlloc(body);
    return error.InvalidProviderResponse;
}

fn errorCompletion(language: i18n.Language, err: anyerror) ProviderCompletion {
    return .{
        .content = i18n.allocPrintMessage(
            .ai_chat_provider_request_failed_error_fmt,
            std.heap.page_allocator,
            language,
            .{@errorName(err)},
        ) catch std.heap.page_allocator.dupe(
            u8,
            i18n.text(language, .ai_chat_provider_request_failed_fallback),
        ) catch unreachable,
    };
}

pub fn requestCompletionAlloc(input: *const RequestInput) !ProviderCompletion {
    const request_flavor = requestFlavorForProvider(input.provider_type, input.endpoint_raw, input.model);
    const endpoint = try normalizeProviderEndpointAlloc(request_flavor, input.endpoint_raw);
    defer std.heap.page_allocator.free(endpoint);

    provider_client_log.info("Submitting provider request: type={s} flavor={s} model={s} endpoint={s} prompt_len={d}", .{
        @tagName(input.provider_type),
        @tagName(request_flavor),
        input.model,
        endpoint,
        input.user_prompt.len,
    });

    const OpenAiMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    return switch (request_flavor) {
        .openai_chat_completions => blk: {
            const RequestBody = struct {
                model: []const u8,
                temperature: f32 = 0.0,
                messages: []const OpenAiMessage,
                stream: bool = true,
            };
            const messages = [_]OpenAiMessage{
                .{ .role = "system", .content = input.system_prompt },
                .{ .role = "user", .content = input.user_prompt },
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = input.model,
                .messages = &messages,
                .stream = true,
            });
            defer std.heap.page_allocator.free(payload);

            var auth_value: ?[]u8 = null;
            defer if (auth_value) |value| std.heap.page_allocator.free(value);
            const headers: []const std.http.Header = if (input.api_key.len > 0) blk_headers: {
                auth_value = try std.fmt.allocPrint(std.heap.page_allocator, "Bearer {s}", .{input.api_key});
                break :blk_headers @as([]const std.http.Header, &.{.{ .name = "Authorization", .value = auth_value.? }});
            } else @as([]const std.http.Header, &[_]std.http.Header{});

            break :blk httpPostStreamAlloc(request_flavor, endpoint, payload, headers, input.stream_sink) catch |err| {
                provider_client_log.warn("Provider stream request failed: flavor={s} error={s}", .{
                    @tagName(request_flavor),
                    @errorName(err),
                });
                break :blk errorCompletion(input.language, err);
            };
        },
        .openai_responses => blk: {
            const ResponseReasoning = struct {
                summary: []const u8 = "detailed",
            };
            const RequestBody = struct {
                model: []const u8,
                instructions: []const u8,
                input: []const u8,
                store: bool = false,
                reasoning: ?ResponseReasoning = null,
                stream: bool = true,
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = input.model,
                .instructions = input.system_prompt,
                .input = input.user_prompt,
                .reasoning = if (shouldRequestOpenAiReasoningSummary(input.provider_type, endpoint))
                    .{}
                else
                    null,
                .stream = true,
            });
            defer std.heap.page_allocator.free(payload);

            var auth_value: ?[]u8 = null;
            defer if (auth_value) |value| std.heap.page_allocator.free(value);
            const headers: []const std.http.Header = if (input.api_key.len > 0) blk_headers: {
                auth_value = try std.fmt.allocPrint(std.heap.page_allocator, "Bearer {s}", .{input.api_key});
                break :blk_headers @as([]const std.http.Header, &.{.{ .name = "Authorization", .value = auth_value.? }});
            } else @as([]const std.http.Header, &[_]std.http.Header{});

            break :blk httpPostStreamAlloc(request_flavor, endpoint, payload, headers, input.stream_sink) catch |err| {
                provider_client_log.warn("Provider stream request failed: flavor={s} error={s}", .{
                    @tagName(request_flavor),
                    @errorName(err),
                });
                break :blk errorCompletion(input.language, err);
            };
        },
        .anthropic_messages => blk: {
            const AnthropicMessage = struct {
                role: []const u8,
                content: []const u8,
            };
            const AnthropicThinking = struct {
                type: []const u8 = "enabled",
                budget_tokens: u32 = 2048,
            };
            const RequestBody = struct {
                model: []const u8,
                max_tokens: u32 = 4096,
                system: []const u8,
                messages: []const AnthropicMessage,
                thinking: ?AnthropicThinking = null,
                stream: bool = true,
            };
            const messages = [_]AnthropicMessage{
                .{ .role = "user", .content = input.user_prompt },
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = input.model,
                .system = input.system_prompt,
                .messages = &messages,
                .thinking = if (modelSupportsAnthropicThinking(input.model)) .{} else null,
                .stream = true,
            });
            defer std.heap.page_allocator.free(payload);

            const headers = [_]std.http.Header{
                .{ .name = "x-api-key", .value = input.api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            };
            break :blk httpPostStreamAlloc(request_flavor, endpoint, payload, &headers, input.stream_sink) catch |err| {
                provider_client_log.warn("Provider stream request failed: flavor={s} error={s}", .{
                    @tagName(request_flavor),
                    @errorName(err),
                });
                break :blk errorCompletion(input.language, err);
            };
        },
        .ollama_chat => blk: {
            const RequestBody = struct {
                model: []const u8,
                stream: bool = true,
                messages: []const OpenAiMessage,
            };
            const messages = [_]OpenAiMessage{
                .{ .role = "system", .content = input.system_prompt },
                .{ .role = "user", .content = input.user_prompt },
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = input.model,
                .messages = &messages,
                .stream = true,
            });
            defer std.heap.page_allocator.free(payload);
            break :blk httpPostStreamAlloc(request_flavor, endpoint, payload, &.{}, input.stream_sink) catch |err| {
                provider_client_log.warn("Provider stream request failed: flavor={s} error={s}", .{
                    @tagName(request_flavor),
                    @errorName(err),
                });
                break :blk errorCompletion(input.language, err);
            };
        },
    };
}
