import type { RouteRecordRaw } from 'vue-router'
import { contentEntries } from 'virtual:guava-content'
import BlogIndexPage from '@/pages/BlogIndexPage.vue'
import CommunityPage from '@/pages/CommunityPage.vue'
import ContentPage from '@/pages/ContentPage.vue'
import DownloadPage from '@/pages/DownloadPage.vue'
import FeaturesPage from '@/pages/FeaturesPage.vue'
import HomePage from '@/pages/HomePage.vue'
import NotFoundPage from '@/pages/NotFoundPage.vue'

const staticPages = [
  ['', HomePage, 'home'],
  ['/features', FeaturesPage, 'features'],
  ['/download', DownloadPage, 'download'],
  ['/blog', BlogIndexPage, 'blog'],
  ['/community', CommunityPage, 'community'],
] as const

export const routes: RouteRecordRaw[] = [
  { path: '/', redirect: '/zh' },
  ...(['zh', 'en'] as const).flatMap((locale) => staticPages.map(([suffix, component, key]) => ({
    path: `/${locale}${suffix}`,
    name: `${locale}-${key}`,
    component,
    meta: { locale, translationKey: key, title: key === 'home' ? undefined : key[0].toUpperCase() + key.slice(1) },
  }))),
  ...contentEntries.map((entry) => ({
    path: entry.path,
    name: `${entry.locale}-${entry.translationKey}`,
    component: ContentPage,
    props: { entry },
    meta: { locale: entry.locale, translationKey: entry.translationKey, title: entry.title, description: entry.description },
  })),
  { path: '/:pathMatch(.*)*', component: NotFoundPage, meta: { locale: 'zh', translationKey: '404', title: '404' } },
]
