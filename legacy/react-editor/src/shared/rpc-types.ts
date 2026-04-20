/**
 * RPC type barrel — re-exports auto-generated types + frontend-only types.
 *
 * Auto-generated types come from rpc-types.generated.ts (source: rpc_schema.zig).
 * Manual types below are frontend-only and not part of the engine schema.
 */

// ── Re-export everything from the generated schema ─────────────────

export type {
  Vec3,
  Quat,
  Transform,
  TransformPartial,
  EntityNode,
  ComponentField as ComponentFieldBase,
  LogEntry,
  AssetEntry,
  AnimGraphState,
  AnimGraphTransition,
  AnimTransitionCondition,
  AnimGraphParameter,
  AnimClipTrack,
  MaterialGraphNodeInfo,
  MaterialGraphConnectionInfo,
  MaterialGraphOutputInfo,
  ScriptFileInfo,
  VfxEntityInfo,
  VfxConfig,
  PrefabInfo,
  PrefabEntityNode,
  PrefabEntityDetail,
  SubscriptionEvents,
  SubscriptionName,
  JsonRpcRequest,
  JsonRpcResponse,
} from "./rpc-types.generated";

import type {
  ComponentInfo as GeneratedComponentInfo,
  RpcMethods as GeneratedRpcMethods,
  RpcResult as GeneratedRpcResult,
} from "./rpc-types.generated";

// ── Extended types (fields the engine supports but the schema hasn't caught up) ──

export interface ComponentInfo extends GeneratedComponentInfo {
  scriptIndex?: number;
}

export interface RpcMethods extends GeneratedRpcMethods {
  "entity.getComponents": {
    params: { entityId: number };
    result: { components: ComponentInfo[] };
  };
  "entity.setAssetField": {
    params: {
      entityId: number;
      componentType: string;
      fieldName: string;
      assetPath?: string;
      scriptIndex?: number;
    };
    result: Record<string, never>;
  };
  "script.getEntityParameters": {
    params: { entityId: number; scriptIndex: number };
    result: { parameters?: string | null };
  };
  "script.setEntityParameters": {
    params: { entityId: number; scriptIndex: number; parameters: string };
    result: Record<string, never>;
  };
  "assets.importModel": {
    params: { sourcePath: string; targetDir?: string };
    result: { success: boolean; assetPath?: string };
  };
}

export type RpcMethodName = keyof RpcMethods;
export type RpcParams<M extends RpcMethodName> = RpcMethods[M]["params"];
export type RpcResult<M extends RpcMethodName> = RpcMethods[M]["result"];

/** History entry — extracted from the getHistory result shape. */
export type HistoryEntry = RpcResult<"editor.getHistory">["entries"][number];

// JSON-RPC 2.0 Notification (server push, no id field)
export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: Record<string, unknown>;
}

// ── Frontend-only types (not in engine schema) ─────────────────────

export type GizmoMode = "translate" | "rotate" | "scale" | "none";
export type RenderMode = "textured" | "wireframe" | "unlit" | "normals" | "depth";

export type FieldType =
  | "float"
  | "int"
  | "bool"
  | "string"
  | "vec3"
  | "vec4"
  | "color"
  | "enum"
  | "asset_ref"
  | "entity_ref";

export interface ComponentField {
  name: string;
  fieldType: FieldType;
  value: unknown;
  options?: string[];
  min?: number;
  max?: number;
  step?: number;
  assetType?: string;
  sourcePath?: string;
}

export type AssetType =
  | "model"
  | "texture"
  | "material"
  | "scene"
  | "script"
  | "shader"
  | "audio"
  | "prefab"
  | "animation";

export type EditorUtilityStatus = "ready" | "load_error" | "init_error" | "update_error";

export interface EditorUtilitySnapshot {
  handle: number;
  name: string;
  description: string;
  sourcePath: string;
  status: EditorUtilityStatus;
  lastError: string;
  open: boolean;
}

export const ErrorCode = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  ResourceNotFound: -32002,
} as const;
