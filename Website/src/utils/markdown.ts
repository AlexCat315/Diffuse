import { marked } from 'marked'
import { highlight, escapeHtml } from './highlight'

/** Render markdown to HTML with highlighted, copyable code blocks. */
export function renderMarkdown(src: string): string {
  const renderer = new marked.Renderer()

  renderer.code = ({ text, lang }: { text: string; lang?: string }) => {
    const language = lang ?? 'text'
    const codeAttr = escapeHtml(text)
    const highlighted = /^(text|plain)$/i.test(language)
      ? escapeHtml(text)
      : highlight(text, language)
    return `<div class="md-code" data-code="${codeAttr}">
      <div class="md-code-head">
        <span>${escapeHtml(language)}</span>
        <button class="md-copy" type="button">复制</button>
      </div>
      <pre><code>${highlighted}</code></pre>
    </div>`
  }

  renderer.heading = ({ tokens, depth }) => {
    const text = tokens.map((t) => ('text' in t ? t.text : '')).join('')
    const id = slugify(text)
    return `<h${depth} id="${id}">${text}</h${depth}>`
  }

  marked.setOptions({ renderer, gfm: true, breaks: false })
  return marked.parse(src) as string
}

export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\u4e00-\u9fa5\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
}

export function extractToc(html: string): { id: string; text: string; depth: number }[] {
  const re = /<h([23]) id="([^"]+)">([^<]+)<\/h\1>/g
  const toc: { id: string; text: string; depth: number }[] = []
  let m: RegExpExecArray | null
  while ((m = re.exec(html))) {
    toc.push({ depth: Number(m[1]), id: m[2], text: m[3] })
  }
  return toc
}
