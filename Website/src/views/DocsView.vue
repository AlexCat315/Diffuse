<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter, RouterLink } from 'vue-router'
import { allDocs, docGroups, findDoc } from '@/utils/docs'
import { extractToc, renderMarkdown } from '@/utils/markdown'

const route = useRoute()
const router = useRouter()

const current = computed(() => findDoc(route.params.slug as string | undefined))
const html = computed(() => renderMarkdown(current.value.raw))
const toc = computed(() => extractToc(html.value))
const activeHeading = ref('')

const sidebarOpen = ref(false)
const contentEl = ref<HTMLElement | null>(null)

const docIndex = computed(() => allDocs.findIndex((d) => d.slug === current.value.slug))
const prev = computed(() => (docIndex.value > 0 ? allDocs[docIndex.value - 1] : null))
const next = computed(() =>
  docIndex.value < allDocs.length - 1 ? allDocs[docIndex.value + 1] : null,
)

function onContentClick(e: MouseEvent) {
  const btn = (e.target as HTMLElement).closest('.md-copy') as HTMLButtonElement | null
  if (!btn) return
  const code = btn.closest('.md-code')?.getAttribute('data-code') ?? ''
  navigator.clipboard.writeText(code).then(() => {
    btn.textContent = '已复制'
    btn.classList.add('done')
    setTimeout(() => {
      btn.textContent = '复制'
      btn.classList.remove('done')
    }, 1500)
  })
}

function scrollToHeading(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' })
}

let headingObserver: IntersectionObserver | null = null
function setupHeadingObserver() {
  headingObserver?.disconnect()
  const headings = Array.from(
    contentEl.value?.querySelectorAll<HTMLElement>('h2[id], h3[id]') ?? [],
  )
  if (!headings.length || !('IntersectionObserver' in window)) return
  headingObserver = new IntersectionObserver(
    (entries) => {
      const visible = entries.filter((e) => e.isIntersecting)
      if (visible.length) activeHeading.value = (visible[0].target as HTMLElement).id
    },
    { rootMargin: '-80px 0px -70% 0px', threshold: 0 },
  )
  headings.forEach((h) => headingObserver?.observe(h))
}

watch(
  () => route.params.slug,
  async () => {
    sidebarOpen.value = false
    await nextTick()
    setupHeadingObserver()
    window.scrollTo({ top: 0 })
  },
)

onMounted(() => {
  nextTick(setupHeadingObserver)
  if (!route.params.slug) {
    router.replace({ name: 'docs', params: { slug: current.value.slug } })
  }
})
onBeforeUnmount(() => headingObserver?.disconnect())
</script>

<template>
  <div class="docs-layout">
    <div class="sidebar-overlay" :class="{ open: sidebarOpen }" @click="sidebarOpen = false"></div>

    <aside class="docs-sidebar" :class="{ open: sidebarOpen }">
      <div class="sidebar-inner">
        <div v-for="g in docGroups" :key="g.group" class="sidebar-group">
          <h4>{{ g.group }}</h4>
          <RouterLink
            v-for="item in g.items"
            :key="item.slug"
            :to="{ name: 'docs', params: { slug: item.slug } }"
            class="sidebar-link"
            :class="{ active: item.slug === current.slug }"
          >
            {{ item.title }}
          </RouterLink>
        </div>
      </div>
    </aside>

    <article class="docs-content" ref="contentEl" @click="onContentClick">
      <button class="mobile-toc-btn" @click="sidebarOpen = true">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M4 6h16M4 12h16M4 18h16" stroke-linecap="round" />
        </svg>
        文档目录
      </button>
      <div class="markdown-body" v-html="html"></div>

      <div class="docs-pager">
        <RouterLink v-if="prev" :to="{ name: 'docs', params: { slug: prev.slug } }" class="pager-card">
          <span>← 上一篇</span>
          <strong>{{ prev.title }}</strong>
        </RouterLink>
        <span v-else></span>
        <RouterLink v-if="next" :to="{ name: 'docs', params: { slug: next.slug } }" class="pager-card pager-next">
          <span>下一篇 →</span>
          <strong>{{ next.title }}</strong>
        </RouterLink>
      </div>
    </article>

    <aside class="docs-toc">
      <div class="toc-inner">
        <h4>本页目录</h4>
        <a
          v-for="h in toc"
          :key="h.id"
          :href="`#${h.id}`"
          class="toc-link"
          :class="[`depth-${h.depth}`, { active: h.id === activeHeading }]"
          @click.prevent="scrollToHeading(h.id)"
        >
          {{ h.text }}
        </a>
      </div>
    </aside>
  </div>
</template>

