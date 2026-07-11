<script setup lang="ts">
import { ArrowLeft, Compass } from '@lucide/vue'
import { useRoute } from 'vue-router'
const route = useRoute()
const locale = route.path.startsWith('/en') ? 'en' : 'zh'
</script>

<template><main class="not-found section-shell"><Compass :size="42" /><p>404 · LOST IN THE WORLD</p><h1>{{ locale === 'zh' ? '这个实体还没有被创建。' : 'This entity has not been created yet.' }}</h1><RouterLink :to="`/${locale}`" class="button"><ArrowLeft :size="17" /> {{ locale === 'zh' ? '返回首页' : 'Back home' }}</RouterLink></main></template>
