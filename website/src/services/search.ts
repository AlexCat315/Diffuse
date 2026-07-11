import MiniSearch from 'minisearch'
import type { ContentEntry, SearchDocument } from '@/types/content'

export function toSearchDocuments(entries: ContentEntry[]): SearchDocument[] {
  return entries.map((entry) => ({
    id: entry.path,
    path: entry.path,
    locale: entry.locale,
    title: entry.title,
    description: entry.description,
    category: entry.category,
    text: entry.text,
  }))
}

export function buildSearchIndex(documents: SearchDocument[]) {
  const index = new MiniSearch<SearchDocument>({
    fields: ['title', 'description', 'text'],
    storeFields: ['path', 'locale', 'title', 'description', 'category'],
    searchOptions: { prefix: true, fuzzy: 0.2, boost: { title: 4, description: 2 } },
  })
  index.addAll(documents)
  return index
}
