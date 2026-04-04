///! Comptime TypeScript code generator.
///!
///! Reads rpc_schema.zig at compile time and emits fully typed TypeScript
///! definitions.  No runtime reflection — all work happens in comptime.
///!
///! Usage (from packages/engine/):
///!   zig run tools/gen_rpc_types.zig > ../editor/src/shared/rpc-types.generated.ts
///!
const std = @import("std");
const schema = @import("rpc_schema.zig");

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
        \\// ║  Source of truth: src/engine/editor_rpc/rpc_schema.zig   ║
        \\// ║  Regenerate:                                             ║
        \\// ║    zig run src/engine/editor_rpc/gen_types.zig \        ║
        \\// ║      2> ../editor/src/shared/rpc-types.generated.ts      ║
        \\// ╚═══════════════════════════════════════════════════════════╝
        \\
        \\
    ;

    // ── Shared data types ────────────────────────────────────────
    r = r ++ "// ── Data Types ─────────────────────────────────────────────\n\n";
    for (@typeInfo(schema.SharedTypes).@"struct".decls) |decl| {
        if (comptime std.mem.eql(u8, decl.name, "JsonValue")) continue;
        r = r ++ emitInterface(decl.name, @field(schema.SharedTypes, decl.name));
    }

    // ── RPC method map ───────────────────────────────────────────
    r = r ++ "// ── RPC Method Signatures ──────────────────────────────────\n\n";
    r = r ++ "export interface RpcMethods {\n";
    for (@typeInfo(schema.Methods).@"struct".decls) |decl| {
        const M = @field(schema.Methods, decl.name);
        r = r ++ "  \"" ++ decl.name ++ "\": { params: " ++ typeToTs(M.Params) ++ "; result: " ++ typeToTs(M.Result) ++ " };\n";
    }
    r = r ++ "}\n\n";

    // ── Subscription events ──────────────────────────────────────
    r = r ++ "// ── Subscription Events ───────────────────────────────────\n\n";
    r = r ++ "export interface SubscriptionEvents {\n";
    for (@typeInfo(schema.Subscriptions).@"struct".decls) |decl| {
        r = r ++ "  \"" ++ decl.name ++ "\": " ++ typeToTs(@field(schema.Subscriptions, decl.name)) ++ ";\n";
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

    return r;
}

// ═══════════════════════════════════════════════════════════════════
//  Type → TypeScript conversion
// ═══════════════════════════════════════════════════════════════════

fn typeToTs(comptime T: type) []const u8 {
    // Opaque sentinel → unknown
    if (T == schema.SharedTypes.JsonValue) return "unknown";

    // Named shared type?
    for (@typeInfo(schema.SharedTypes).@"struct".decls) |decl| {
        if (T == @field(schema.SharedTypes, decl.name)) return decl.name;
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
