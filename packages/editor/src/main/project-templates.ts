import fs from "fs";
import path from "path";

export interface ProjectTemplate {
  id: string;
  name: string;
  description: string;
  icon: string;
}

export const PROJECT_TEMPLATES: ProjectTemplate[] = [
  {
    id: "empty",
    name: "Empty Project",
    description: "A blank project with the basic folder structure. No scene content.",
    icon: "📄",
  },
  {
    id: "3d-basic",
    name: "3D Basic",
    description: "A simple 3D scene with a camera, directional light, a ground plane, and a cube.",
    icon: "🎲",
  },
];

/** Null entity template — all component fields set to null. */
function nullEntity(name: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name,
    parent: null,
    local_transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] },
    camera: null,
    mesh: null,
    skinned_mesh: null,
    animator: null,
    animator_targets: null,
    skinned_mesh_targets: null,
    animation_graph: null,
    animation_graph_instance: null,
    rigidbody: null,
    box_collider: null,
    sphere_collider: null,
    mesh_collider: null,
    material: null,
    light: null,
    vfx: null,
    script: null,
    audio_source: null,
    audio_listener: null,
    nav_agent: null,
    visible: true,
    editor_only: false,
    dont_destroy_on_load: false,
    is_folder: false,
    ...overrides,
  };
}

function randomHexId(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function generateBasic3DScene(): string {
  const sceneId = randomHexId();
  const cubeMeshId = randomHexId();
  const groundMeshId = randomHexId();
  const defaultMaterialId = randomHexId();
  const groundMaterialId = randomHexId();

  const scene = {
    version: 7,
    scene: {
      version: 6,
      scene_id: sceneId,
      environment_asset_id: null,
      asset_records: [
        {
          id: cubeMeshId,
          type: "mesh",
          source_path: "builtin://mesh/cube",
          source_hash: "8d997575e78ae4ef38fb34002a04b1d1144e90f7f05a7604267f607282cd7e90",
          import_settings_hash: "30b08ae5ad5ce2dcaf5f447ad85a72950eb91682dacfd37fdd843861d85b767d",
          import_version: 1,
          dependency_ids: [],
          outputs: [],
          metadata: { display_name: "BuiltinCube", importer: "embedded-mesh-v1", source_extension: "" },
          version: 2,
        },
        {
          id: groundMeshId,
          type: "mesh",
          source_path: "scene://embedded/meshes/Ground",
          source_hash: "9312437d1fcac62c3c986e2838f519ca6369797b9775aab8116642307634eba8",
          import_settings_hash: "30b08ae5ad5ce2dcaf5f447ad85a72950eb91682dacfd37fdd843861d85b767d",
          import_version: 1,
          dependency_ids: [],
          outputs: [],
          metadata: { display_name: "Ground", importer: "embedded-mesh-v1", source_extension: "" },
          version: 2,
        },
        {
          id: defaultMaterialId,
          type: "material",
          source_path: "scene://embedded/materials/DefaultMaterial",
          source_hash: "f9c5a607c6d15d49fc28cd642b6b2d897c934816c24b0bd4e3752073c61df7f8",
          import_settings_hash: "8bbd2a2a1940c492da1b6ca785b34e93c963c9c4b2466cf561349186c1efe852",
          import_version: 1,
          dependency_ids: [],
          outputs: [],
          metadata: { display_name: "DefaultMaterial", importer: "embedded-material-v1", source_extension: "" },
          version: 2,
        },
        {
          id: groundMaterialId,
          type: "material",
          source_path: "scene://embedded/materials/GroundMaterial",
          source_hash: "5f93820ee941b8df6ddfa4d79dc0a5c5ec99bb4cdd869fcee29251656e145bff",
          import_settings_hash: "8bbd2a2a1940c492da1b6ca785b34e93c963c9c4b2466cf561349186c1efe852",
          import_version: 1,
          dependency_ids: [],
          outputs: [],
          metadata: { display_name: "GroundMaterial", importer: "embedded-material-v1", source_extension: "" },
          version: 2,
        },
      ],
      meshes: [],
      textures: [],
      materials: [],
      skeletons: [],
      skins: [],
      animation_clips: [],
      scripts: [],
      entities: [
        nullEntity("MainCamera", {
          local_transform: { translation: [0, 1.5, 5], rotation: [0, 0, 0, 1], scale: [1, 1, 1] },
          camera: {
            projection: {
              perspective: { fov_y_radians: 1.0471975803375244, near_clip: 0.1, far_clip: 1000 },
            },
            is_primary: true,
          },
        }),
        nullEntity("Sun", {
          local_transform: {
            translation: [0, 0, 0],
            rotation: [-0.4155, 0.2661, 0.1285, 0.8602],
            scale: [1, 1, 1],
          },
          light: { kind: "directional", color: [1, 0.985, 0.95], intensity: 3.25, range: 10 },
        }),
        nullEntity("Ground", {
          local_transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [20, 0.1, 20] },
          mesh: { asset_id: groundMeshId, primitive: "cube" },
          material: {
            asset_id: groundMaterialId,
            shading: "pbr_metallic_roughness",
            base_color_factor: [0.35, 0.38, 0.42, 1.0],
            emissive_factor: [0, 0, 0],
            metallic_factor: 0.0,
            roughness_factor: 0.9,
            alpha_cutoff: 0.5,
            double_sided: false,
          },
        }),
        nullEntity("Cube", {
          local_transform: { translation: [0, 1, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] },
          mesh: { asset_id: cubeMeshId, primitive: "cube" },
          material: {
            asset_id: defaultMaterialId,
            shading: "pbr_metallic_roughness",
            base_color_factor: [0.8, 0.8, 0.8, 1.0],
            emissive_factor: [0, 0, 0],
            metallic_factor: 0.0,
            roughness_factor: 0.8,
            alpha_cutoff: 0.5,
            double_sided: false,
          },
        }),
      ],
    },
    runtime_state: {
      global_time: 0.0,
      time_scale: 1.0,
      physics_accumulator_seconds: 0.0,
      playback_state: "stopped",
      game_state: "game_start",
    },
  };

  return JSON.stringify(scene, null, 2);
}

