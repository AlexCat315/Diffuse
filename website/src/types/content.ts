import type { Component } from 'vue'

export type Locale = 'zh' | 'en'
export type ContentKind = 'doc' | 'post' | 'roadmap'

export interface ContentMeta {
  path: string
  title: string
  description: string
  locale: Locale
  translationKey: string
  category: string
  order: number
  kind: ContentKind
  tags?: string[]
  publishedAt?: string
  updatedAt?: string
  draft?: boolean
}

export interface ContentEntry extends ContentMeta {
  component: Component
  editPath: string
  text: string
  headings: Array<{ level: number; title: string; slug: string }>
}

export interface SearchDocument {
  id: string
  path: string
  locale: Locale
  title: string
  description: string
  category: string
  text: string
}
