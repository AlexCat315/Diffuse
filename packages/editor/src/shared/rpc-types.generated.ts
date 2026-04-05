// ╔═══════════════════════════════════════════════════════════╗
// ║  AUTO-GENERATED — do not edit manually.                  ║
// ║  Source of truth: src/engine/editor_rpc/schema/           ║
// ║  Regenerate:                                             ║
// ║    zig run src/engine/editor_rpc/gen_types.zig \        ║
// ║      2> ../editor/src/shared/rpc-types.generated.ts      ║
// ╚═══════════════════════════════════════════════════════════╝

// ── Data Types ─────────────────────────────────────────────

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface Quat {
  x: number;
  y: number;
  z: number;
  w: number;
}

export interface Transform {
  position: Vec3;
  rotation: Quat;
  scale: Vec3;
}

export interface TransformPartial {
  position?: Vec3;
  rotation?: Quat;
  scale?: Vec3;
}

export interface EntityNode {
  id: number;
  name: string;
  visible: boolean;
  children: EntityNode[];
}

export interface ComponentInfo {
  type: string;
  fields: ComponentField[];
}

export interface ComponentField {
  name: string;
  fieldType: string;
  value: unknown;
  options?: string[];
}

export interface LogEntry {
  level: string;
  message: string;
  timestamp: number;
  source?: string;
}

export interface AssetEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  assetType?: string;
  size?: number;
}

export interface ScriptFileInfo {
  path: string;
  name: string;
  language: string;
  sizeBytes: number;
}

export interface SequencerTrack {
  index: number;
  kind: string;
  target: string;
}

export interface AnimGraphState {
  index: number;
  name: string;
  clipName?: string;
  speed: number;
  loop: boolean;
  duration: number;
  isDefault: boolean;
  isCurrent: boolean;
  isNext: boolean;
}

export interface AnimGraphTransition {
  index: number;
  fromState: number;
  toState: number;
  fromStateName: string;
  toStateName: string;
  duration: number;
  conditions: AnimTransitionCondition[];
}

export interface AnimTransitionCondition {
  index: number;
  conditionType: string;
  threshold: number;
  parameterName?: string;
  comparison?: string;
}

export interface AnimGraphParameter {
  index: number;
  name: string;
  paramType: string;
  floatValue?: number;
  boolValue?: boolean;
  intValue?: number;
}

export interface AnimClipTrack {
  index: number;
  name: string;
  trackType: string;
  keyframeCount: number;
}

export interface MaterialGraphNodeInfo {
  id: number;
  kind: string;
  outputType: string;
  channel?: string;
  valueKind: string;
  scalar: number;
  vec2: unknown /* [2]f64 */;
  vec3: unknown /* [3]f64 */;
  vec4: unknown /* [4]f64 */;
  textureHandle?: number;
  posX: number;
  posY: number;
}

export interface MaterialGraphConnectionInfo {
  fromNodeId: number;
  fromSlot: number;
  toNodeId: number;
  toSlot: number;
}

export interface MaterialGraphOutputInfo {
  channel: string;
  sourceNodeId: number;
  sourceSlot: number;
}

export interface VfxEntityInfo {
  entityId: number;
  name: string;
  kind: string;
}

export interface VfxConfig {
  kind: string;
  looping: boolean;
  emissionRate: number;
  particleLifetime: number;
  speed: number;
  maxParticles: number;
  radius: number;
  spread: number;
  size: number;
  colorR: number;
  colorG: number;
  colorB: number;
}

export interface PrefabInfo {
  id: string;
  name: string;
  version: number;
  entityCount: number;
  sourcePath?: string;
}

export interface PrefabEntityNode {
  prefabEntityId: number;
  name: string;
  parentId?: number;
  visible: boolean;
  isFolder: boolean;
  hasTransform: boolean;
  hasMesh: boolean;
  hasMaterial: boolean;
  hasLight: boolean;
  hasCamera: boolean;
  hasScript: boolean;
  hasVfx: boolean;
}

export interface PrefabEntityDetail {
  prefabEntityId: number;
  name: string;
  visible: boolean;
  isFolder: boolean;
  posX: number;
  posY: number;
  posZ: number;
  rotX: number;
  rotY: number;
  rotZ: number;
  rotW: number;
  scaleX: number;
  scaleY: number;
  scaleZ: number;
  components: string[];
}

