<script setup lang="ts">
import { Bot, Box, Cpu, Film, Gauge, Layers3, Network, Palette, Sparkles, WandSparkles } from '@lucide/vue'
import { capabilities } from '@/content/copy'
import { useLocale } from '@/composables/useLocale'

const { locale, t } = useLocale()
const icons = [Network, Gauge, Palette, Bot, Film, Layers3]
const systems = locale.value === 'zh'
  ? [['场景与物理', 'SceneRuntime · Jolt Physics', '实体、组件、调度、空间查询、角色控制与序列化。'], ['渲染与平台', 'RHIWGPU · RenderBackend · SDL3', '共享 WebGPU 设备、渲染提交和跨平台窗口输入层。'], ['创作界面', 'GuavaUI · EditorCore', '声明式组件、工作区布局、层级、检查器、资产与视口。'], ['AI 运行时', 'Intent · Capability · Observation', '把信号、能力、提案、确认和编辑组织成统一变更路径。']]
  : [['Scene & physics', 'SceneRuntime · Jolt Physics', 'Entities, components, schedules, spatial queries, character control, and serialization.'], ['Rendering & platform', 'RHIWGPU · RenderBackend · SDL3', 'A shared WebGPU device, render submission, and cross-platform window/input layer.'], ['Creative interface', 'GuavaUI · EditorCore', 'Declarative components, workspace layout, hierarchy, inspector, assets, and viewport.'], ['AI runtime', 'Intent · Capability · Observation', 'Signals, capabilities, proposals, confirmation, and edits in one change path.']]
</script>

<template>
  <main>
    <section class="page-hero section-shell"><p class="eyebrow"><Sparkles :size="14" /> {{ t.features.eyebrow }}</p><h1>{{ t.features.title }}</h1><p>{{ t.features.description }}</p></section>
    <section class="section-shell feature-detail-grid">
      <article v-for="(item, index) in capabilities[locale]" :key="item[0]"><component :is="icons[index]" :size="25" /><div><span>0{{ index + 1 }}</span><h2>{{ item[0] }}</h2><p>{{ item[1] }}</p></div></article>
    </section>
    <section class="architecture-band section-space"><div class="section-shell"><div class="section-heading"><p class="eyebrow">COMPOSABLE BY DESIGN</p><h2>{{ locale === 'zh' ? '清晰边界，共享同一个世界' : 'Clear boundaries, one shared world' }}</h2></div><div class="system-grid"><article v-for="(system, index) in systems" :key="system[0]"><component :is="[Box, Cpu, WandSparkles, Bot][index]" :size="22" /><h3>{{ system[0] }}</h3><strong>{{ system[1] }}</strong><p>{{ system[2] }}</p></article></div></div></section>
  </main>
</template>
