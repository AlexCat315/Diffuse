# AI Tools Reference

> **Auto-generated** — do not edit manually.
> To expose a new tool, add `pub const ai_tool: types.AiTool = .{ ... };` inside the RPC method struct.
> Regenerate: `cd packages/engine && zig run src/engine/editor_rpc/gen_types.zig > ../../docs/api/ai-tools.md 2> ../editor/src/shared/rpc-types.generated.ts`

Total: **37** tools

## Scene

| Method | Description | Confirm? |
|--------|-------------|----------|
| `editor.undo` | Undo the last action. | No |
| `editor.redo` | Redo the last undone action. | No |
| `editor.getHistory` | Get the undo/redo history list. | No |
| `scene.getHierarchy` | Get the full entity hierarchy of the current scene as a tree. | No |
| `scene.createEntity` | Create a new entity in the scene. Optionally specify a name and parent. | No |
| `scene.deleteEntity` | Delete an entity from the scene. | ⚠️ Yes |
| `scene.duplicateEntity` | Duplicate an entity (with all components and children). | No |
| `scene.save` | Save the current scene to disk. | No |
| `scene.load` | Load a scene file. | ⚠️ Yes |
| `scene.listScenes` | List all available scene files in the project. | No |

## Entity

| Method | Description | Confirm? |
|--------|-------------|----------|
| `entity.getTransform` | Get an entity's position, rotation and scale. | No |
| `entity.setTransform` | Set an entity's position, rotation and/or scale. Only specified fields are changed. | No |
| `entity.setName` | Rename an entity. | No |
| `entity.getComponents` | Get all components attached to an entity, with their field names and values. Use field names from the result when calling entity.setComponentField. | No |
| `entity.setComponentField` | Set a field value on a component. Use exact field names from entity.getComponents. Works for scalars, arrays, and enums. For Mesh.primitive valid values: `cube`, `sphere`, `plane`. For material colors prefer material.setColor. | No |
| `entity.addComponent` | Add a component to an entity. Valid types: Camera, Mesh, SkinnedMesh, Animator, Rigidbody, BoxCollider, SphereCollider, MeshCollider, CapsuleCollider, CharacterController, Tag, Sky, Constraint, Material, Light, Vfx, Script, AudioSource, AudioListener, NavAgent. Components are added with default values. After adding Mesh, you MUST call entity.setComponentField to set primitive to `cube`, `sphere`, or `plane` — otherwise it defaults to `custom` (no geometry). | No |
| `entity.removeComponent` | Remove a component from an entity. | No |
| `entity.setVisible` | Show or hide an entity. | No |
| `entity.setAssetField` | Assign an asset to a component field. Params: entityId, componentType, fieldName, assetPath (string\|null to clear). For Sky.environment_asset_id pass the asset path. For Script, use optional scriptIndex. | No |

## Playback

| Method | Description | Confirm? |
|--------|-------------|----------|
| `playback.play` | Start playing the scene (enter Play mode). | No |
| `playback.pause` | Pause playback. | No |
| `playback.stop` | Stop playback and return to edit mode. | No |

## Script

| Method | Description | Confirm? |
|--------|-------------|----------|
| `script.listScripts` | List all script files in the project. | No |
| `script.getContent` | Read the source code of a script file. | No |
| `script.saveContent` | Write source code to a script file. Creates the file if it doesn't exist. | No |

## Asset

| Method | Description | Confirm? |
|--------|-------------|----------|
| `assets.list` | List files and folders in a project directory. | No |

## Animation

| Method | Description | Confirm? |
|--------|-------------|----------|
| `animation.getState` | Get the animation graph state of an entity. | No |
| `animation.addState` | Add a new animation state to an entity's animation graph. Optional name param, defaults to 'State N'. Returns the new state index. | No |
| `animation.addTransition` | Add a transition between animation states. Params: entityId, fromState (index), toState (index), optional duration (default 0.2), optional triggerTime (default 0.25). Returns transition index. | No |

## Material

| Method | Description | Confirm? |
|--------|-------------|----------|
| `material.getState` | Get material properties: baseColor [4]f32, emissive [3]f32, metallic, roughness, alphaCutoff, doubleSided, texture handles, etc. Note: property names in getState use camelCase but setColor/setScalar use snake_case. | No |
| `material.setColor` | Set a color property on an entity's material. property must be `base_color` or `emissive`. value is [r,g,b,a] with floats 0-1. | No |
| `material.setScalar` | Set a scalar material property. property must be `metallic`, `roughness`, `alpha_cutoff`, or `ibl_intensity`. value is a float. | No |

## Camera

| Method | Description | Confirm? |
|--------|-------------|----------|
| `camera.getState` | Get the current editor camera position and rotation. | No |
| `camera.lookAlongAxis` | Point the editor camera along a direction. Params: axisX, axisY, axisZ (floats). Common: top-down (0,-1,0), front (0,0,-1), right (1,0,0). | No |

## Prefab

| Method | Description | Confirm? |
|--------|-------------|----------|
| `prefab.list` | List all prefabs in the project. | No |
| `prefab.instantiate` | Instantiate a prefab at a position in the scene. | No |

## Audio

| Method | Description | Confirm? |
|--------|-------------|----------|
| `audio.getMixerStatus` | Get the audio mixer status (buses, volumes, active voices). | No |

