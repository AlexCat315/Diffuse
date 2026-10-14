import { existsSync } from 'node:fs'
import { collectContent, resolveMarkdownLink } from '../plugins/content-manifest'

const entries = collectContent()
// Keep translation gates aligned with the documentation currently shipped.
// Single-language architecture guides remain valid and can gain a counterpart later.
const requiredTranslations = ['docs.contributing', 'blog.v007']

for (const key of requiredTranslations) {
  for (const locale of ['zh', 'en']) {
    if (!entries.some((entry) => entry.translationKey === key && entry.locale === locale)) {
      throw new Error(`Missing ${locale} translation for ${key}`)
    }
  }
}

const markdownLink = /\[[^\]]*\]\(([^)]+\.md(?:#[^)]+)?)\)/g
for (const entry of entries) {
  for (const match of entry.raw.matchAll(markdownLink)) {
    const target = resolveMarkdownLink(entry, match[1])
    if (target && !existsSync(target)) {
      throw new Error(`${entry.editPath}: broken Markdown link ${match[1]}`)
    }
  }
}

console.log(`Validated ${entries.length} content pages and all required translations.`)
