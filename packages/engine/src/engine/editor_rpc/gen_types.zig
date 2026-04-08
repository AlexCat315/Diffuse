///! Comptime TypeScript code generator.
///!
///! Reads the schema/ modules at compile time and emits fully typed
///! TypeScript definitions.  No runtime reflection — all work happens
///! in comptime.
///!
///! Usage (from packages/engine/):
///!   zig run tools/gen_rpc_types.zig > ../editor/src/shared/rpc-types.generated.ts
///!
const std = @import("std");
const schema = @import("schema/mod.zig");

// Generate the entire file at comptime — O(1) runtime work.
const output = generate();

pub fn main() void {
    std.debug.print("{s}", .{output});
}

// ═══════════════════════════════════════════════════════════════════
//  Comptime generator
// ═══════════════════════════════════════════════════════════════════

fn generate() []const u8 {
    @setEvalBranchQuota(100_000);

    var r: []const u8 =
        \\// ╔═══════════════════════════════════════════════════════════╗
        \\// ║  AUTO-GENERATED — do not edit manually.                  ║
        \\// ║  Source of truth: src/engine/editor_rpc/schema/           ║
        \\// ║  Regenerate:                                             ║
        \\// ║    zig run src/engine/editor_rpc/gen_types.zig \        ║
        \\// ║      2> ../editor/src/shared/rpc-types.generated.ts      ║
        \\// ╚═══════════════════════════════════════════════════════════╝
        \\
        \\
    ;

    // ── Shared data types ────────────────────────────────────────
    r = r ++ "// ── Data Types ─────────────────────────────────────────────\n\n";
    for (@typeInfo(schema.types).@"struct".decls) |decl| {
        if (comptime std.mem.eql(u8, decl.name, "JsonValue")) continue;
        // Skip enum types — they are represented as strings in the wire format.
        if (comptime std.mem.eql(u8, decl.name, "ManipulationMode")) continue;
        if (comptime std.mem.eql(u8, decl.name, "TransformSpace")) continue;
        if (comptime std.mem.eql(u8, decl.name, "ViewportShadingMode")) continue;
        if (comptime std.mem.eql(u8, decl.name, "RenderJobStatus")) continue;
        r = r ++ emitInterface(decl.name, @field(schema.types, decl.name));
    }

    // ── RPC method map ───────────────────────────────────────────
    r = r ++ "// ── RPC Method Signatures ──────────────────────────────────\n\n";
    r = r ++ "export interface RpcMethods {\n";
    inline for (schema.method_modules) |mod| {
        for (@typeInfo(mod).@"struct".decls) |decl| {
            const M = @field(mod, decl.name);
            r = r ++ "  \"" ++ decl.name ++ "\": { params: " ++ typeToTs(M.Params) ++ "; result: " ++ typeToTs(M.Result) ++ " };\n";
        }
    }
    r = r ++ "}\n\n";

    // ── Subscription events ──────────────────────────────────────
    r = r ++ "// ── Subscription Events ───────────────────────────────────\n\n";
    r = r ++ "export interface SubscriptionEvents {\n";
    for (@typeInfo(schema.subscriptions).@"struct".decls) |decl| {
        r = r ++ "  \"" ++ decl.name ++ "\": " ++ typeToTs(@field(schema.subscriptions, decl.name)) ++ ";\n";
    }
    r = r ++ "}\n\n";

    // ── Convenience type aliases ─────────────────────────────────
    r = r ++
        \\// ── Convenience Aliases ───────────────────────────────────
        \\
        \\export type RpcMethodName = keyof RpcMethods;
        \\export type SubscriptionName = keyof SubscriptionEvents;
        \\
        \\export type RpcParams<M extends RpcMethodName> = RpcMethods[M]["params"];
        \\export type RpcResult<M extends RpcMethodName> = RpcMethods[M]["result"];
        \\
        \\// ── JSON-RPC 2.0 Wire Format ─────────────────────────────
        \\
        \\export interface JsonRpcRequest {
        \\  jsonrpc: "2.0";
        \\  id: number | string;
        \\  method: string;
        \\  params?: Record<string, unknown>;
        \\}
        \\
        \\export interface JsonRpcResponse {
        \\  jsonrpc: "2.0";
        \\  id: number | string;
        \\  result?: unknown;
        \\  error?: { code: number; message: string; data?: unknown };
        \\}
        \\
    ;

    // ── AI Tool Definitions ──────────────────────────────────────
    r = r ++ "// ── AI Tool Definitions ────────────────────────────────────\n\n";
    r = r ++ emitAiTools();

    return r;
}

