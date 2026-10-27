# Diffuse Website

Diffuse 官方网站，使用 **Vue 3 + TypeScript + Vite** 构建。

> 上游项目：[Diffuse](../) — 基于 Swift 构建、以 AI Agent 驱动的综合创作工作站：文本与代码编辑、游戏开发、动画制作和视频剪辑。

## 技术栈

| 类别 | 选型 |
|------|------|
| 框架 | Vue 3（`<script setup>`） |
| 语言 | TypeScript 5（strict） |
| 构建 | Vite 5 |
| 路由 | Vue Router 4 |
| 状态 | Pinia |
| 动效 | GSAP、CSS 3D 动画、Canvas 2D |
| 文档 | Markdown（`?raw` 导入）+ marked 渲染 |

## 快速开始

```bash
npm install
npm run dev        # 开发服务器 http://localhost:5174
```

## 构建与预览

```bash
npm run build      # 类型检查 + 生产构建（输出到 dist/）
npm run preview    # 预览生产构建
```

## 目录结构

```
Website/
├── public/
│   └── favicon.svg             # 站点图标
├── src/
│   ├── components/
│   │   ├── TheNav.vue          # 顶部导航
│   │   ├── TheFooter.vue       # 页脚
│   │   ├── ParticleField.vue   # 虹彩粒子光场 Canvas
│   │   ├── AgentChat.vue       # Agent 打字机对话演示
│   │   ├── TiltCard.vue        # 3D 倾斜卡片包装器
│   │   └── CodeBlock.vue       # 代码块（高亮 + 复制）
│   ├── content/                # 文档 Markdown
│   │   ├── build.md
│   │   ├── architecture.md
│   │   └── agent-runtime.md
│   ├── directives/
│   │   └── reveal.ts           # v-reveal 滚动入场
│   ├── router/index.ts
│   ├── styles/main.css         # Iridescence 主题
│   ├── utils/
│   │   ├── docs.ts             # 文档目录清单
│   │   ├── highlight.ts        # 语法高亮
│   │   └── markdown.ts         # marked 渲染
│   ├── views/
│   │   ├── HomeView.vue        # 首页
│   │   ├── WorkflowsView.vue   # 四大工作流详情
│   │   ├── PluginsView.vue     # 插件生态
│   │   ├── DownloadView.vue    # 下载 / 构建
│   │   ├── DocsView.vue        # 文档站
│   │   └── NotFoundView.vue    # 404
│   ├── App.vue
│   ├── env.d.ts
│   └── main.ts
├── index.html
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## 页面与功能

- **首页**：粒子光场背景、Agent 实时对话演示（打字机 + 工具调用）、四大工作流、引擎能力、视频管线时间线。
- **工作流**：四大工作流的详细功能点卡片。
- **插件生态**：原生 / WASM / MCP 三类插件、扩展市场、安全保障。
- **下载**：前置依赖、平台构建命令（一键复制）、第三方依赖清单。
- **文档站**：三栏布局、Markdown 渲染、代码块复制、翻页导航、移动端抽屉。

## 设计与动效

- **主题：Iridescence（虹彩）**——深紫黑底，紫 → 粉 → 橙霓虹渐变与光晕。
- 粒子随鼠标发光、相互连线（"漫反射"网络），DPR 自适应，页面隐藏时暂停。
- Agent 对话循环演示意图解析与工具调用；卡片 3D 倾斜 + 移动高光；滚动入场与时间线动效。
- 全站响应式。

## 如何修改文档

编辑 `src/content/*.md`，并在 `src/utils/docs.ts` 中登记侧边栏条目即可。

## 许可

与上游 Diffuse 一致，采用 Apache License 2.0。
