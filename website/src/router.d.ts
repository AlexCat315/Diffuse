import 'vue-router'
import type { Locale } from '@/types/content'

declare module 'vue-router' {
  interface RouteMeta {
    locale?: Locale
    translationKey?: string
    title?: string
    description?: string
  }
}