// ═══════════════════════════════════════════════════════════════════
//  Type → TypeScript conversion
// ═══════════════════════════════════════════════════════════════════

fn typeToTs(comptime T: type) []const u8 {
    // Opaque sentinel → unknown
    if (T == schema.types.JsonValue) return "unknown";

    // Named shared type?
    for (@typeInfo(schema.types).@"struct".decls) |decl| {
        if (T == @field(schema.types, decl.name)) return decl.name;
    }

    return switch (@typeInfo(T)) {
        .bool => "boolean",
        .int => "number",
        .float => "number",
        .pointer => |p| if (p.child == u8) "string" else typeToTs(p.child) ++ "[]",
        .optional => |o| typeToTs(o.child) ++ " | null",
        .@"struct" => |s| structToTs(s.fields),
        else => "unknown /* " ++ @typeName(T) ++ " */",
    };
}

fn structToTs(comptime fields: anytype) []const u8 {
    if (fields.len == 0) return "Record<string, never>";
    var r: []const u8 = "{ ";
    for (fields, 0..) |field, i| {
        if (i > 0) r = r ++ "; ";
        const is_opt = isOptional(field.type);
        r = r ++ field.name;
        if (is_opt) r = r ++ "?";
        r = r ++ ": " ++ typeToTs(if (is_opt) unwrap(field.type) else field.type);
    }
    return r ++ " }";
}

fn isOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

fn unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

// ── Interface emitter ────────────────────────────────────────────

fn emitInterface(comptime name: []const u8, comptime T: type) []const u8 {
    var r: []const u8 = "export interface " ++ name ++ " {\n";
    for (@typeInfo(T).@"struct".fields) |field| {
        const is_opt = isOptional(field.type);
        r = r ++ "  " ++ field.name;
        if (is_opt) r = r ++ "?";
        r = r ++ ": " ++ typeToTs(if (is_opt) unwrap(field.type) else field.type) ++ ";\n";
    }
    return r ++ "}\n\n";
}

// ═══════════════════════════════════════════════════════════════════
//  AI Tool code generator
// ═══════════════════════════════════════════════════════════════════

const ai_tools = schema.ai_tools;

/// Look up the Params type for a given RPC method name across all schema modules.
fn findParamsType(comptime method_name: []const u8) ?type {
    inline for (schema.method_modules) |mod| {
        for (@typeInfo(mod).@"struct".decls) |decl| {
            if (comptime std.mem.eql(u8, decl.name, method_name)) {
                return @field(mod, decl.name).Params;
            }
        }
    }
    return null;
}

/// Convert a Zig type to a JSON Schema type string.
fn jsonSchemaType(comptime T: type) []const u8 {
    // Unwrap optionals first
    const U = if (isOptional(T)) unwrap(T) else T;
    return switch (@typeInfo(U)) {
        .bool => "boolean",
        .int => "integer",
        .float => "number",
        .pointer => |p| if (p.child == u8) "string" else "array",
        .@"struct" => "object",
        .array => "array",
        else => "string",
    };
}

/// Convert a Zig struct Params type to a JSON Schema object literal string.
/// Example output: { type: "object", properties: { entityId: { type: "integer" } }, required: ["entityId"] }
fn paramsToJsonSchema(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len == 0) return "{ type: \"object\" as const, properties: {} }";

    var r: []const u8 = "{ type: \"object\" as const, properties: { ";
    var req: []const u8 = "";
    var req_count: usize = 0;

    for (fields, 0..) |field, i| {
        if (i > 0) r = r ++ ", ";
        r = r ++ field.name ++ ": " ++ fieldToJsonSchema(field.type);

        // Non-optional fields without defaults are required
        if (!isOptional(field.type) and field.default_value_ptr == null) {
            if (req_count > 0) req = req ++ ", ";
            req = req ++ "\"" ++ field.name ++ "\"";
            req_count += 1;
        }
    }

    r = r ++ " }";
    if (req_count > 0) {
        r = r ++ ", required: [" ++ req ++ "]";
    }
    return r ++ " }";
}

