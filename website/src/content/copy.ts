import type { Locale } from '@/types/content'

export const repositoryUrl = 'https://github.com/AlexCat315/GuavaStudio'

export const copy = {
  zh: {
    languageName: '中文',
    nav: { features: '能力', docs: '文档', blog: '动态', roadmap: '路线图', community: '社区', download: '下载' },
    actions: { getStarted: '开始构建', download: '下载编辑器', explore: '探索能力', viewAll: '查看全部', github: '在 GitHub 查看' },
    home: {
      eyebrow: 'AI-NATIVE · SWIFT · WEBGPU',
      title: '让创作意图，直接成为可运行的世界。',
      description: 'GuavaStudio 是以 AI Agent 驱动的开源创作工作站，整合文本与代码编辑、游戏开发、动画制作和视频剪辑。人与 Agent 共用文件、场景和媒体操作。',
      conceptLabel: '概念界面 · 非实际产品截图',
      capabilitiesTitle: '一套工作站，连接代码与创作',
      capabilitiesIntro: '从场景搭建到运行时，从声明式 UI 到 AI 协作，核心能力都围绕同一个可理解、可编辑的世界。',
      workflowTitle: '从想法到可玩世界，只需三步',
      releaseTitle: '构建已经在路上',
      releaseIntro: '获取最新的跨平台编辑器构建，或从源码开始探索。',
      roadmapTitle: '透明演进，持续交付',
      communityTitle: '和创作者一起构建',
    },
    features: {
      eyebrow: 'WORKSTATION CAPABILITIES',
      title: '为创作者设计，而不是为管线妥协。',
      description: 'GuavaStudio 把文档、媒体、渲染、场景、UI、物理与 AI 能力组织成可组合的 Swift 模块。',
    },
    download: {
      eyebrow: 'LATEST BUILDS',
      title: '选择你的平台，开始创造。',
      description: 'Release 构建直接来自 GuavaStudio 的公开 GitHub 发布页。项目仍处于早期阶段，建议保留源码构建能力。',
      sourceTitle: '从源码构建',
      sourceDescription: '需要 Swift 6.1+、CMake 3.20+、C/C++ 工具链和 Git。首次构建会编译原生依赖。',
    },
    blog: { eyebrow: 'PROJECT LOG', title: '构建日志', description: '记录 GuavaStudio 的版本、设计决策与创作工作流。' },
    community: {
      eyebrow: 'OPEN SOURCE COMMUNITY',
      title: '工作站属于每一位建设者。',
      description: '阅读代码、提出问题、贡献实现，或者把你的第一个 Guava 项目分享给社区。',
      contribute: '参与贡献',
      issue: '报告问题',
      contributors: '贡献者',
    },
    search: { label: '搜索', placeholder: '搜索文档与动态…', empty: '没有找到相关内容', hint: '按 Esc 关闭' },
    github: { stale: '当前显示缓存数据，GitHub 实时数据暂时不可用。', latest: '最新版本', stars: 'Stars', forks: 'Forks' },
    footer: { tagline: '连接代码、游戏、动画与视频的 AI Agent 工作站。', license: 'Apache-2.0 开源许可' },
  },
  en: {
    languageName: 'English',
    nav: { features: 'Features', docs: 'Docs', blog: 'Updates', roadmap: 'Roadmap', community: 'Community', download: 'Download' },
    actions: { getStarted: 'Get started', download: 'Download editor', explore: 'Explore features', viewAll: 'View all', github: 'View on GitHub' },
    home: {
      eyebrow: 'AI-NATIVE · SWIFT · WEBGPU',
      title: 'Turn creative intent into a world that runs.',
      description: 'GuavaStudio is an open-source workstation driven by AI agents, bringing text and code editing, game development, animation, and video editing into one workspace. People and agents share file, scene, and media operations.',
      conceptLabel: 'Concept UI · not a product screenshot',
      capabilitiesTitle: 'One workstation for code and creation',
      capabilitiesIntro: 'Scene authoring, runtime, declarative UI, and AI collaboration all operate on the same understandable and editable world.',
      workflowTitle: 'From an idea to a playable world in three steps',
      releaseTitle: 'Working builds, available today',
      releaseIntro: 'Get the latest cross-platform editor build or start from source.',
      roadmapTitle: 'Transparent progress, continuous delivery',
      communityTitle: 'Built together with creators',
    },
    features: {
      eyebrow: 'WORKSTATION CAPABILITIES',
      title: 'Designed for creators, not pipeline compromises.',
      description: 'Guava organizes rendering, scene, UI, physics, film, and AI capabilities as composable Swift modules.',
    },
    download: {
      eyebrow: 'LATEST BUILDS',
      title: 'Choose a platform and start creating.',
      description: 'Release builds come directly from the public GuavaStudio GitHub releases. The project is early-stage, so keeping a source build available is recommended.',
      sourceTitle: 'Build from source',
      sourceDescription: 'Requires Swift 6.1+, CMake 3.20+, a C/C++ toolchain, and Git. The first build compiles native dependencies.',
    },
    blog: { eyebrow: 'PROJECT LOG', title: 'Build log', description: 'Releases, design decisions, and creative workflows from GuavaStudio.' },
    community: {
      eyebrow: 'OPEN SOURCE COMMUNITY',
      title: 'The engine belongs to its builders.',
      description: 'Read the code, report an issue, contribute an implementation, or share your first Guava project.',
      contribute: 'Contribute',
      issue: 'Report an issue',
      contributors: 'Contributors',
    },
    search: { label: 'Search', placeholder: 'Search docs and updates…', empty: 'No matching content', hint: 'Press Esc to close' },
    github: { stale: 'Showing cached data while GitHub is unavailable.', latest: 'Latest release', stars: 'Stars', forks: 'Forks' },
    footer: { tagline: 'An AI-native 3D engine for creators and agents.', license: 'Open source under Apache-2.0' },
  },
} as const satisfies Record<Locale, object>

