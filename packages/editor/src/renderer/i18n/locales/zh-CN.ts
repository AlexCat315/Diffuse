import type { TranslationKeys } from "./en";

export const zhCN: TranslationKeys = {
  // ── Common ────────────────────────────────────────────
  common: {
    noEntitySelected: "未选择实体",
    notConnected: "未连接",
    loading: "加载中...",
    noResults: "无结果",
    name: "名称",
    cancel: "取消",
    confirm: "确认",
    delete: "删除",
    duplicate: "复制",
    rename: "重命名",
  },

  // ── Toolbar ───────────────────────────────────────────
  toolbar: {
    save: "保存场景 (Ctrl+S)",
    openScene: "打开场景...",
    undo: "撤销",
    redo: "重做",
    play: "播放",
    pause: "暂停",
    stop: "停止",
    translate: "移动 (W)",
    rotate: "旋转 (E)",
    scale: "缩放 (R)",
    brand: "Guava 编辑器",
    noScenesFound: "未找到场景",
  },

  // ── Scene Hierarchy ───────────────────────────────────
  hierarchy: {
    title: "场景层级",
    searchPlaceholder: "搜索实体...",
    noEntities: "无实体",
    noMatchingEntities: "无匹配实体",
    createEntity: "创建实体",
    createChild: "创建子实体",
    defaultEntityName: "新实体",
  },

  // ── Inspector ─────────────────────────────────────────
  inspector: {
    title: "检查器",
    entityLabel: "实体",
    entityNamePlaceholder: "实体名称",
    transform: "变换",
    position: "位置",
    rotation: "旋转",
    scale: "缩放",
    noEditableFields: "无可编辑字段",
  },

  // ── Console ───────────────────────────────────────────
  console: {
    title: "控制台",
    clearTooltip: "清空控制台",
    noLogs: "无日志",
    toggleLevel: "切换 {level}",
  },

  // ── Asset Browser ─────────────────────────────────────
  assets: {
    title: "资产",
    refreshTooltip: "刷新",
    emptyDirectory: "空目录",
    parentDirectory: "..",
  },

  // ── Render Settings ───────────────────────────────────
  renderSettings: {
    title: "渲染设置",
    shading: "着色",
    overlays: "叠加层",
    postProcessing: "后处理",
    colorGrading: "色彩校正",
    solid: "纯色",
    material: "材质",
    rendered: "渲染",
    wireframe: "线框",
    grid: "网格",
    bones: "骨骼",
    collision: "碰撞体",
    bloom: "泛光",
    threshold: "阈值",
    intensity: "强度",
    exposure: "曝光",
    value: "数值",
    ssao: "SSAO",
    radius: "半径",
    dof: "景深",
    focusDist: "对焦距离",
    focusRange: "对焦范围",
    fxaa: "FXAA",
    taa: "TAA",
    contactShadows: "接触阴影",
    saturation: "饱和度",
    contrast: "对比度",
    gamma: "伽马",
  },

  // ── Viewport ──────────────────────────────────────────
  viewport: {
    title: "视口",
    syncingEngine: "正在同步引擎窗口…",
    waitingForEngine: "等待引擎连接…",
  },

  // ── Viewport Status ───────────────────────────────────
  viewportStatus: {
    fps: "FPS",
    drawCalls: "绘制调用",
    triangles: "三角形",
  },

  // ── App-level ─────────────────────────────────────────
  app: {
    connectionError: "引擎连接错误",
    engineNotRunning: "请确保 guava-engine 以 --editor-server 参数运行",
    connectingToEngine: "正在连接引擎...",
    tabConsole: "控制台",
    tabAssets: "资产",
    tabTimeline: "时间线",
    tabUtilities: "AI 工具",
    tabSettings: "设置",
  },

  // ── Command Timeline ──────────────────────────────────
  commandTimeline: {
    title: "命令时间线",
    noHistory: "无撤销历史",
    current: "当前",
  },

  // ── Editor Utilities ─────────────────────────────────
  editorUtilities: {
    title: "AI 工具",
    runtimeUnavailable: "编辑器工具运行时不可用。",
    noUtilitiesLoaded: "未加载任何编辑器工具。使用 MCP compile_editor_utility 来添加。",
    loadedUtilities: "已加载工具",
    panelContent: "面板内容",
    noPanelsOpen: "当前没有打开的工具面板。请在上方切换工具开关以显示。",
    source: "来源",
    status: "状态",
    open: "打开",
    unload: "卸载",
    statusReady: "就绪",
    statusLoadError: "加载错误",
    statusInitError: "初始化错误",
    statusUpdateError: "更新错误",
  },
} as const;
