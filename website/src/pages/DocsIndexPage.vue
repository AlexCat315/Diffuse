<script setup lang="ts">
import { computed } from 'vue'
import { contentEntries } from 'virtual:guava-content'
import { useLocale } from '@/composables/useLocale'
const { locale } = useLocale()
const docs = computed(() => contentEntries.filter((entry) => entry.locale === locale.value && entry.kind === 'doc'))
</script>
<template>
  <main class="section-shell section-space">
    <h1>{{ locale === 'zh' ? 'GuavaStudio 文档' : 'GuavaStudio documentation' }}</h1>
    <p>{{ locale === 'zh' ? '工作站、跨设备组件、平台宿主和贡献指南。' : 'Workstation, components, platform hosts and contribution guides.' }}</p>
    <ul><li v-for="entry in docs" :key="entry.path"><RouterLink :to="entry.path">{{ entry.title }}</RouterLink><p>{{ entry.description }}</p></li></ul>
  </main>
</template>