export const capabilities = {
  zh: [
    ['语义世界', '场景不是静态快照，而是持续维护的语义图；属性、关系与变更都有明确含义。'],
    ['实时 3D', 'NativeRHI 渲染、Jolt 物理与 SDL 平台层组成跨平台运行时基础。'],
    ['GuavaUI', 'SwiftUI 风格的声明式 UI，与引擎共享设备、输入和渲染生命周期。'],
    ['AI 协作', 'Intent、Proposal 与 Edit 构成可验证、可预览、可追溯的创作变更。'],
    ['影视管线', '序列、路径追踪、EXR 与色彩模块为镜头级制作保留同一世界上下文。'],
    ['开放模块', 'Engine、GuavaUI、Editor 与 MCP 均以独立 Swift 包和清晰依赖边界组织。'],
  ],
  en: [
    ['Semantic world', 'The scene is a continuously maintained semantic graph with explicit properties, relationships, and edits.'],
    ['Real-time 3D', 'NativeRHI rendering, Jolt physics, and an SDL platform layer form the cross-platform runtime foundation.'],
    ['GuavaUI', 'A SwiftUI-style declarative UI sharing the engine device, input, and rendering lifecycle.'],
    ['AI collaboration', 'Intent, Proposal, and Edit create a validated, previewable, and traceable authoring loop.'],
    ['Film pipeline', 'Sequence, path tracing, EXR, and color modules preserve world context through shot production.'],
    ['Open modules', 'Engine, GuavaUI, Editor, and MCP are organized as independent Swift packages with clear boundaries.'],
  ],
} as const

export const workflow = {
  zh: [['01', '描述意图', '用自然语言或直接操作表达你想改变的世界。'], ['02', '验证与预览', '引擎检查前置条件，并为高影响变更保留确认边界。'], ['03', '运行与迭代', '同一个世界模型进入编辑器、游戏运行时和后续 AI 会话。']],
  en: [['01', 'Describe intent', 'Express a world change through natural language or direct manipulation.'], ['02', 'Validate and preview', 'The engine checks preconditions and keeps confirmation boundaries for impactful changes.'], ['03', 'Run and iterate', 'The same world model flows into the editor, game runtime, and future AI sessions.']],
} as const

export const roadmapSummary = {
  zh: [['已完成', '编辑器基础工作流、场景与资产、GuavaUI、实时渲染'], ['进行中', '跨平台打包、角色控制、物理深度与 AI 骨架'], ['规划中', '语义管线、图生场景、影视深度渲染与长期记忆']],
  en: [['Shipped', 'Editor foundations, scene and assets, GuavaUI, real-time rendering'], ['In progress', 'Cross-platform packaging, character control, physics depth, and AI foundations'], ['Planned', 'Semantic pipeline, scene from image, film rendering depth, and long-session memory']],
} as const
