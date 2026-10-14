<script setup lang="ts">
import { useLocale } from '@/composables/useLocale'
const { locale } = useLocale()
</script>
<template>
  <main class="section-shell section-space">
    <h1>{{ locale === 'zh' ? 'GuavaStudio 演进方向' : 'GuavaStudio roadmap' }}</h1>
    <p>{{ locale === 'zh' ? '以 AI Agent 驱动的文本、代码、游戏、动画和视频工作站。' : 'An AI agent workstation for text, code, games, animation and video.' }}</p>
    <ul v-if="locale === 'zh'">
      <li>持续验证桌面、Android 和 iOS 平台宿主与 Wasmtime/Pulley。</li>
      <li>把所有组件迁移到空间、输入能力和安全区驱动的标准。</li>
      <li>扩展媒体时间线：多轨、转场、代理媒体和硬件解码。</li>
      <li>扩展普通代码文档的语言服务，以及 Agent 的项目操作。</li>
    </ul>
    <ul v-else>
      <li>Validate desktop, Android and iOS hosts with Wasmtime/Pulley.</li>
      <li>Migrate components to space, input capabilities and safe-area standards.</li>
      <li>Extend media editing with multiple tracks, transitions, proxies and hardware decoding.</li>
      <li>Extend language services and agent project operations for ordinary code documents.</li>
    </ul>
  </main>
</template>
