<script setup lang="ts">
import { computed, ref } from 'vue'
import { highlight } from '@/utils/highlight'

const props = withDefaults(defineProps<{ code: string; lang?: string; title?: string }>(), {
  lang: 'swift',
  title: '',
})

const copied = ref(false)
async function copy() {
  await navigator.clipboard.writeText(props.code)
  copied.value = true
  setTimeout(() => (copied.value = false), 1600)
}

const html = computed(() =>
  /^(text|plain)$/i.test(props.lang) ? props.code : highlight(props.code, props.lang),
)
</script>

<template>
  <div class="code-block">
    <div class="code-head">
      <span class="code-title">{{ title || lang }}</span>
      <button class="copy-btn" @click="copy">
        <svg v-if="!copied" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="9" y="9" width="13" height="13" rx="2" />
          <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
        </svg>
        <svg v-else width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
          <path d="M20 6 9 17l-5-5" />
        </svg>
        <span>{{ copied ? '已复制' : '复制' }}</span>
      </button>
    </div>
    <pre><code class="code-body" v-html="html"></code></pre>
  </div>
</template>

<style scoped>
.code-block {
  border-radius: var(--radius);
  overflow: hidden;
  border: 1px solid var(--border);
  background: #080412;
  box-shadow: var(--shadow);
  margin: 20px 0;
}
.code-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 10px 16px;
  background: rgba(38, 25, 66, 0.6);
  border-bottom: 1px solid var(--border);
}
.code-title {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--text-faint);
}
.copy-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  background: none;
  border: none;
  color: var(--text-dim);
  font-size: 12px;
  cursor: pointer;
  padding: 4px 8px;
  border-radius: 6px;
}
.copy-btn:hover { color: var(--primary-soft); background: rgba(192, 132, 252, 0.12); }
.code-body {
  display: block;
  padding: 18px 20px;
  overflow-x: auto;
  font-size: 13.5px;
  line-height: 1.7;
  font-family: var(--font-mono);
  color: #ecdffa;
}
:deep(.tok-keyword) { color: #d8b4fe; font-weight: 600; }
:deep(.tok-string) { color: #fda4af; }
:deep(.tok-comment) { color: #7d6b99; font-style: italic; }
:deep(.tok-number) { color: #fdba74; }
</style>
