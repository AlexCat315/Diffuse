import { describe, expect, it } from 'vitest'
import { contentEntries } from 'virtual:guava-content'
import { routes } from '@/router'

describe('routes', () => {
  it('provides paired core pages', () => {
    const paths = routes.map((route) => route.path)
    for (const suffix of ['', '/features', '/download', '/blog', '/community', '/docs', '/roadmap']) {
      expect(paths).toContain(`/zh${suffix}`)
      expect(paths).toContain(`/en${suffix}`)
    }
  })

  it('redirects the root to Chinese and retains a catch-all', () => {
    expect(routes.find((route) => route.path === '/')?.redirect).toBe('/zh')
    expect(routes.at(-1)?.path).toBe('/:pathMatch(.*)*')
  })

  it('encodes non-ASCII table-of-contents anchors to match rendered heading ids', () => {
    const architecture = contentEntries.find((entry) => entry.path === '/zh/docs/architecture')
    expect(architecture?.headings[0]?.slug).toMatch(/^%E/)
  })

  it('provides locale-aware not-found routes', () => {
    expect(routes.find((route) => route.path === '/zh/:pathMatch(.*)*')?.meta?.locale).toBe('zh')
    expect(routes.find((route) => route.path === '/en/:pathMatch(.*)*')?.meta?.locale).toBe('en')
  })
})
