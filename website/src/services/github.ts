import fallbackSnapshot from '@/data/github-fallback.json'
import type { GitHubSnapshot } from '@/types/github'

const api = 'https://api.github.com/repos/AlexCat315/Guava-Engine'
const cacheKey = 'guava-github-snapshot-v1'
const ttl = 30 * 60 * 1000

interface CachedSnapshot { expiresAt: number; snapshot: GitHubSnapshot }

export interface GitHubRepositoryPayload {
  stargazers_count: number
  forks_count: number
  open_issues_count: number
  updated_at: string
  html_url: string
}

export interface GitHubAssetPayload {
  id: number
  name: string
  size: number
  download_count: number
  browser_download_url: string
}

export interface GitHubReleasePayload {
  tag_name: string
  name: string | null
  published_at: string
  html_url: string
  assets: GitHubAssetPayload[]
}

export interface GitHubContributorPayload {
  login: string
  avatar_url: string
  html_url: string
  contributions: number
}

async function request<T>(path: string): Promise<T> {
  const response = await fetch(`${api}${path}`, { headers: { Accept: 'application/vnd.github+json' } })
  if (!response.ok) throw new Error(`GitHub API request failed: ${response.status}`)
  return response.json() as Promise<T>
}

export function mapGitHubPayload(repository: GitHubRepositoryPayload, releases: GitHubReleasePayload[], contributors: GitHubContributorPayload[]): GitHubSnapshot {
  return {
    repository: {
      stars: repository.stargazers_count,
      forks: repository.forks_count,
      openIssues: repository.open_issues_count,
      updatedAt: repository.updated_at,
      url: repository.html_url,
    },
    releases: releases.map((release) => ({
      tag: release.tag_name,
      name: release.name || release.tag_name,
      publishedAt: release.published_at,
      url: release.html_url,
      assets: release.assets.map((asset) => ({
        id: asset.id,
        name: asset.name,
        size: asset.size,
        downloadCount: asset.download_count,
        downloadUrl: asset.browser_download_url,
      })),
    })),
    contributors: contributors.map((contributor) => ({
      login: contributor.login,
      avatarUrl: contributor.avatar_url,
      profileUrl: contributor.html_url,
      contributions: contributor.contributions,
    })),
    fetchedAt: new Date().toISOString(),
  }
}

function readCache(): CachedSnapshot | undefined {
  if (typeof window === 'undefined') return undefined
  try {
    return JSON.parse(window.localStorage.getItem(cacheKey) || '') as CachedSnapshot
  } catch {
    return undefined
  }
}

function writeCache(snapshot: GitHubSnapshot) {
  if (typeof window === 'undefined') return
  window.localStorage.setItem(cacheKey, JSON.stringify({ expiresAt: Date.now() + ttl, snapshot }))
}

export async function fetchGitHubSnapshot(force = false): Promise<GitHubSnapshot> {
  const cached = readCache()
  if (!force && cached && cached.expiresAt > Date.now()) return cached.snapshot

  try {
    const [repository, releases, contributors] = await Promise.all([
      request<GitHubRepositoryPayload>(''),
      request<GitHubReleasePayload[]>('/releases?per_page=5'),
      request<GitHubContributorPayload[]>('/contributors?per_page=12&anon=0'),
    ])
    const snapshot = mapGitHubPayload(repository, releases, contributors)
    writeCache(snapshot)
    return snapshot
  } catch {
    if (cached) return { ...cached.snapshot, stale: true }
    return { ...(fallbackSnapshot as GitHubSnapshot), stale: true }
  }
}
