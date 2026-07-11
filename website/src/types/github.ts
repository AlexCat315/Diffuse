export interface GitHubRepositorySummary {
  stars: number
  forks: number
  openIssues: number
  updatedAt: string
  url: string
}

export interface GitHubAsset {
  id: number
  name: string
  size: number
  downloadCount: number
  downloadUrl: string
}

export interface GitHubRelease {
  tag: string
  name: string
  publishedAt: string
  url: string
  assets: GitHubAsset[]
}

export interface GitHubContributor {
  login: string
  avatarUrl: string
  profileUrl: string
  contributions: number
}

export interface GitHubSnapshot {
  repository: GitHubRepositorySummary
  releases: GitHubRelease[]
  contributors: GitHubContributor[]
  fetchedAt: string
  stale?: boolean
}
