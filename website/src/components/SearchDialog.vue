<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { FileText, Search, X } from '@lucide/vue'
import { contentEntries } from 'virtual:guava-content'
import { useLocale } from '@/composables/useLocale'
import { useSearchDialog } from '@/composables/useSearchDialog'
import { buildSearchIndex, toSearchDocuments } from '@/services/search'
import type { SearchDocument } from '@/types/content'

const router = useRouter()
const { locale, t } = useLocale()
const { searchOpen, closeSearch } = useSearchDialog()
const input = ref<HTMLInputElement>()
const query = ref('')
const selected = ref(0)

const documents: SearchDocument[] = toSearchDocuments(contentEntries)
const index = buildSearchIndex(documents)

const results = computed(() => {
  if (!query.value.trim()) return documents.filter((document) => document.locale === locale.value).slice(0, 8)
  return index.search(query.value).filter((result) => result.locale === locale.value).slice(0, 10)
})

function choose(path: string) {
  closeSearch()
  query.value = ''
  void router.push(path)
}

function onKey(event: KeyboardEvent) {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault()
    if (searchOpen.value) closeSearch()
    else searchOpen.value = true
  }
  if (!searchOpen.value) return
  if (event.key === 'Escape') closeSearch()
  if (event.key === 'ArrowDown') { event.preventDefault(); selected.value = Math.min(selected.value + 1, results.value.length - 1) }
  if (event.key === 'ArrowUp') { event.preventDefault(); selected.value = Math.max(selected.value - 1, 0) }
  if (event.key === 'Enter' && results.value[selected.value]) choose(String(results.value[selected.value].path))
}

watch(searchOpen, async (open) => {
  if (open) { selected.value = 0; await nextTick(); input.value?.focus() }
})
watch(query, () => { selected.value = 0 })
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <Teleport to="body">
    <div v-if="searchOpen" class="dialog-backdrop" role="presentation" @click.self="closeSearch">
      <section class="search-dialog" role="dialog" aria-modal="true" :aria-label="t.search.label">
        <div class="search-input-row">
          <Search :size="20" />
          <input ref="input" v-model="query" :placeholder="t.search.placeholder" aria-label="Search query" />
          <button type="button" :aria-label="t.search.hint" @click="closeSearch"><X :size="19" /></button>
        </div>
        <div class="search-results" role="listbox">
          <button
            v-for="(result, indexValue) in results"
            :key="result.id"
            type="button"
            :class="{ selected: selected === indexValue }"
            role="option"
            :aria-selected="selected === indexValue"
            @mouseenter="selected = indexValue"
            @click="choose(String(result.path))"
          >
            <FileText :size="17" />
            <span><strong>{{ result.title }}</strong><small>{{ result.description }}</small></span>
            <em>{{ result.category }}</em>
          </button>
          <p v-if="!results.length" class="search-empty">{{ t.search.empty }}</p>
        </div>
        <footer><span>↑↓</span> Navigate <span>↵</span> Open <span>Esc</span> {{ t.search.hint }}</footer>
      </section>
    </div>
  </Teleport>
</template>
