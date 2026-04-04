export const en = {
  // ── Common ────────────────────────────────────────────
  common: {
    noEntitySelected: "No entity selected",
    notConnected: "Not connected",
    loading: "Loading...",
    noResults: "No results",
    name: "Name",
    cancel: "Cancel",
    confirm: "Confirm",
    delete: "Delete",
    duplicate: "Duplicate",
    rename: "Rename",
  },

  // ── Toolbar ───────────────────────────────────────────
  toolbar: {
    save: "Save Scene (Ctrl+S)",
    openScene: "Open Scene...",
    undo: "Undo",
    redo: "Redo",
    play: "Play",
    pause: "Pause",
    stop: "Stop",
    translate: "Translate (W)",
    rotate: "Rotate (E)",
    scale: "Scale (R)",
    brand: "Guava Editor",
    noScenesFound: "No scenes found",
  },

  // ── Scene Hierarchy ───────────────────────────────────
  hierarchy: {
    title: "Scene Hierarchy",
    searchPlaceholder: "Search entities...",
    noEntities: "No entities",
    noMatchingEntities: "No matching entities",
    createEntity: "Create Entity",
    createChild: "Create Child",
    defaultEntityName: "New Entity",
  },

  // ── Inspector ─────────────────────────────────────────
  inspector: {
    title: "Inspector",
    entityLabel: "Entity",
    entityNamePlaceholder: "Entity name",
    transform: "Transform",
    position: "Position",
    rotation: "Rotation",
    scale: "Scale",
    noEditableFields: "No editable fields",
  },

  // ── Console ───────────────────────────────────────────
  console: {
    title: "Console",
    clearTooltip: "Clear console",
    noLogs: "No logs",
    toggleLevel: "Toggle {level}",
  },

  // ── Asset Browser ─────────────────────────────────────
  assets: {
    title: "Assets",
    refreshTooltip: "Refresh",
    emptyDirectory: "Empty directory",
    parentDirectory: "..",
  },

  // ── Render Settings ───────────────────────────────────
  renderSettings: {
    title: "Render Settings",
    shading: "Shading",
    overlays: "Overlays",
    postProcessing: "Post-Processing",
    colorGrading: "Color Grading",
    // Shading modes
    solid: "Solid",
    material: "Material",
    rendered: "Rendered",
    wireframe: "Wireframe",
    // Overlays
    grid: "Grid",
    bones: "Bones",
    collision: "Collision",
    // Post-processing
    bloom: "Bloom",
    threshold: "Threshold",
    intensity: "Intensity",
    exposure: "Exposure",
    value: "Value",
    ssao: "SSAO",
    radius: "Radius",
    dof: "DOF",
    focusDist: "Focus Dist",
    focusRange: "Focus Range",
    fxaa: "FXAA",
    taa: "TAA",
    contactShadows: "Contact Shadows",
    // Color grading
    saturation: "Saturation",
    contrast: "Contrast",
    gamma: "Gamma",
  },

  // ── Viewport ──────────────────────────────────────────
  viewport: {
    title: "Viewport",
    syncingEngine: "Syncing engine window…",
    waitingForEngine: "Waiting for engine connection…",
  },

  // ── Viewport Status ───────────────────────────────────
  viewportStatus: {
    fps: "FPS",
    drawCalls: "draws",
    triangles: "tris",
  },

  // ── App-level ─────────────────────────────────────────
  app: {
    connectionError: "Engine Connection Error",
    engineNotRunning: "Make sure guava-engine is running with --editor-server",
    connectingToEngine: "Connecting to engine...",
    tabConsole: "Console",
    tabAssets: "Assets",
    tabTimeline: "Timeline",
    tabUtilities: "AI Utilities",
    tabSettings: "Settings",
  },

  // ── Command Timeline ──────────────────────────────────
  commandTimeline: {
    title: "Command Timeline",
    noHistory: "No undo history",
    current: "Current",
  },

  // ── Editor Utilities ─────────────────────────────────
  editorUtilities: {
    title: "AI Utilities",
    runtimeUnavailable: "Editor utility runtime is not available.",
    noUtilitiesLoaded: "No editor utilities are loaded. Use MCP compile_editor_utility to add one.",
    loadedUtilities: "Loaded Utilities",
    panelContent: "Panel Content",
    noPanelsOpen: "No utility panels are currently open. Toggle a utility above to display it here.",
    source: "Source",
    status: "Status",
    open: "Open",
    unload: "Unload",
    statusReady: "Ready",
    statusLoadError: "Load Error",
    statusInitError: "Init Error",
    statusUpdateError: "Update Error",
  },
};

type DeepStringRecord<T> = {
  [K in keyof T]: T[K] extends Record<string, unknown> ? DeepStringRecord<T[K]> : string;
};

export type TranslationKeys = DeepStringRecord<typeof en>;