<style scoped>
.docs-layout {
  display: grid;
  grid-template-columns: 260px minmax(0, 1fr) 230px;
  max-width: 1400px;
  margin: 0 auto;
  padding-top: var(--nav-h);
  min-height: 100vh;
}
.docs-sidebar {
  position: sticky;
  top: var(--nav-h);
  height: calc(100vh - var(--nav-h));
  overflow-y: auto;
  border-right: 1px solid var(--border);
  padding: 36px 12px;
}
.sidebar-group h4 {
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--text-faint);
  padding: 0 14px;
  margin: 22px 0 10px;
}
.sidebar-link {
  display: block;
  padding: 8px 14px;
  border-radius: 8px;
  font-size: 14px;
  color: var(--text-dim);
  border-left: 2px solid transparent;
}
.sidebar-link:hover { color: var(--text); background: rgba(255, 255, 255, 0.04); }
.sidebar-link.active {
  color: var(--primary-soft);
  background: rgba(192, 132, 252, 0.1);
  border-left-color: var(--primary);
}
.docs-content { padding: 44px 52px 80px; min-width: 0; }
.mobile-toc-btn {
  display: none;
  width: 100%;
  align-items: center;
  gap: 8px;
  padding: 12px 16px;
  margin-bottom: 24px;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--surface);
  color: var(--text-dim);
  font-size: 14px;
  cursor: pointer;
}
.docs-toc {
  position: sticky;
  top: var(--nav-h);
  height: calc(100vh - var(--nav-h));
  overflow-y: auto;
  border-left: 1px solid var(--border);
  padding: 36px 20px;
}
.toc-inner h4 {
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--text-faint);
  margin-bottom: 14px;
}
.toc-link {
  display: block;
  font-size: 13px;
  color: var(--text-faint);
  padding: 5px 0 5px 12px;
  border-left: 2px solid transparent;
}
.toc-link.depth-3 { padding-left: 26px; font-size: 12.5px; }
.toc-link:hover { color: var(--text-dim); }
.toc-link.active { color: var(--primary-soft); border-left-color: var(--primary); }

.docs-pager {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
  margin-top: 64px;
}
.pager-card {
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 16px 20px;
}
.pager-card:hover { border-color: var(--primary); transform: translateY(-2px); }
.pager-card span { display: block; font-size: 12px; color: var(--text-faint); margin-bottom: 4px; }
.pager-card strong { font-size: 15px; }
.pager-next { text-align: right; }

.sidebar-overlay { display: none; }

@media (max-width: 1100px) {
  .docs-layout { grid-template-columns: 250px minmax(0, 1fr); }
  .docs-toc { display: none; }
}
@media (max-width: 820px) {
  .docs-layout { grid-template-columns: 1fr; }
  .docs-content { padding: 28px 20px 64px; }
  .mobile-toc-btn { display: flex; }
  .docs-sidebar {
    position: fixed;
    left: 0;
    top: var(--nav-h);
    bottom: 0;
    z-index: 90;
    width: 280px;
    background: rgba(10, 7, 20, 0.98);
    backdrop-filter: blur(20px);
    transform: translateX(-100%);
    transition: transform 0.3s;
  }
  .docs-sidebar.open { transform: none; }
  .sidebar-overlay {
    display: block;
    position: fixed;
    inset: var(--nav-h) 0 0 0;
    background: rgba(0, 0, 0, 0.5);
    z-index: 80;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.3s;
  }
  .sidebar-overlay.open { opacity: 1; pointer-events: auto; }
  .docs-pager { grid-template-columns: 1fr; }
}
</style>

<style>
.markdown-body { color: var(--text); font-size: 15.5px; }
.markdown-body h1 { font-size: 34px; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
.markdown-body h2 { font-size: 25px; margin: 44px 0 16px; }
.markdown-body h3 { font-size: 19px; margin: 32px 0 12px; }
.markdown-body p { margin: 14px 0; }
.markdown-body ul, .markdown-body ol { margin: 14px 0; padding-left: 26px; }
.markdown-body li { margin: 7px 0; }
.markdown-body a { color: var(--primary-soft); text-decoration: underline; text-underline-offset: 3px; }
.markdown-body blockquote {
  border-left: 3px solid var(--primary);
  background: rgba(192, 132, 252, 0.08);
  padding: 12px 18px;
  border-radius: 0 10px 10px 0;
  margin: 18px 0;
  color: var(--text-dim);
}
.markdown-body table {
  width: 100%;
  border-collapse: collapse;
  margin: 22px 0;
  font-size: 14px;
  display: block;
  overflow-x: auto;
}
.markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 10px 14px; text-align: left; }
.markdown-body th { background: rgba(38, 25, 66, 0.5); font-weight: 600; }
.markdown-body hr { border: none; border-top: 1px solid var(--border); margin: 36px 0; }
.markdown-body code {
  font-family: var(--font-mono);
  font-size: 13px;
  background: rgba(192, 132, 252, 0.12);
  color: var(--primary-soft);
  padding: 2px 7px;
  border-radius: 6px;
}
.md-code {
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: hidden;
  margin: 22px 0;
  background: #080412;
}
.md-code-head {
  display: flex;
  justify-content: space-between;
  padding: 8px 16px;
  background: rgba(38, 25, 66, 0.55);
  border-bottom: 1px solid var(--border);
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--text-faint);
}
.md-copy {
  background: none;
  border: none;
  color: var(--text-dim);
  font-size: 12px;
  cursor: pointer;
  padding: 3px 10px;
  border-radius: 6px;
  font-family: var(--font-sans);
}
.md-copy:hover { color: var(--primary-soft); background: rgba(192, 132, 252, 0.12); }
.md-copy.done { color: #4ade80; }
.md-code pre { margin: 0; padding: 18px 20px; overflow-x: auto; }
.md-code pre code { background: none; color: #ecdffa; padding: 0; font-size: 13.5px; line-height: 1.7; }
.md-code .tok-keyword { color: #d8b4fe; font-weight: 600; }
.md-code .tok-string { color: #fda4af; }
.md-code .tok-comment { color: #7d6b99; font-style: italic; }
.md-code .tok-number { color: #fdba74; }
</style>
