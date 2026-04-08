/**
 * AI Tool Definitions — maps RPC methods to LLM function-calling schemas.
 *
 * Each tool wraps an existing engine RPC method.  Adding a new RPC method to
 * the engine (via gen_types.zig → rpc-types.generated.ts) and then adding an
 * entry here is all that's needed to expose it to AI.
 *
 * NOTE: This file is a manual bridge.  Long-term it should be replaced by
 *       codegen from the Zig schema (Phase 2 of the AI-tool unification plan).
 */

import type { RpcMethodName } from "../../shared/rpc-types";

// ── Types ────────────────────────────────────────────────

/** JSON-Schema-like property descriptor (subset used by OpenAI / Anthropic). */
export interface JsonSchemaProperty {
  type: "string" | "number" | "integer" | "boolean" | "object" | "array";
  description?: string;
  enum?: string[];
  items?: JsonSchemaProperty;
  properties?: Record<string, JsonSchemaProperty>;
  required?: string[];
}

/** One tool that the AI can call. */
export interface AiToolDef {
  /** Tool name shown to the LLM (= RPC method name). */
  name: string;
  /** Human-readable description for the LLM. */
  description: string;
  /** JSON Schema for the parameters object. */
  parameters: {
    type: "object";
    properties: Record<string, JsonSchemaProperty>;
    required?: string[];
  };
  /** The RPC method to invoke when the tool is called. */
  rpcMethod: RpcMethodName;
  /** If true the AiChat UI will ask for user confirmation before executing. */
  requiresConfirmation?: boolean;
  /** Category for grouping in UI / system prompt. */
  category: ToolCategory;
}

export type ToolCategory =
  | "scene"
  | "entity"
  | "playback"
  | "script"
  | "asset"
  | "animation"
  | "material"
  | "camera"
  | "render"
  | "prefab"
  | "audio"
  | "query";

// ── Tool Catalog ─────────────────────────────────────────

