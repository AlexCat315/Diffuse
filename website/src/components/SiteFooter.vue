<script setup lang="ts">
import { GitFork as Github } from '@lucide/vue'
import logoUrl from '@root/docs/logo/logo1.svg'
import { repositoryUrl } from '@/content/copy'
import { useLocale } from '@/composables/useLocale'

const { locale, t } = useLocale()
</script>

<template>
  <footer class="site-footer">
    <div class="footer-shell">
      <div class="footer-brand">
        <img :src="logoUrl" alt="" />
        <div><strong>Guava Engine</strong><p>{{ t.footer.tagline }}</p></div>
      </div>
      <div class="footer-links">
        <RouterLink :to="`/${locale}/docs`">{{ t.nav.docs }}</RouterLink>
        <RouterLink :to="`/${locale}/roadmap`">{{ t.nav.roadmap }}</RouterLink>
        <RouterLink :to="`/${locale}/community`">{{ t.nav.community }}</RouterLink>
        <a :href="repositoryUrl" target="_blank" rel="noreferrer"><Github :size="16" /> GitHub</a>
      </div>
    </div>
    <div class="footer-bottom"><span>© {{ new Date().getFullYear() }} Guava Engine</span><span>{{ t.footer.license }}</span></div>
  </footer>
</template>
