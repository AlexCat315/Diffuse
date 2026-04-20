/**
 * AI Tool Definitions — re-exports from the auto-generated file.
 *
 * Source of truth: `pub const ai_tool` declarations inside schema structs.
 * See the manifest at the top of rpc-types.generated.ts for a full list.
 * Regenerate:  cd packages/engine && zig run src/engine/editor_rpc/gen_types.zig \
 *                2> ../editor/src/shared/rpc-types.generated.ts
 */

export {
  type AiToolDef,
  type ToolCategory,
  AI_TOOLS,
  toOpenAiTools,
  toAnthropicTools,
  findTool,
} from "../../shared/rpc-types.generated";
