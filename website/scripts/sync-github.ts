import { writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const api = 'https://api.github.com/repos/AlexCat315/Guava-Engine'
const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'guava-engine-website' }

interface RepositoryPayload { stargazers_count: number; forks_count: number; open_issues_count: number; updated_at: string; html_url: string }
interface AssetPayload { id: number; name: string; size: number; download_count: number; browser_download_url: string }
interface ReleasePayload { tag_name: string; name: string | null; published_at: string; html_url: string; assets: AssetPayload[] }
interface ContributorPayload { login: string; avatar_url: string; html_url: string; contributions: number }

async function get<T>(path: string): Promise<T> {
  const response = await fetch(`${api}${path}`, { headers })
  if (!response.ok) throw new Error(`GitHub API ${response.status}: ${path}`)
  return response.json() as Promise<T>
}

const [repository, releases, contributors] = await Promise.all([
  get<RepositoryPayload>(''),
  get<ReleasePayload[]>('/releases?per_page=5'),
  get<ContributorPayload[]>('/contributors?per_page=12&anon=0'),
])

const snapshot = {
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

await writeFile(resolve('src/data/github-fallback.json'), `${JSON.stringify(snapshot, null, 2)}\n`)
console.log(`Saved GitHub snapshot with ${snapshot.releases.length} releases.`)