/// Convert a single field type to its JSON Schema representation.
fn fieldToJsonSchema(comptime T: type) []const u8 {
    const U = if (isOptional(T)) unwrap(T) else T;

    // Opaque sentinel → any value (string is the best LLM hint for JSON-encoded values)
    if (U == schema.types.JsonValue) return "{ type: \"string\" as const }";

    return switch (@typeInfo(U)) {
        .bool => "{ type: \"boolean\" as const }",
        .int => "{ type: \"integer\" as const }",
        .float => "{ type: \"number\" as const }",
        .pointer => |p| {
            if (p.child == u8) {
                return "{ type: \"string\" as const }";
            }
            // Array of T → { type: "array", items: ... }
            return "{ type: \"array\" as const, items: " ++ fieldToJsonSchema(p.child) ++ " }";
        },
        .array => |a| {
            // Fixed-size array (e.g. [3]f64) → { type: "array", items: ... }
            return "{ type: \"array\" as const, items: " ++ fieldToJsonSchema(a.child) ++ " }";
        },
        .@"struct" => |s| {
            // Nested struct → { type: "object", properties: ... }
            if (s.fields.len == 0) return "{ type: \"object\" as const }";
            var r: []const u8 = "{ type: \"object\" as const, properties: { ";
            for (s.fields, 0..) |field, i| {
                if (i > 0) r = r ++ ", ";
                r = r ++ field.name ++ ": " ++ fieldToJsonSchema(field.type);
            }
            return r ++ " } }";
        },
        else => "{ type: \"string\" as const }",
    };
}

fn categoryToStr(comptime cat: ai_tools.Category) []const u8 {
    return switch (cat) {
        .scene => "scene",
        .entity => "entity",
        .playback => "playback",
        .script => "script",
        .asset => "asset",
        .animation => "animation",
        .material => "material",
        .camera => "camera",
        .render => "render",
        .prefab => "prefab",
        .audio => "audio",
        .query => "query",
    };
}

fn emitAiTools() []const u8 {
    @setEvalBranchQuota(200_000);

    // First, validate that all referenced RPC methods exist.
    for (ai_tools.tools) |tool| {
        if (findParamsType(tool.rpc_method) == null) {
            @compileError("ai_tools references unknown RPC method: " ++ tool.rpc_method);
        }
    }

    var r: []const u8 =
        \\export type ToolCategory =
        \\  | "scene"
        \\  | "entity"
        \\  | "playback"
        \\  | "script"
        \\  | "asset"
        \\  | "animation"
        \\  | "material"
        \\  | "camera"
        \\  | "render"
        \\  | "prefab"
        \\  | "audio"
        \\  | "query";
        \\
        \\export interface AiToolDef {
        \\  name: string;
        \\  description: string;
        \\  parameters: { type: "object"; properties: Record<string, unknown>; required?: string[] };
        \\  rpcMethod: RpcMethodName;
        \\  requiresConfirmation?: boolean;
        \\  category: ToolCategory;
        \\}
        \\
        \\export const AI_TOOLS: AiToolDef[] = [
        \\
    ;

    for (ai_tools.tools) |tool| {
        const Params = findParamsType(tool.rpc_method).?;
        r = r ++ "  {\n";
        r = r ++ "    name: \"" ++ tool.rpc_method ++ "\",\n";
        r = r ++ "    description: \"" ++ tool.description ++ "\",\n";
        r = r ++ "    parameters: " ++ paramsToJsonSchema(Params) ++ ",\n";
        r = r ++ "    rpcMethod: \"" ++ tool.rpc_method ++ "\",\n";
        if (tool.requires_confirmation) {
            r = r ++ "    requiresConfirmation: true,\n";
        }
        r = r ++ "    category: \"" ++ categoryToStr(tool.category) ++ "\",\n";
        r = r ++ "  },\n";
    }

    r = r ++ "];\n\n";

    // ── Helper functions ─────────────────────────────────────────
    r = r ++
        \\/** Sanitize tool name for OpenAI/Anthropic (only [a-zA-Z0-9_-] allowed). */
        \\function sanitizeName(name: string): string {
        \\  return name.replace(/\./g, "_");
        \\}
        \\
        \\export function toOpenAiTools(tools: AiToolDef[]) {
        \\  return tools.map((t) => ({
        \\    type: "function" as const,
        \\    function: { name: sanitizeName(t.name), description: t.description, parameters: t.parameters },
        \\  }));
        \\}
        \\
        \\export function toAnthropicTools(tools: AiToolDef[]) {
        \\  return tools.map((t) => ({
        \\    name: sanitizeName(t.name),
        \\    description: t.description,
        \\    input_schema: t.parameters,
        \\  }));
        \\}
        \\
        \\/** Find a tool by name (accepts both dotted and underscored forms). */
        \\export function findTool(name: string): AiToolDef | undefined {
        \\  const normalized = name.replace(/_/g, ".");
        \\  return AI_TOOLS.find((t) => t.name === name || t.name === normalized);
        \\}
        \\
    ;

    return r;
}
