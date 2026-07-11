import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchGitHubSnapshot, mapGitHubPayload } from '@/services/github'

describe('GitHub data', () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it('maps repository, release assets, and contributors', () => {
    const result = mapGitHubPayload(
      { stargazers_count: 8, forks_count: 2, open_issues_count: 1, updated_at: 'now', html_url: 'repo' },
      [{ tag_name: 'v1', name: '', published_at: 'today', html_url: 'release', assets: [{ id: 1, name: 'macos.zip', size: 42, download_count: 5, browser_download_url: 'asset' }] }],
      [{ login: 'alex', avatar_url: 'avatar', html_url: 'profile', contributions: 9 }],
    )
    expect(result.repository.stars).toBe(8)
    expect(result.releases[0]?.assets[0]?.downloadUrl).toBe('asset')
    expect(result.contributors[0]?.login).toBe('alex')
  })

  it('falls back to a bundled stale snapshot on network failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')))
    const result = await fetchGitHubSnapshot(true)
    expect(result.stale).toBe(true)
    expect(result.releases.length).toBeGreaterThan(0)
  })

  it('returns a valid fresh API response', async () => {
    const payloads = [
      { stargazers_count: 4, forks_count: 1, open_issues_count: 0, updated_at: 'now', html_url: 'repo' },
      [],
      [],
    ]
    vi.stubGlobal('fetch', vi.fn().mockImplementation(() => Promise.resolve({ ok: true, json: () => Promise.resolve(payloads.shift()) })))
    const result = await fetchGitHubSnapshot(true)
    expect(result.repository.stars).toBe(4)
    expect(result.stale).toBeUndefined()
  })
})
