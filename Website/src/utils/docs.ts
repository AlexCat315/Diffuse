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
    items: [{ slug: 'agent-runtime', title: 'Agent 运行时', raw: agentRuntime }],
  },
]

export const allDocs: DocLeaf[] = docGroups.flatMap((g) => g.items)

export function findDoc(slug?: string): DocLeaf {
  return allDocs.find((d) => d.slug === slug) ?? allDocs[0]
}