function generateEmptyScene(): string {
  const sceneId = randomHexId();
  const scene = {
    version: 7,
    scene: {
      version: 6,
      scene_id: sceneId,
      environment_asset_id: null,
      asset_records: [],
      meshes: [],
      textures: [],
      materials: [],
      skeletons: [],
      skins: [],
      animation_clips: [],
      scripts: [],
      entities: [
        nullEntity("MainCamera", {
          local_transform: { translation: [0, 1.5, 5], rotation: [0, 0, 0, 1], scale: [1, 1, 1] },
          camera: {
            projection: {
              perspective: { fov_y_radians: 1.0471975803375244, near_clip: 0.1, far_clip: 1000 },
            },
            is_primary: true,
          },
        }),
        nullEntity("DirectionalLight", {
          local_transform: {
            translation: [0, 0, 0],
            rotation: [-0.4155, 0.2661, 0.1285, 0.8602],
            scale: [1, 1, 1],
          },
          light: { kind: "directional", color: [1, 0.985, 0.95], intensity: 3.0, range: 10 },
        }),
      ],
    },
    runtime_state: {
      global_time: 0.0,
      time_scale: 1.0,
      physics_accumulator_seconds: 0.0,
      playback_state: "stopped",
      game_state: "game_start",
    },
  };

  return JSON.stringify(scene, null, 2);
}

/**
 * Apply a template to a project directory.
 * Assumes the directory structure (.guava, Content/Scenes, Derived) already exists.
 */
export function applyTemplate(projectPath: string, templateId: string): void {
  const scenesDir = path.join(projectPath, "Content", "Scenes");
  const scenePath = path.join(scenesDir, "Main.guava_scene");

  // Ensure directory exists
  fs.mkdirSync(scenesDir, { recursive: true });

  switch (templateId) {
    case "3d-basic":
      fs.writeFileSync(scenePath, generateBasic3DScene(), "utf-8");
      break;
    case "empty":
    default:
      fs.writeFileSync(scenePath, generateEmptyScene(), "utf-8");
      break;
  }
}
