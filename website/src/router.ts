import type { RouteRecordRaw } from 'vue-router'
import { contentEntries } from 'virtual:guava-content'

const staticPages = [
  ['', () => import('@/pages/HomePage.vue'), 'home'],
  ['/features', () => import('@/pages/FeaturesPage.vue'), 'features'],
  ['/download', () => import('@/pages/DownloadPage.vue'), 'download'],
  ['/blog', () => import('@/pages/BlogIndexPage.vue'), 'blog'],
  ['/community', () => import('@/pages/CommunityPage.vue'), 'community'],
] as const

const ContentPage = () => import('@/pages/ContentPage.vue')
const NotFoundPage = () => import('@/pages/NotFoundPage.vue')

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
  { path: '/zh/:pathMatch(.*)*', component: NotFoundPage, meta: { locale: 'zh', translationKey: '404', title: '404' } },
  { path: '/en/:pathMatch(.*)*', component: NotFoundPage, meta: { locale: 'en', translationKey: '404', title: '404' } },
  { path: '/:pathMatch(.*)*', component: NotFoundPage, meta: { locale: 'zh', translationKey: '404', title: '404' } },
]
