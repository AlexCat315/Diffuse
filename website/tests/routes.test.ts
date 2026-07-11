import { describe, expect, it } from 'vitest'
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
})
