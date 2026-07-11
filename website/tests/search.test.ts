import { describe, expect, it } from 'vitest'
import { buildSearchIndex } from '@/services/search'
import type { SearchDocument } from '@/types/content'

const documents: SearchDocument[] = [
  { id: '/zh/docs/architecture', path: '/zh/docs/architecture', locale: 'zh', title: '架构', description: '统一世界模型', category: '核心', text: '语义世界与场景运行时' },
  { id: '/en/docs/architecture', path: '/en/docs/architecture', locale: 'en', title: 'Architecture', description: 'Shared world model', category: 'Core', text: 'semantic world and scene runtime' },
]

describe('content search', () => {
  it('ranks title and full-text matches', () => {
    const index = buildSearchIndex(documents)
    expect(index.search('架构')[0]?.id).toBe('/zh/docs/architecture')
    expect(index.search('semantic')[0]?.id).toBe('/en/docs/architecture')
  })

  it('supports prefix matches', () => {
    const index = buildSearchIndex(documents)
    expect(index.search('arch')[0]?.id).toBe('/en/docs/architecture')
  })
})
