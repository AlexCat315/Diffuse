<script setup lang="ts">
import { BookOpen, Code2, GitFork as Github, MessageSquareWarning, Users } from '@lucide/vue'
import { repositoryUrl } from '@/content/copy'
import { useGitHub } from '@/composables/useGitHub'
import { useLocale } from '@/composables/useLocale'

const { locale, t } = useLocale()
const { snapshot } = useGitHub()
</script>

<template>
  <main><section class="page-hero section-shell"><p class="eyebrow"><Users :size="14" /> {{ t.community.eyebrow }}</p><h1>{{ t.community.title }}</h1><p>{{ t.community.description }}</p><div class="hero-actions"><a :href="repositoryUrl" class="button" target="_blank" rel="noreferrer"><Github :size="17" /> GitHub</a><RouterLink :to="`/${locale}/docs/contributing`" class="button button-secondary"><Code2 :size="17" /> {{ t.community.contribute }}</RouterLink></div></section>
    <section class="section-shell community-actions"><a :href="`${repositoryUrl}/issues/new`" target="_blank" rel="noreferrer"><MessageSquareWarning :size="24" /><h2>{{ t.community.issue }}</h2><p>{{ locale === 'zh' ? '提供复现步骤、平台和相关日志，帮助问题更快被定位。' : 'Share reproduction steps, platform details, and logs so the issue can be understood quickly.' }}</p></a><RouterLink :to="`/${locale}/docs/contributing`"><Code2 :size="24" /><h2>{{ t.community.contribute }}</h2><p>{{ locale === 'zh' ? '从文档、测试和小型修复开始，逐步熟悉引擎模块边界。' : 'Start with docs, tests, and focused fixes while learning the engine boundaries.' }}</p></RouterLink><RouterLink :to="`/${locale}/docs`"><BookOpen :size="24" /><h2>{{ t.nav.docs }}</h2><p>{{ locale === 'zh' ? '了解构建、架构、模块和 GuavaUI 组件契约。' : 'Learn the build, architecture, modules, and GuavaUI component contracts.' }}</p></RouterLink></section>
    <section class="section-shell contributors-section section-space"><div class="section-heading"><p class="eyebrow">PEOPLE</p><h2>{{ t.community.contributors }}</h2></div><div class="contributor-grid"><a v-for="person in snapshot?.contributors" :key="person.login" :href="person.profileUrl" target="_blank" rel="noreferrer"><img :src="person.avatarUrl" :alt="person.login" /><div><strong>@{{ person.login }}</strong><span>{{ person.contributions }} contributions</span></div></a></div><p v-if="snapshot?.stale" class="stale-note">{{ t.github.stale }}</p></section>
  </main>
</template>