export const AI_TOOLS: AiToolDef[] = [
  // ───── Scene ──────────────────────────
  {
    name: "scene.getHierarchy",
    description: "Get the full entity hierarchy of the current scene as a tree.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "scene.getHierarchy",
    category: "scene",
  },
  {
    name: "scene.createEntity",
    description: "Create a new entity in the scene. Optionally specify a parent.",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Name for the new entity" },
        parentId: { type: "integer", description: "Parent entity ID (omit for root)" },
      },
    },
    rpcMethod: "scene.createEntity",
    category: "scene",
  },
  {
    name: "scene.deleteEntity",
    description: "Delete an entity from the scene.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID to delete" },
      },
      required: ["entityId"],
    },
    rpcMethod: "scene.deleteEntity",
    requiresConfirmation: true,
    category: "scene",
  },
  {
    name: "scene.duplicateEntity",
    description: "Duplicate an entity (with all components and children).",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID to duplicate" },
      },
      required: ["entityId"],
    },
    rpcMethod: "scene.duplicateEntity",
    category: "scene",
  },
  {
    name: "scene.save",
    description: "Save the current scene to disk.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Optional save path override" },
      },
    },
    rpcMethod: "scene.save",
    category: "scene",
  },
  {
    name: "scene.load",
    description: "Load a scene file.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Scene file path to load" },
      },
      required: ["path"],
    },
    rpcMethod: "scene.load",
    requiresConfirmation: true,
    category: "scene",
  },
  {
    name: "scene.listScenes",
    description: "List all available scene files in the project.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "scene.listScenes",
    category: "scene",
  },

  // ───── Entity ─────────────────────────
  {
    name: "entity.getTransform",
    description: "Get an entity's position, rotation and scale.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
      },
      required: ["entityId"],
    },
    rpcMethod: "entity.getTransform",
    category: "entity",
  },
  {
    name: "entity.setTransform",
    description: "Set an entity's position, rotation and/or scale. Only specified fields are changed.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        transform: {
          type: "object",
          description: "Partial transform — include only fields you want to change",
          properties: {
            position: {
              type: "object",
              properties: {
                x: { type: "number" },
                y: { type: "number" },
                z: { type: "number" },
              },
            },
            rotation: {
              type: "object",
              properties: {
                x: { type: "number" },
                y: { type: "number" },
                z: { type: "number" },
                w: { type: "number" },
              },
            },
            scale: {
              type: "object",
              properties: {
                x: { type: "number" },
                y: { type: "number" },
                z: { type: "number" },
              },
            },
          },
        },
      },
      required: ["entityId", "transform"],
    },
    rpcMethod: "entity.setTransform",
    category: "entity",
  },
  {
    name: "entity.setName",
    description: "Rename an entity.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        name: { type: "string", description: "New name" },
      },
      required: ["entityId", "name"],
    },
    rpcMethod: "entity.setName",
    category: "entity",
  },
  {
    name: "entity.getComponents",
    description: "Get all components attached to an entity, with their field values.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
      },
      required: ["entityId"],
    },
    rpcMethod: "entity.getComponents",
    category: "entity",
  },
  {
    name: "entity.setComponentField",
    description: "Set a field value on a component of an entity.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        componentType: { type: "string", description: "Component type name (e.g. 'Rigidbody', 'Light')" },
        fieldName: { type: "string", description: "Field name within the component" },
        value: { type: "string", description: "New value (JSON-encoded)" },
      },
      required: ["entityId", "componentType", "fieldName", "value"],
    },
    rpcMethod: "entity.setComponentField",
    category: "entity",
  },
  {
    name: "entity.addComponent",
    description: "Add a component to an entity (e.g. Rigidbody, Light, Script, BoxCollider, SphereCollider, MeshCollider, PointLight, DirectionalLight).",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        componentType: { type: "string", description: "Component type to add" },
      },
      required: ["entityId", "componentType"],
    },
    rpcMethod: "entity.addComponent",
    category: "entity",
  },
  {
    name: "entity.removeComponent",
    description: "Remove a component from an entity.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        componentType: { type: "string", description: "Component type to remove" },
      },
      required: ["entityId", "componentType"],
    },
    rpcMethod: "entity.removeComponent",
    category: "entity",
  },
  {
    name: "entity.setVisible",
    description: "Show or hide an entity.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        visible: { type: "boolean", description: "Whether the entity should be visible" },
      },
      required: ["entityId", "visible"],
    },
    rpcMethod: "entity.setVisible",
    category: "entity",
  },
  {
    name: "entity.setAssetField",
    description: "Assign an asset (model, texture, script, etc.) to a component field on an entity.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        componentType: { type: "string", description: "Component type" },
        fieldName: { type: "string", description: "Field name" },
        assetPath: { type: "string", description: "Asset path (relative to project root)" },
      },
      required: ["entityId", "componentType", "fieldName"],
    },
    rpcMethod: "entity.setAssetField",
    category: "entity",
  },

  // ───── Playback ───────────────────────
  {
    name: "playback.play",
    description: "Start playing the scene (enter Play mode).",
    parameters: { type: "object", properties: {} },
    rpcMethod: "playback.play",
    category: "playback",
  },
  {
    name: "playback.pause",
    description: "Pause playback.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "playback.pause",
    category: "playback",
  },
  {
    name: "playback.stop",
    description: "Stop playback and return to edit mode.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "playback.stop",
    category: "playback",
  },

  // ───── Script ─────────────────────────
  {
    name: "script.listScripts",
    description: "List all script files in the project.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "script.listScripts",
    category: "script",
  },
  {
    name: "script.getContent",
    description: "Read the source code of a script file.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Script file path" },
      },
      required: ["path"],
    },
    rpcMethod: "script.getContent",
    category: "script",
  },
  {
    name: "script.saveContent",
    description: "Write source code to a script file. Creates the file if it doesn't exist.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Script file path" },
        content: { type: "string", description: "Full source code to write" },
      },
      required: ["path", "content"],
    },
    rpcMethod: "script.saveContent",
    category: "script",
  },

  // ───── Asset ──────────────────────────
  {
    name: "assets.list",
    description: "List files and folders in a project directory.",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "Directory path (omit for project root)" },
      },
    },
    rpcMethod: "assets.list",
    category: "asset",
  },

  // ───── Animation ──────────────────────
  {
    name: "animation.getState",
    description: "Get the animation graph state of an entity (states, transitions, parameters, clips).",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
      },
      required: ["entityId"],
    },
    rpcMethod: "animation.getState",
    category: "animation",
  },
  {
    name: "animation.addState",
    description: "Add a new animation state to an entity's animation graph.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        name: { type: "string", description: "State name" },
      },
      required: ["entityId"],
    },
    rpcMethod: "animation.addState",
    category: "animation",
  },
  {
    name: "animation.addTransition",
    description: "Add a transition between two animation states.",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        fromState: { type: "integer", description: "Source state index" },
        toState: { type: "integer", description: "Target state index" },
        duration: { type: "number", description: "Blend duration in seconds" },
      },
      required: ["entityId", "fromState", "toState"],
    },
    rpcMethod: "animation.addTransition",
    category: "animation",
  },

  // ───── Material ───────────────────────
  {
    name: "material.getState",
    description: "Get the material properties of an entity (color, metallic, roughness, etc.).",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
      },
      required: ["entityId"],
    },
    rpcMethod: "material.getState",
    category: "material",
  },
  {
    name: "material.setColor",
    description: "Set a color property on an entity's material (e.g. baseColor, emissive).",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        property: { type: "string", description: "Color property name (baseColor, emissive)" },
        value: {
          type: "array",
          description: "RGBA color as [r, g, b, a] with values 0-1",
          items: { type: "number" },
        },
      },
      required: ["entityId", "property", "value"],
    },
    rpcMethod: "material.setColor",
    category: "material",
  },
  {
    name: "material.setScalar",
    description: "Set a scalar material property (metallic, roughness, alphaCutoff, etc.).",
    parameters: {
      type: "object",
      properties: {
        entityId: { type: "integer", description: "Entity ID" },
        property: { type: "string", description: "Property name" },
        value: { type: "number", description: "Value" },
      },
      required: ["entityId", "property", "value"],
    },
    rpcMethod: "material.setScalar",
    category: "material",
  },

  // ───── Camera ─────────────────────────
  {
    name: "camera.getState",
    description: "Get the current editor camera position and rotation.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "camera.getState",
    category: "camera",
  },
  {
    name: "camera.lookAlongAxis",
    description: "Point the editor camera along an axis (e.g. top-down, front, side view).",
    parameters: {
      type: "object",
      properties: {
        axisX: { type: "number" },
        axisY: { type: "number" },
        axisZ: { type: "number" },
        distance: { type: "number", description: "Distance from target" },
        targetX: { type: "number" },
        targetY: { type: "number" },
        targetZ: { type: "number" },
      },
      required: ["axisX", "axisY", "axisZ"],
    },
    rpcMethod: "camera.lookAlongAxis",
    category: "camera",
  },

  // ───── Prefab ─────────────────────────
  {
    name: "prefab.list",
    description: "List all prefabs in the project.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "prefab.list",
    category: "prefab",
  },
  {
    name: "prefab.instantiate",
    description: "Instantiate a prefab at a position in the scene.",
    parameters: {
      type: "object",
      properties: {
        prefabId: { type: "string", description: "Prefab asset ID" },
        posX: { type: "number" },
        posY: { type: "number" },
        posZ: { type: "number" },
      },
      required: ["prefabId"],
    },
    rpcMethod: "prefab.instantiate",
    category: "prefab",
  },

  // ───── Audio ──────────────────────────
  {
    name: "audio.getMixerStatus",
    description: "Get the audio mixer status (buses, volumes, active voices).",
    parameters: { type: "object", properties: {} },
    rpcMethod: "audio.getMixerStatus",
    category: "audio",
  },

  // ───── Editor ─────────────────────────
  {
    name: "editor.undo",
    description: "Undo the last action.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "editor.undo",
    category: "scene",
  },
  {
    name: "editor.redo",
    description: "Redo the last undone action.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "editor.redo",
    category: "scene",
  },
  {
    name: "editor.getHistory",
    description: "Get the undo/redo history list.",
    parameters: { type: "object", properties: {} },
    rpcMethod: "editor.getHistory",
    category: "scene",
  },
];

// ── Helpers ──────────────────────────────────────────────

/** Convert our tool definitions to OpenAI function-calling format. */
export function toOpenAiTools(tools: AiToolDef[]) {
  return tools.map((t) => ({
    type: "function" as const,
    function: {
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    },
  }));
}

/** Convert our tool definitions to Anthropic tool format. */
export function toAnthropicTools(tools: AiToolDef[]) {
  return tools.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: t.parameters,
  }));
}

/** Lookup a tool by name. */
export function findTool(name: string): AiToolDef | undefined {
  return AI_TOOLS.find((t) => t.name === name);
}
