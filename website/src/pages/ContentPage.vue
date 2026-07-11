<script setup lang="ts">
import { computed, provide } from 'vue'
import { useRoute } from 'vue-router'
import { ChevronLeft, ChevronRight, ExternalLink } from '@lucide/vue'
import { contentEntries } from 'virtual:guava-content'
import type { ContentEntry } from '@/types/content'

const props = defineProps<{ entry: ContentEntry }>()
provide('content-entry', props.entry)
const route = useRoute()

const isDoc = computed(() => props.entry.kind !== 'post')
const siblings = computed(() => contentEntries
  .filter((entry) => entry.locale === props.entry.locale && entry.kind === props.entry.kind && (props.entry.kind === 'post' || entry.category === props.entry.category))
  .sort((a, b) => a.order - b.order))
const position = computed(() => siblings.value.findIndex((entry) => entry.path === props.entry.path))
const previous = computed(() => position.value > 0 ? siblings.value[position.value - 1] : undefined)
const next = computed(() => position.value < siblings.value.length - 1 ? siblings.value[position.value + 1] : undefined)
const docs = computed(() => contentEntries.filter((entry) => entry.locale === props.entry.locale && entry.kind === 'doc').sort((a, b) => a.order - b.order))
const categories = computed(() => [...new Set(docs.value.map((entry) => entry.category))])
const editUrl = computed(() => `https://github.com/AlexCat315/Guava-Engine/edit/next/${props.entry.editPath}`)
</script>

<template>
  <main :class="['content-shell', { 'blog-article-shell': entry.kind === 'post' }]">
    <aside v-if="isDoc" class="docs-sidebar">
      <RouterLink :to="`/${entry.locale}/docs`" class="docs-title">DOCUMENTATION</RouterLink>
      <section v-for="category in categories" :key="category">
        <h3>{{ category }}</h3>
        <RouterLink v-for="doc in docs.filter((item) => item.category === category)" :key="doc.path" :to="doc.path">{{ doc.title }}</RouterLink>
      </section>
    </aside>

    <article class="content-article">
      <nav class="breadcrumbs" aria-label="Breadcrumb">
        <RouterLink :to="`/${entry.locale}`">Guava</RouterLink><span>/</span>
        <RouterLink :to="entry.kind === 'post' ? `/${entry.locale}/blog` : `/${entry.locale}/docs`">{{ entry.kind === 'post' ? 'Blog' : 'Docs' }}</RouterLink><span>/</span>
        <span>{{ entry.title }}</span>
      </nav>
      <p v-if="entry.kind === 'post'" class="article-meta">{{ entry.publishedAt }} · {{ entry.tags?.join(' · ') }}</p>
      <component :is="entry.component" :key="route.fullPath" />
      <a class="edit-link" :href="editUrl" target="_blank" rel="noreferrer"><ExternalLink :size="14" /> {{ entry.locale === 'zh' ? '在 GitHub 编辑此页' : 'Edit this page on GitHub' }}</a>
      <nav class="page-turner" aria-label="Adjacent pages">
        <RouterLink v-if="previous" :to="previous.path"><ChevronLeft :size="17" /><span><small>{{ entry.locale === 'zh' ? '上一篇' : 'Previous' }}</small>{{ previous.title }}</span></RouterLink>
        <RouterLink v-if="next" :to="next.path" class="next"><span><small>{{ entry.locale === 'zh' ? '下一篇' : 'Next' }}</small>{{ next.title }}</span><ChevronRight :size="17" /></RouterLink>
      </nav>
    </article>

    <aside v-if="isDoc && entry.headings.length" class="page-toc">
      <strong>{{ entry.locale === 'zh' ? '本页内容' : 'On this page' }}</strong>
      <a v-for="heading in entry.headings" :key="heading.slug" :href="`#${heading.slug}`" :class="`level-${heading.level}`">{{ heading.title }}</a>
    </aside>
  </main>
</template>
