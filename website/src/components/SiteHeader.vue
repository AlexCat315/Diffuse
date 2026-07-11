<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { GitFork as Github, Languages, Menu, Moon, Search, Sun, X } from '@lucide/vue'
import logoUrl from '@root/docs/logo/logo1.svg'
import { repositoryUrl } from '@/content/copy'
import { useGitHub } from '@/composables/useGitHub'
import { useLocale } from '@/composables/useLocale'
import { useSearchDialog } from '@/composables/useSearchDialog'
import { useTheme } from '@/composables/useTheme'
import type { Locale } from '@/types/content'

const route = useRoute()
const router = useRouter()
const { locale, t } = useLocale()
const { theme, toggleTheme } = useTheme()
const { openSearch } = useSearchDialog()
const { snapshot } = useGitHub()
const menuOpen = ref(false)

const nav = computed(() => [
  [t.value.nav.features, `/${locale.value}/features`],
  [t.value.nav.docs, `/${locale.value}/docs`],
  [t.value.nav.blog, `/${locale.value}/blog`],
  [t.value.nav.roadmap, `/${locale.value}/roadmap`],
  [t.value.nav.community, `/${locale.value}/community`],
] as const)

function switchLocale() {
  const next: Locale = locale.value === 'zh' ? 'en' : 'zh'
  const translationKey = route.meta.translationKey
  const translated = router.getRoutes().find((candidate) => candidate.meta.translationKey === translationKey && candidate.meta.locale === next)
  const fallback = String(translationKey).startsWith('docs.components.') ? `/${next}/docs/components` : `/${next}`
  window.localStorage.setItem('guava-locale', next)
  menuOpen.value = false
  void router.push(translated?.path ?? fallback)
}
</script>

<template>
  <header class="site-header">
    <div class="header-shell">
      <RouterLink :to="`/${locale}`" class="brand" aria-label="Guava Engine home">
        <img :src="logoUrl" alt="" class="brand-mark" />
        <span>GUAVA <b>ENGINE</b></span>
      </RouterLink>

      <nav class="desktop-nav" aria-label="Primary navigation">
        <RouterLink v-for="item in nav" :key="item[1]" :to="item[1]">{{ item[0] }}</RouterLink>
      </nav>

      <div class="header-actions">
        <button class="icon-button search-trigger" type="button" :aria-label="t.search.label" @click="openSearch">
          <Search :size="17" />
          <span>{{ t.search.label }}</span>
          <kbd>⌘K</kbd>
        </button>
        <button class="icon-button" type="button" :aria-label="locale === 'zh' ? 'Switch to English' : '切换到中文'" @click="switchLocale">
          <Languages :size="18" />
        </button>
        <button class="icon-button" type="button" :aria-label="theme === 'dark' ? 'Use light theme' : 'Use dark theme'" @click="toggleTheme">
          <Sun v-if="theme === 'dark'" :size="18" />
          <Moon v-else :size="18" />
        </button>
        <a :href="repositoryUrl" class="github-chip" target="_blank" rel="noreferrer">
          <Github :size="17" />
          <span v-if="snapshot">{{ snapshot.repository.stars }}</span>
        </a>
        <RouterLink :to="`/${locale}/download`" class="button button-small">{{ t.nav.download }}</RouterLink>
        <button class="icon-button mobile-menu" type="button" :aria-expanded="menuOpen" aria-label="Toggle navigation" @click="menuOpen = !menuOpen">
          <X v-if="menuOpen" :size="20" />
          <Menu v-else :size="20" />
        </button>
      </div>
    </div>
    <nav v-if="menuOpen" class="mobile-nav" aria-label="Mobile navigation">
      <RouterLink v-for="item in nav" :key="item[1]" :to="item[1]" @click="menuOpen = false">{{ item[0] }}</RouterLink>
      <RouterLink :to="`/${locale}/download`" @click="menuOpen = false">{{ t.nav.download }}</RouterLink>
    </nav>
  </header>
</template>
