<script setup lang="ts">
import { computed } from 'vue'
import { ArrowRight, Bot, Boxes, Code2, Download, Film, GitFork as Github, Layers3, MonitorDown, Sparkles, Users, Zap } from '@lucide/vue'
import EditorConcept from '@/components/EditorConcept.vue'
import { capabilities, repositoryUrl, roadmapSummary, workflow } from '@/content/copy'
import { useGitHub } from '@/composables/useGitHub'
import { useLocale } from '@/composables/useLocale'

const { locale, t } = useLocale()
const { snapshot } = useGitHub()
const capabilityIcons = [Layers3, Zap, Boxes, Bot, Film, Code2]
const latest = computed(() => snapshot.value?.releases[0])
const primaryAsset = computed(() => latest.value?.assets.find((asset) => asset.name.includes('macos')) ?? latest.value?.assets[0])
</script>

<template>
  <main>
    <section class="hero section-shell">
      <div class="hero-copy">
        <p class="eyebrow"><Sparkles :size="14" /> {{ t.home.eyebrow }}</p>
        <h1>{{ t.home.title }}</h1>
        <p class="hero-description">{{ t.home.description }}</p>
        <div class="hero-actions">
          <RouterLink :to="`/${locale}/docs/getting-started`" class="button"><ArrowRight :size="17" /> {{ t.actions.getStarted }}</RouterLink>
          <RouterLink :to="`/${locale}/download`" class="button button-secondary"><Download :size="17" /> {{ t.actions.download }}</RouterLink>
        </div>
        <div class="hero-proof">
          <span><i></i> Apache-2.0</span><span>Swift 6</span><span>WebGPU</span><span v-if="snapshot">★ {{ snapshot.repository.stars }}</span>
        </div>
      </div>
      <EditorConcept />
    </section>

    <section class="capabilities section-shell section-space">
      <div class="section-heading"><p class="eyebrow">CREATIVE SYSTEM</p><h2>{{ t.home.capabilitiesTitle }}</h2><p>{{ t.home.capabilitiesIntro }}</p></div>
      <div class="capability-grid">
        <article v-for="(item, index) in capabilities[locale]" :key="item[0]">
          <component :is="capabilityIcons[index]" :size="22" />
          <h3>{{ item[0] }}</h3><p>{{ item[1] }}</p><span>0{{ index + 1 }}</span>
        </article>
      </div>
      <RouterLink :to="`/${locale}/features`" class="text-link">{{ t.actions.explore }} <ArrowRight :size="16" /></RouterLink>
    </section>

    <section class="workflow-section section-space">
      <div class="section-shell">
        <div class="section-heading"><p class="eyebrow">INTENT TO WORLD</p><h2>{{ t.home.workflowTitle }}</h2></div>
        <div class="workflow-grid">
          <article v-for="item in workflow[locale]" :key="item[0]"><b>{{ item[0] }}</b><div><h3>{{ item[1] }}</h3><p>{{ item[2] }}</p></div></article>
        </div>
      </div>
    </section>

    <section class="release-section section-shell section-space">
      <div class="release-card">
        <div><p class="eyebrow"><MonitorDown :size="14" /> {{ t.github.latest }}</p><h2>{{ t.home.releaseTitle }}</h2><p>{{ t.home.releaseIntro }}</p></div>
        <div class="release-version"><span>{{ latest?.tag ?? 'v0.0.7' }}</span><small>{{ latest?.publishedAt?.slice(0, 10) ?? '2026-07-05' }}</small></div>
        <div class="release-actions">
          <a v-if="primaryAsset" :href="primaryAsset.downloadUrl" class="button"><Download :size="17" /> {{ t.actions.download }}</a>
          <RouterLink v-else :to="`/${locale}/download`" class="button"><Download :size="17" /> {{ t.actions.download }}</RouterLink>
          <RouterLink :to="`/${locale}/download`" class="text-link">{{ locale === 'zh' ? '全部平台' : 'All platforms' }} <ArrowRight :size="15" /></RouterLink>
        </div>
      </div>
      <p v-if="snapshot?.stale" class="stale-note">{{ t.github.stale }}</p>
    </section>

    <section class="section-shell section-space split-feature">
      <div>
        <p class="eyebrow">PUBLIC ROADMAP</p><h2>{{ t.home.roadmapTitle }}</h2>
        <div class="roadmap-mini"><article v-for="(item, index) in roadmapSummary[locale]" :key="item[0]" :class="`roadmap-${index}`"><i></i><div><strong>{{ item[0] }}</strong><p>{{ item[1] }}</p></div></article></div>
        <RouterLink :to="`/${locale}/roadmap`" class="text-link">{{ t.nav.roadmap }} <ArrowRight :size="16" /></RouterLink>
      </div>
      <div class="community-panel">
        <Users :size="30" /><h2>{{ t.home.communityTitle }}</h2>
        <div class="avatar-stack"><img v-for="person in snapshot?.contributors.slice(0, 6)" :key="person.login" :src="person.avatarUrl" :alt="person.login" /></div>
        <p>{{ locale === 'zh' ? '每一次提交、讨论与试用，都在塑造 Guava 的下一步。' : 'Every commit, discussion, and experiment shapes what Guava becomes next.' }}</p>
        <div><RouterLink :to="`/${locale}/community`" class="button button-secondary">{{ t.nav.community }}</RouterLink><a :href="repositoryUrl" class="icon-button" target="_blank" rel="noreferrer"><Github :size="18" /></a></div>
      </div>
    </section>
  </main>
</template>
