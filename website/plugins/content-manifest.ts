import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, extname, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import matter from 'gray-matter'
import type { Plugin, ViteDevServer } from 'vite'

const websiteRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const repositoryRoot = resolve(websiteRoot, '..')
const docsRoot = resolve(repositoryRoot, 'docs')
const blogRoot = resolve(websiteRoot, 'content', 'blog')
const virtualId = 'virtual:guava-content'
const resolvedVirtualId = `\0${virtualId}`

const requiredFields = ['path', 'title', 'description', 'locale', 'translationKey', 'category', 'order', 'kind'] as const

export interface ScannedContent {
  sourcePath: string
  editPath: string
  path: string
  title: string
  description: string
  locale: 'zh' | 'en'
  translationKey: string
  category: string
  order: number
  kind: 'doc' | 'post' | 'roadmap'
  tags?: string[]
  publishedAt?: string
  updatedAt?: string
  draft?: boolean
  text: string
  headings: Array<{ level: number; title: string; slug: string }>
  raw: string
  isLegacyComponent: boolean
}

function listMarkdownFiles(directory: string): string[] {
  if (!existsSync(directory)) return []
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name)
    if (entry.isDirectory()) return listMarkdownFiles(path)
    return extname(entry.name) === '.md' ? [path] : []
  })
}

function slugify(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[`*_~]/g, '')
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
}

function stripMarkdown(value: string): string {
  return value
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/[>*_|~-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

function legacyComponent(path: string, raw: string): ScannedContent {
  const filename = path.split(sep).at(-1) ?? ''
  const slug = filename === 'README.md' ? '' : filename.replace(/\.md$/, '')
  const title = raw.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? slug
  const editPath = relative(repositoryRoot, path).split(sep).join('/')
  const description = filename === 'README.md'
    ? 'GuavaUI 内置组件的结构、状态、交互与主题契约。'
    : `${title} 的 GuavaUI 组件设计契约与交互规则。`

  return {
    sourcePath: path,
    editPath,
    path: `/zh/docs/components${slug ? `/${slug}` : ''}`,
    title,
    description,
    locale: 'zh',
    translationKey: `docs.components.${slug || 'index'}`,
    category: '组件',
    order: filename === 'README.md' ? 200 : 210 + filename.charCodeAt(0),
    kind: 'doc',
    text: stripMarkdown(raw),
    headings: extractHeadings(raw),
    raw,
    isLegacyComponent: true,
  }
}

function extractHeadings(raw: string): Array<{ level: number; title: string; slug: string }> {
  return [...raw.matchAll(/^(#{2,3})\s+(.+)$/gm)].map((match) => ({
    level: match[1].length,
    title: match[2].replace(/[`*_]/g, '').trim(),
    slug: encodeURIComponent(slugify(match[2])),
  }))
}

export function collectContent(): ScannedContent[] {
  const files = [...listMarkdownFiles(docsRoot), ...listMarkdownFiles(blogRoot)]
  const entries = files.map((sourcePath) => {
    const raw = readFileSync(sourcePath, 'utf8')
    const editPath = relative(repositoryRoot, sourcePath).split(sep).join('/')
    const isLegacyComponent = editPath.startsWith('docs/components/')
    if (isLegacyComponent) return legacyComponent(sourcePath, raw)

    const parsed = matter(raw)
    for (const field of requiredFields) {
      if (parsed.data[field] === undefined || parsed.data[field] === '') {
        throw new Error(`${editPath}: missing frontmatter field "${field}"`)
      }
    }
    if (!['zh', 'en'].includes(parsed.data.locale)) throw new Error(`${editPath}: locale must be zh or en`)
    if (!['doc', 'post', 'roadmap'].includes(parsed.data.kind)) throw new Error(`${editPath}: invalid content kind`)
    if (!String(parsed.data.path).startsWith(`/${parsed.data.locale}/`)) {
      throw new Error(`${editPath}: path must start with /${parsed.data.locale}/`)
    }

    return {
      sourcePath,
      editPath,
      path: parsed.data.path,
      title: parsed.data.title,
      description: parsed.data.description,
      locale: parsed.data.locale,
      translationKey: parsed.data.translationKey,
      category: parsed.data.category,
      order: Number(parsed.data.order),
      kind: parsed.data.kind,
      tags: parsed.data.tags,
      publishedAt: parsed.data.publishedAt,
      updatedAt: parsed.data.updatedAt,
      draft: parsed.data.draft,
      text: stripMarkdown(parsed.content),
      headings: extractHeadings(parsed.content),
      raw,
      isLegacyComponent: false,
    } satisfies ScannedContent
  })

  const paths = new Set<string>()
  for (const entry of entries) {
    if (paths.has(entry.path)) throw new Error(`Duplicate content route: ${entry.path}`)
    paths.add(entry.path)
  }
  return entries.sort((a, b) => a.locale.localeCompare(b.locale) || a.order - b.order || a.title.localeCompare(b.title))
}

function moduleSource(): string {
  const entries = collectContent().filter((entry) => !entry.draft)
  const imports = entries.map((entry, index) => `import Content${index} from ${JSON.stringify(`/@fs${entry.sourcePath}`)}`).join('\n')
  const records = entries.map((entry, index) => {
    const { sourcePath: _sourcePath, raw: _raw, isLegacyComponent: _legacy, ...publicEntry } = entry
    return `{ ...${JSON.stringify(publicEntry)}, component: Content${index} }`
  }).join(',\n')
  return `${imports}\nexport const contentEntries = [${records}]\n`
}

function invalidate(server: ViteDevServer) {
  const module = server.moduleGraph.getModuleById(resolvedVirtualId)
  if (module) server.moduleGraph.invalidateModule(module)
}

export function contentManifestPlugin(): Plugin {
  return {
    name: 'guava-content-manifest',
    enforce: 'pre',
    resolveId(id) {
      return id === virtualId ? resolvedVirtualId : undefined
    },
    load(id) {
      return id === resolvedVirtualId ? moduleSource() : undefined
    },
    configureServer(server) {
      server.watcher.add([docsRoot, blogRoot])
      server.watcher.on('all', (_event, path) => {
        if (path.endsWith('.md')) invalidate(server)
      })
    },
  }
}

export function resolveMarkdownLink(entry: ScannedContent, link: string): string | undefined {
  const [pathPart] = link.split('#')
  if (!pathPart.endsWith('.md')) return undefined
  return resolve(dirname(entry.sourcePath), pathPart)
}
