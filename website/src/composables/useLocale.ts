import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { copy } from '@/content/copy'
import type { Locale } from '@/types/content'

export function useLocale() {
  const route = useRoute()
  const locale = computed<Locale>(() => route.meta.locale === 'en' ? 'en' : 'zh')
  const t = computed(() => copy[locale.value])
  return { locale, t }
}
