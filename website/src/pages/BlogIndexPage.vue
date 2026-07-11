<script setup lang="ts">
import { ArrowRight, CalendarDays, Rss } from '@lucide/vue'
import { contentEntries } from 'virtual:guava-content'
import { useLocale } from '@/composables/useLocale'

const { locale, t } = useLocale()
const posts = contentEntries.filter((entry) => entry.kind === 'post' && entry.locale === locale.value).sort((a, b) => (b.publishedAt || '').localeCompare(a.publishedAt || ''))
</script>

<template>
  <main><section class="page-hero section-shell"><p class="eyebrow"><Rss :size="14" /> {{ t.blog.eyebrow }}</p><h1>{{ t.blog.title }}</h1><p>{{ t.blog.description }}</p></section><section class="section-shell blog-grid"><RouterLink v-for="post in posts" :key="post.path" :to="post.path" class="blog-card"><div class="blog-card-art"><span v-for="n in 6" :key="n"></span><b>GUAVA<br />BUILD LOG</b></div><div><p><CalendarDays :size="14" /> {{ post.publishedAt }}</p><h2>{{ post.title }}</h2><span>{{ post.description }}</span><em v-for="tag in post.tags" :key="tag">{{ tag }}</em><strong>{{ locale === 'zh' ? '阅读文章' : 'Read article' }} <ArrowRight :size="15" /></strong></div></RouterLink></section></main>
</template>
