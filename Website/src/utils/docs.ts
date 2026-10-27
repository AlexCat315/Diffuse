/** Documentation manifest — the sidebar tree. */
export interface DocLeaf {
  slug: string
  title: string
  raw: string
}
export interface DocGroup {
  group: string
  items: DocLeaf[]
}

import build from '@/content/build.md?raw'
import architecture from '@/content/architecture.md?raw'
import agentRuntime from '@/content/agent-runtime.md?raw'
import pluginDevelopment from '@/content/plugin-development.md?raw'
import pluginServices from '@/content/plugin-services.md?raw'
import conversations from '@/content/conversations.md?raw'

export const docGroups: DocGroup[] = [
  {
    group: '指南',
    items: [
      { slug: 'build', title: '构建指南', raw: build },
      { slug: 'architecture', title: '架构概览', raw: architecture },
    ],
  },
  {
    group: 'AI 与扩展',
    items: [
      { slug: 'conversations', title: '项目与会话', raw: conversations },
      { slug: 'plugin-development', title: '插件开发', raw: pluginDevelopment },
      { slug: 'plugin-services', title: '服务与 AI 扩展', raw: pluginServices },
      { slug: 'agent-runtime', title: 'Agent 运行时', raw: agentRuntime },
    ],
  },
]

export const allDocs: DocLeaf[] = docGroups.flatMap((g) => g.items)

export function findDoc(slug?: string): DocLeaf {
  return allDocs.find((d) => d.slug === slug) ?? allDocs[0]
}