// ── RPC Method Signatures ──────────────────────────────────

export interface RpcMethods {
  "editor.ping": { params: Record<string, never>; result: { pong: boolean } };
  "editor.getCapabilities": { params: Record<string, never>; result: { version: string; methods: string[]; subscriptions: string[] } };
  "editor.setSelection": { params: { entityIds: number[] }; result: Record<string, never> };
  "editor.undo": { params: Record<string, never>; result: Record<string, never> };
  "editor.redo": { params: Record<string, never>; result: Record<string, never> };
  "editor.getHistory": { params: Record<string, never>; result: { cursor: number; entries: { sequence: number; label: string; source: string; detail?: string; timestampMs: number }[] } };
  "editor.timeTravel": { params: { targetSequence: number }; result: Record<string, never> };
  "scene.getHierarchy": { params: Record<string, never>; result: { roots: EntityNode[] } };
  "scene.createEntity": { params: { name?: string; parentId?: number }; result: { entityId: number } };
  "scene.deleteEntity": { params: { entityId: number }; result: Record<string, never> };
  "scene.duplicateEntity": { params: { entityId: number }; result: { entityId: number } };
  "scene.save": { params: { path?: string }; result: { path: string } };
  "scene.load": { params: { path: string }; result: { path: string } };
  "scene.listScenes": { params: Record<string, never>; result: { scenes: string[] } };
  "scene.spawnActor": { params: { kind: string }; result: { entityId: number } };
  "entity.getTransform": { params: { entityId: number }; result: Transform };
  "entity.setTransform": { params: { entityId: number; transform: TransformPartial }; result: Record<string, never> };
  "entity.setName": { params: { entityId: number; name: string }; result: Record<string, never> };
  "entity.getComponents": { params: { entityId: number }; result: { components: ComponentInfo[] } };
  "entity.setComponentField": { params: { entityId: number; componentType: string; fieldName: string; value: unknown }; result: Record<string, never> };
  "entity.addComponent": { params: { entityId: number; componentType: string }; result: Record<string, never> };
  "entity.removeComponent": { params: { entityId: number; componentType: string }; result: Record<string, never> };
  "playback.play": { params: Record<string, never>; result: Record<string, never> };
  "playback.pause": { params: Record<string, never>; result: Record<string, never> };
  "playback.stop": { params: Record<string, never>; result: Record<string, never> };
  "console.clear": { params: Record<string, never>; result: Record<string, never> };
  "viewport.setGizmoMode": { params: { mode: string }; result: Record<string, never> };
  "viewport.setRect": { params: { x: number; y: number; width: number; height: number }; result: Record<string, never> };
  "viewport.getWindowInfo": { params: Record<string, never>; result: { x: number; y: number; width: number; height: number; drawableWidth: number; drawableHeight: number; nativeHandle: number; platform: string } };
  "viewport.attachToParent": { params: { parentHandle: number }; result: Record<string, never> };
  "viewport.detachFromParent": { params: Record<string, never>; result: Record<string, never> };
  "viewport.getSurfaceId": { params: Record<string, never>; result: { surfaceId: number; width: number; height: number; shmName?: string } };
  "viewport.getRenderSettings": { params: Record<string, never>; result: { shadingMode: string; showGrid: boolean; showBones: boolean; showCollision: boolean; bloomEnabled: boolean; bloomThreshold: number; bloomIntensity: number; exposureEnabled: boolean; exposure: number; ssaoEnabled: boolean; ssaoRadius: number; ssaoIntensity: number; ssaoBias: number; ssaoPower: number; fxaaEnabled: boolean; taaEnabled: boolean; taaBlendFactor: number; taaMotionBlurScale: number; taaFeedbackMin: number; taaFeedbackMax: number; contactShadowsEnabled: boolean; contactShadowsDistance: number; contactShadowsThickness: number; contactShadowsIntensity: number; contactShadowsBias: number; contactShadowsSteps: number; ssrEnabled: boolean; ssrIntensity: number; ssrRayStep: number; ssrMaxDistance: number; ssrThickness: number; ssrFadeDistance: number; ssrEdgeFade: number; ssrRoughnessBlur: number; ssgiEnabled: boolean; ssgiRadius: number; ssgiIntensity: number; ssgiBias: number; ssgiRayCount: number; ssgiStepCount: number; colorGradingEnabled: boolean; colorGradingSaturation: number; colorGradingContrast: number; colorGradingGamma: number; dofEnabled: boolean; dofFocusDistance: number; dofFocusRange: number; dofBlurRadius: number; dofBokehRadius: number; dofNearBlur: number; dofFarBlur: number; dofQuality: number; lutEnabled: boolean; lutIntensity: number; lutPreset: string; volumetricFogEnabled: boolean; volumetricFogDensity: number; volumetricFogHeightFalloff: number; volumetricFogMaxDistance: number; rtShadowsEnabled: boolean; rtShadowSamples: number; rtShadowStrength: number; rtShadowSoftness: number; rtShadowResolutionScale: number } };
  "viewport.setRenderSettings": { params: { shadingMode?: string; showGrid?: boolean; showBones?: boolean; showCollision?: boolean; bloomEnabled?: boolean; bloomThreshold?: number; bloomIntensity?: number; exposureEnabled?: boolean; exposure?: number; ssaoEnabled?: boolean; ssaoRadius?: number; ssaoIntensity?: number; ssaoBias?: number; ssaoPower?: number; fxaaEnabled?: boolean; taaEnabled?: boolean; taaBlendFactor?: number; taaMotionBlurScale?: number; taaFeedbackMin?: number; taaFeedbackMax?: number; contactShadowsEnabled?: boolean; contactShadowsDistance?: number; contactShadowsThickness?: number; contactShadowsIntensity?: number; contactShadowsBias?: number; contactShadowsSteps?: number; ssrEnabled?: boolean; ssrIntensity?: number; ssrRayStep?: number; ssrMaxDistance?: number; ssrThickness?: number; ssrFadeDistance?: number; ssrEdgeFade?: number; ssrRoughnessBlur?: number; ssgiEnabled?: boolean; ssgiRadius?: number; ssgiIntensity?: number; ssgiBias?: number; ssgiRayCount?: number; ssgiStepCount?: number; colorGradingEnabled?: boolean; colorGradingSaturation?: number; colorGradingContrast?: number; colorGradingGamma?: number; dofEnabled?: boolean; dofFocusDistance?: number; dofFocusRange?: number; dofBlurRadius?: number; dofBokehRadius?: number; dofNearBlur?: number; dofFarBlur?: number; dofQuality?: number; lutEnabled?: boolean; lutIntensity?: number; lutPreset?: string; volumetricFogEnabled?: boolean; volumetricFogDensity?: number; volumetricFogHeightFalloff?: number; volumetricFogMaxDistance?: number; rtShadowsEnabled?: boolean; rtShadowSamples?: number; rtShadowStrength?: number; rtShadowSoftness?: number; rtShadowResolutionScale?: number }; result: Record<string, never> };
  "viewport.sendInput": { params: { type: string; x?: number; y?: number; deltaX?: number; deltaY?: number; button?: string; clicks?: number; key?: string; shift?: boolean; ctrl?: boolean; alt?: boolean }; result: Record<string, never> };
  "viewport.pick": { params: { x: number; y: number; mode?: string }; result: Record<string, never> };
  "viewport.boxSelect": { params: { x1: number; y1: number; x2: number; y2: number; mode?: string }; result: { selectedIds: number[] } };
  "viewport.setFrameRate": { params: { fps: number }; result: Record<string, never> };
  "viewport.getFrameRate": { params: Record<string, never>; result: { fps: number; frameDelayMs: number } };
  "rendersettings.getSettings": { params: Record<string, never>; result: { shadingMode: string; transformSpace: string; showGrid: boolean; showBones: boolean; showCollision: boolean; pathTrace: { samples: number; bounces: number; resolutionScale: number }; viewportSize: { width: number; height: number }; renderOutput: { preset: string; width: number; height: number; format: string; path: string } } };
  "rendersettings.setShadingMode": { params: { mode: string }; result: Record<string, never> };
  "rendersettings.setTransformSpace": { params: { space: string }; result: Record<string, never> };
  "rendersettings.setOverlay": { params: { key: string; value: boolean }; result: Record<string, never> };
  "rendersettings.setPathTrace": { params: { samples?: number; bounces?: number; resolutionScale?: number }; result: Record<string, never> };
  "rendersettings.applyPtPreset": { params: { preset: string }; result: Record<string, never> };
  "rendersettings.setRenderOutput": { params: { preset?: string; width?: number; height?: number; format?: string; path?: string }; result: Record<string, never> };
  "camera.listBookmarks": { params: Record<string, never>; result: { bookmarks: { index: number; name: string; position: Vec3; rotation: Quat; fov: number }[] } };
  "camera.addBookmark": { params: { name?: string }; result: { index: number } };
  "camera.removeBookmark": { params: { index: number }; result: Record<string, never> };
  "camera.applyBookmark": { params: { index: number }; result: Record<string, never> };
  "camera.renameBookmark": { params: { index: number; name: string }; result: Record<string, never> };
  "camera.getState": { params: Record<string, never>; result: { position: Vec3; rotation: Quat } };
  "camera.lookAlongAxis": { params: { axisX: number; axisY: number; axisZ: number; distance?: number; targetX?: number; targetY?: number; targetZ?: number }; result: Record<string, never> };
  "camera.orbit": { params: { deltaYaw: number; deltaPitch: number }; result: Record<string, never> };
  "assets.list": { params: { path?: string }; result: { path: string; entries: AssetEntry[] } };
  "script.listScripts": { params: Record<string, never>; result: { scripts: ScriptFileInfo[] } };
  "script.getContent": { params: { path: string }; result: { content: string; language: string; readOnly: boolean } };
  "script.saveContent": { params: { path: string; content: string }; result: { success: boolean } };
  "utilities.list": { params: Record<string, never>; result: { utilities: { handle: number; name: string; description: string; sourcePath: string; status: string; open: boolean; lastError: string }[] } };
  "utilities.setOpen": { params: { handle: number; open: boolean }; result: Record<string, never> };
  "utilities.remove": { params: { handle: number }; result: Record<string, never> };
  "plugin.list": { params: Record<string, never>; result: { plugins: { name: string; pluginType: string; source: string; lifecycle: string; lastError?: string }[] } };
  "plugin.enable": { params: { name: string }; result: Record<string, never> };
  "plugin.disable": { params: { name: string }; result: Record<string, never> };
  "plugin.unload": { params: { name: string }; result: Record<string, never> };
  "plugin.rescan": { params: { path?: string }; result: Record<string, never> };
  "prefab.list": { params: Record<string, never>; result: { prefabs: PrefabInfo[] } };
  "prefab.getEntities": { params: { prefabId: string }; result: { found: boolean; entities: PrefabEntityNode[] } };
  "prefab.getEntityDetail": { params: { prefabId: string; prefabEntityId: number }; result: { found: boolean; entity?: PrefabEntityDetail } };
  "prefab.setEntityTransform": { params: { prefabId: string; prefabEntityId: number; posX?: number; posY?: number; posZ?: number; rotX?: number; rotY?: number; rotZ?: number; rotW?: number; scaleX?: number; scaleY?: number; scaleZ?: number }; result: { success: boolean } };
  "prefab.setEntityField": { params: { prefabId: string; prefabEntityId: number; field: string; value: string }; result: { success: boolean } };
  "prefab.create": { params: { entityId: number; name: string }; result: { success: boolean; prefabId?: string } };
  "prefab.instantiate": { params: { prefabId: string; posX?: number; posY?: number; posZ?: number }; result: { success: boolean; entityId?: number } };
  "prefab.save": { params: { prefabId: string }; result: { success: boolean } };
  "prefab.delete": { params: { prefabId: string }; result: { success: boolean } };
  "particle.listVfxEntities": { params: Record<string, never>; result: { entities: VfxEntityInfo[] } };
  "particle.getConfig": { params: { entityId: number }; result: { found: boolean; config?: VfxConfig } };
  "particle.setConfig": { params: { entityId: number; kind?: string; looping?: boolean; emissionRate?: number; particleLifetime?: number; speed?: number; maxParticles?: number; radius?: number; spread?: number; size?: number; colorR?: number; colorG?: number; colorB?: number }; result: { success: boolean } };
  "particle.applyPreset": { params: { entityId: number; preset: string }; result: { success: boolean } };
  "material.getState": { params: { entityId: number }; result: { hasMaterial: boolean; name?: string; shading?: string; baseColor?: unknown /* [4]f32 */; emissive?: unknown /* [3]f32 */; metallic?: number; roughness?: number; alphaCutoff?: number; doubleSided?: boolean; useIBL?: boolean; iblIntensity?: number; texBaseColor?: number; texMetallicRoughness?: number; texNormal?: number; texOcclusion?: number; texEmissive?: number; isShared?: boolean; materialHandle?: number; parentHandle?: number; generation?: number; previewPrimitive?: string } };
  "material.setShading": { params: { entityId: number; mode: string }; result: Record<string, never> };
  "material.setColor": { params: { entityId: number; property: string; value: unknown /* [4]f32 */ }; result: Record<string, never> };
  "material.setScalar": { params: { entityId: number; property: string; value: number }; result: Record<string, never> };
  "material.setFlag": { params: { entityId: number; property: string; value: boolean }; result: Record<string, never> };
  "material.assignTexture": { params: { entityId: number; slot: string; textureHandle: number }; result: Record<string, never> };
  "material.clearTexture": { params: { entityId: number; slot: string }; result: Record<string, never> };
  "material.makeUnique": { params: { entityId: number }; result: { newHandle: number; wasShared: boolean; generation?: number } };
  "material.getTextureInfo": { params: { textureHandle: number }; result: { found: boolean; name?: string; width?: number; height?: number; format?: string } };
  "material.listTextures": { params: Record<string, never>; result: { textures: { handle: number; name: string; width: number; height: number }[] } };
  "material.setPreviewPrimitive": { params: { primitive: string }; result: Record<string, never> };
  "material.getGraph": { params: { entityId: number }; result: { hasGraph: boolean; nodes?: MaterialGraphNodeInfo[]; connections?: MaterialGraphConnectionInfo[]; outputs?: MaterialGraphOutputInfo[] } };
  "material.addGraphNode": { params: { entityId: number; kind: string; posX: number; posY: number }; result: { nodeId: number } };
  "material.removeGraphNode": { params: { entityId: number; nodeId: number }; result: Record<string, never> };
  "material.updateGraphNode": { params: { entityId: number; nodeId: number; channel?: string; outputType?: string; valueKind?: string; scalar?: number; vec2?: unknown /* [2]f64 */; vec3?: unknown /* [3]f64 */; vec4?: unknown /* [4]f64 */; textureHandle?: number }; result: Record<string, never> };
  "material.addGraphConnection": { params: { entityId: number; fromNodeId: number; fromSlot: number; toNodeId: number; toSlot: number }; result: Record<string, never> };
  "material.removeGraphConnection": { params: { entityId: number; fromNodeId: number; fromSlot: number; toNodeId: number; toSlot: number }; result: Record<string, never> };
  "material.setGraphOutput": { params: { entityId: number; channel: string; sourceNodeId: number; sourceSlot: number }; result: Record<string, never> };
  "material.removeGraphOutput": { params: { entityId: number; channel: string }; result: Record<string, never> };
  "material.setNodePosition": { params: { entityId: number; nodeId: number; posX: number; posY: number }; result: Record<string, never> };
  "style.getActiveStyle": { params: Record<string, never>; result: { name: string; displayName: string; meshProgram: string; shadowProgram?: string; source: string; path?: string; disabledPasses: string[]; configSchema: { name: string; displayName: string; paramType: string; defaultValue: number; minValue: number; maxValue: number }[]; paramValues: { name: string; value: number }[] } };
  "style.listStyles": { params: Record<string, never>; result: { styles: { name: string; displayName: string; source: string; isActive: boolean }[] } };
  "style.setActiveStyle": { params: { name: string }; result: Record<string, never> };
  "style.setParam": { params: { styleName: string; paramName: string; value: number }; result: Record<string, never> };
  "renderqueue.listJobs": { params: Record<string, never>; result: { jobs: { index: number; sequencePath: string; outputDir: string; width: number; height: number; format: string; samples: number; bounces: number; usePathTrace: boolean; encodeVideo: boolean; videoCodec: string; status: string; totalFrames: number; currentFrame: number; statusMessage: string }[]; isRunning: boolean } };
  "renderqueue.addJob": { params: { sequencePath: string; outputDir?: string; width?: number; height?: number; format?: string; samples?: number; bounces?: number; usePathTrace?: boolean; encodeVideo?: boolean; videoCodec?: string }; result: { index: number } };
  "renderqueue.removeJob": { params: { index: number }; result: Record<string, never> };
  "renderqueue.startQueue": { params: Record<string, never>; result: Record<string, never> };
  "renderqueue.cancelQueue": { params: Record<string, never>; result: Record<string, never> };
  "renderqueue.clearCompleted": { params: Record<string, never>; result: Record<string, never> };
  "debug.getRhiStats": { params: Record<string, never>; result: { bindingCache: { hits: number; misses: number; evictions: number; entries: number; maxEntries: number; hitRate: number; frameHits: number; frameMisses: number; frameEvictions: number }; passes: { name: string; status: string }[] } };
  "debug.resetRhiStats": { params: Record<string, never>; result: Record<string, never> };
  "audio.getMixerStatus": { params: Record<string, never>; result: { available: boolean; activeVoices: number; buses: { id: string; label: string; volume: number; playing: number }[] } };
  "audio.setBusVolume": { params: { busId: string; volume: number }; result: Record<string, never> };
  "physicsviz.getSettings": { params: Record<string, never>; result: { drawMode: string; opacity: number; velocityScale: number; wireframeOnly: boolean; showCollisionShapes: boolean; showRigidbodies: boolean; showTriggers: boolean; showConstraints: boolean; showVelocityVectors: boolean; showSleepState: boolean; showAabbs: boolean; colorStatic: unknown /* [4]f32 */; colorDynamic: unknown /* [4]f32 */; colorKinematic: unknown /* [4]f32 */; colorTrigger: unknown /* [4]f32 */; colorSleeping: unknown /* [4]f32 */; colorConstraint: unknown /* [4]f32 */ } };
  "physicsviz.setDrawMode": { params: { mode: string }; result: Record<string, never> };
  "physicsviz.setToggle": { params: { key: string; value: boolean }; result: Record<string, never> };
  "physicsviz.setFloat": { params: { key: string; value: number }; result: Record<string, never> };
  "physicsviz.setColor": { params: { key: string; r: number; g: number; b: number; a: number }; result: Record<string, never> };
  "animation.getState": { params: { entityId: number }; result: { hasAnimator: boolean; hasGraph: boolean; graphName?: string; currentState?: number; nextState?: number; blendFactor?: number; transitionTime?: number; transitionDuration?: number; defaultState?: number; states?: AnimGraphState[]; transitions?: AnimGraphTransition[]; parameters?: AnimGraphParameter[]; clipTracks?: AnimClipTrack[]; clipDuration?: number; sampleTime?: number } };
  "animation.addState": { params: { entityId: number; name?: string }; result: { index: number } };
  "animation.updateState": { params: { entityId: number; stateIndex: number; name?: string; clip?: string; speed?: number; loop?: boolean; duration?: number }; result: Record<string, never> };
  "animation.removeState": { params: { entityId: number; stateIndex: number }; result: Record<string, never> };
  "animation.setDefaultState": { params: { entityId: number; stateIndex: number }; result: Record<string, never> };
  "animation.activateState": { params: { entityId: number; stateIndex: number }; result: Record<string, never> };
  "animation.addTransition": { params: { entityId: number; fromState: number; toState: number; duration?: number; triggerTime?: number }; result: { index: number } };
  "animation.updateTransition": { params: { entityId: number; transitionIndex: number; fromState?: number; toState?: number; duration?: number }; result: Record<string, never> };
  "animation.removeTransition": { params: { entityId: number; transitionIndex: number }; result: Record<string, never> };
  "animation.addCondition": { params: { entityId: number; transitionIndex: number; conditionType: string; threshold?: number; parameterName?: string; comparison?: string }; result: { index: number } };
  "animation.updateCondition": { params: { entityId: number; transitionIndex: number; conditionIndex: number; conditionType?: string; threshold?: number; parameterName?: string; comparison?: string }; result: Record<string, never> };
  "animation.removeCondition": { params: { entityId: number; transitionIndex: number; conditionIndex: number }; result: Record<string, never> };
  "animation.setParameter": { params: { entityId: number; parameterIndex: number; floatValue?: number; boolValue?: boolean; intValue?: number }; result: Record<string, never> };
  "sequencer.getState": { params: Record<string, never>; result: { loaded: boolean; name?: string; fps?: number; duration?: number; currentTime: number; isPlaying: boolean; speed: number; filePath?: string; tracks?: SequencerTrack[] } };
  "sequencer.create": { params: { name?: string; fps?: number }; result: { ok: boolean } };
  "sequencer.load": { params: { path: string }; result: { ok: boolean; error?: string } };
  "sequencer.save": { params: { path?: string }; result: { ok: boolean; error?: string } };
  "sequencer.setProperties": { params: { name?: string; fps?: number; duration?: number }; result: Record<string, never> };
  "sequencer.addTrack": { params: { kind: string; target: string }; result: { index: number } };
  "sequencer.removeTrack": { params: { index: number }; result: Record<string, never> };
  "sequencer.updateTrack": { params: { index: number; clipPath?: string; startTime?: number; endTime?: number; blendIn?: number; blendOut?: number; speed?: number; volume?: number; fadeIn?: number; fadeOut?: number; property?: string }; result: Record<string, never> };
  "sequencer.addKeyframe": { params: { trackIndex: number; time: number; position?: unknown /* [3]f64 */; rotation?: unknown /* [4]f64 */; fov?: number; easing?: string; value?: number; name?: string }; result: { count?: number; error?: string } };
  "sequencer.removeKeyframe": { params: { trackIndex: number; keyframeIndex: number }; result: { error?: string } };
  "sequencer.updateKeyframe": { params: { trackIndex: number; keyframeIndex: number; time?: number; position?: unknown /* [3]f64 */; rotation?: unknown /* [4]f64 */; fov?: number; easing?: string; value?: number; name?: string }; result: Record<string, never> };
  "sequencer.play": { params: Record<string, never>; result: Record<string, never> };
  "sequencer.pause": { params: Record<string, never>; result: Record<string, never> };
  "sequencer.stop": { params: Record<string, never>; result: Record<string, never> };
  "sequencer.seek": { params: { time: number }; result: Record<string, never> };
  "sequencer.setSpeed": { params: { speed: number }; result: Record<string, never> };
  "sequencer.recomputeDuration": { params: Record<string, never>; result: { duration: number } };
  "mesh.getState": { params: Record<string, never>; result: { active: boolean; mode: string; selectionMode: string; selectionCount: number; canEnterEditMode: boolean; entityId?: number } };
  "mesh.enterEditMode": { params: { entityId: number }; result: { success: boolean } };
  "mesh.exitEditMode": { params: Record<string, never>; result: Record<string, never> };
  "mesh.setSelectionMode": { params: { mode: string }; result: Record<string, never> };
  "mesh.extrude": { params: Record<string, never>; result: { success: boolean } };
  "mesh.inset": { params: Record<string, never>; result: { success: boolean } };
  "mesh.bevel": { params: Record<string, never>; result: { success: boolean } };
  "mesh.loopCut": { params: Record<string, never>; result: { success: boolean } };
  "mesh.merge": { params: Record<string, never>; result: { success: boolean } };
  "mesh.delete": { params: Record<string, never>; result: { success: boolean } };
  "mesh.duplicate": { params: Record<string, never>; result: { success: boolean } };
  "mesh.separate": { params: Record<string, never>; result: { success: boolean } };
  "mesh.recalcNormals": { params: Record<string, never>; result: { success: boolean } };
  "mesh.pivotToSelection": { params: Record<string, never>; result: { success: boolean } };
}

// ── Subscription Events ───────────────────────────────────

export interface SubscriptionEvents {
  "on:scene.changed": { revision: number; entityIds: number[] };
  "on:selection.changed": { entityIds: number[] };
  "on:console.log": LogEntry;
  "on:console.logs": { entries: LogEntry[] };
  "on:viewport.metrics": { fps: number; frameTimeMs: number; drawCalls: number; triangles: number; frameDelayMs: number };
  "on:playback.stateChanged": { state: string };
  "on:asset.changed": { assetId: string; changeType: string };
  "on:editor.historyChanged": { cursor: number; totalEntries: number };
  "on:mesh.stateChanged": { active: boolean; mode: string; selectionMode: string; selectionCount: number; canEnterEditMode: boolean; entityId?: number };
}

// ── Convenience Aliases ───────────────────────────────────

export type RpcMethodName = keyof RpcMethods;
export type SubscriptionName = keyof SubscriptionEvents;

export type RpcParams<M extends RpcMethodName> = RpcMethods[M]["params"];
export type RpcResult<M extends RpcMethodName> = RpcMethods[M]["result"];

// ── JSON-RPC 2.0 Wire Format ─────────────────────────────

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}
