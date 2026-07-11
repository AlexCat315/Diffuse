<script setup lang="ts">
import { onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useHead } from '@unhead/vue'
import SiteFooter from '@/components/SiteFooter.vue'
import SiteHeader from '@/components/SiteHeader.vue'
import SearchDialog from '@/components/SearchDialog.vue'
import { useGitHub } from '@/composables/useGitHub'

const route = useRoute()
const router = useRouter()
const { load } = useGitHub()
const siteUrl = (import.meta.env.VITE_SITE_URL || 'http://localhost:5173').replace(/\/$/, '')
function translatedPath(locale: 'zh' | 'en') {
  const target = router.getRoutes().find((candidate) => candidate.meta.translationKey === route.meta.translationKey && candidate.meta.locale === locale)
  if (target) return target.path
  if (String(route.meta.translationKey).startsWith('docs.components.')) return `/${locale}/docs/components`
  return `/${locale}`
}
useHead(() => ({
  htmlAttrs: { lang: route.meta.locale === 'en' ? 'en' : 'zh-CN' },
  title: route.meta.title ? `${route.meta.title} · Guava Engine` : 'Guava Engine',
  meta: [
    { name: 'description', content: String(route.meta.description || 'Guava Engine — AI-Native 3D game and film engine.') },
    { property: 'og:title', content: route.meta.title ? `${route.meta.title} · Guava Engine` : 'Guava Engine' },
    { property: 'og:description', content: String(route.meta.description || 'An AI-native 3D engine for creators and agents.') },
    { property: 'og:image', content: `${siteUrl}/og.png` },
    { property: 'og:type', content: 'website' },
    { name: 'twitter:card', content: 'summary_large_image' },
  ],
  link: [
    { rel: 'canonical', href: `${siteUrl}${route.path}` },
    { rel: 'alternate', hreflang: 'zh-CN', href: `${siteUrl}${translatedPath('zh')}` },
    { rel: 'alternate', hreflang: 'en', href: `${siteUrl}${translatedPath('en')}` },
  ],
}))
onMounted(load)
</script>

<template>
  <a class="skip-link" href="#main-content">Skip to content</a>
  <SiteHeader />
  <RouterView id="main-content" />
  <SiteFooter />
  <SearchDialog />
</template>
