<script setup lang="ts">
import { computed } from 'vue'
import { Apple, ArrowUpRight, Download, GitFork as Github, Laptop, Monitor as Windows, Terminal } from '@lucide/vue'
import { repositoryUrl } from '@/content/copy'
import { useGitHub } from '@/composables/useGitHub'
import { useLocale } from '@/composables/useLocale'

const { locale, t } = useLocale()
const { snapshot } = useGitHub()
const latest = computed(() => snapshot.value?.releases[0])
const platforms = computed(() => [
  { key: 'macos', title: 'macOS', detail: 'Apple Silicon · macOS 14+', icon: Apple, match: 'macos' },
  { key: 'windows', title: 'Windows', detail: 'x86_64 · Windows 11', icon: Windows, match: 'windows' },
  { key: 'linux', title: 'Linux', detail: 'x86_64 · glibc', icon: Laptop, match: 'linux' },
].map((platform) => ({ ...platform, asset: latest.value?.assets.find((asset) => asset.name.includes(platform.match)) })))
</script>

<template>
  <main>
    <section class="page-hero section-shell"><p class="eyebrow"><Download :size="14" /> {{ t.download.eyebrow }}</p><h1>{{ t.download.title }}</h1><p>{{ t.download.description }}</p><div class="version-pill"><i></i>{{ latest?.tag ?? 'v0.0.7' }} <span>{{ latest?.publishedAt?.slice(0, 10) ?? '2026-07-05' }}</span></div></section>
    <section class="section-shell download-grid">
      <article v-for="platform in platforms" :key="platform.key">
        <component :is="platform.icon" :size="31" /><div><h2>{{ platform.title }}</h2><p>{{ platform.detail }}</p></div>
        <a v-if="platform.asset" :href="platform.asset.downloadUrl" class="button"><Download :size="16" /> {{ t.actions.download }}</a>
        <a v-else :href="`${repositoryUrl}/releases/latest`" class="button"><ArrowUpRight :size="16" /> GitHub</a>
      </article>
    </section>
    <p v-if="snapshot?.stale" class="stale-note section-shell">{{ t.github.stale }}</p>
    <section class="section-shell source-build section-space"><div><Terminal :size="29" /><h2>{{ t.download.sourceTitle }}</h2><p>{{ t.download.sourceDescription }}</p></div><pre><code>git clone https://github.com/AlexCat315/Guava-Engine.git
cd Guava-Engine
git submodule update --init --recursive
python bootstrap.py
swift build --package-path Editor</code></pre><div><RouterLink :to="`/${locale}/docs/getting-started`" class="text-link">{{ t.actions.getStarted }} <ArrowUpRight :size="15" /></RouterLink><a :href="repositoryUrl" class="text-link" target="_blank" rel="noreferrer"><Github :size="15" /> GitHub</a></div></section>
  </main>
</template>
