const KEYWORDS =
  /\b(import|func|let|var|struct|class|enum|protocol|extension|return|if|else|for|while|switch|case|default|guard|in|init|self|nil|true|false|private|public|internal|static|final|throws|try|await|async|do|catch|some|where|typealias|associatedtype|deinit|subscript|operator|break|continue|repeat|defer|inout|weak|unowned|indirect|convenience|required|override|open|mutating|nonmutating|get|set|willSet|didSet)\b/g

const SHELL_KEYWORDS =
  /\b(curl|sh|sudo|brew|apt|winget|git|cd|ls|export|set|if|then|fi|echo|source|chmod|mkdir|cmake|ninja|swift)\b/g

const STRING_RE = /(&quot;.*?&quot;|&#39;.*?&#39;)/g

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

export function highlight(src: string, lang: string): string {
  const isShell = /^(sh|bash|shell|powershell|ps1|zsh)$/i.test(lang)
  const lines = src.replace(/\n$/, '').split('\n')

  return lines
    .map((line) => {
      let out = escapeHtml(line)
      let comment = ''

      const commentMatch = out.match(isShell ? /#/ : /(\/\/|\/\*)/)
      if (commentMatch && commentMatch.index !== undefined) {
        comment = `<span class="tok-comment">${out.slice(commentMatch.index)}</span>`
        out = out.slice(0, commentMatch.index)
      }

      let mark = 0xe000
      const tokens = new Map<string, string>()
      out = out.replace(STRING_RE, (m) => {
        const token = String.fromCodePoint(mark++)
        tokens.set(token, m)
        return token
      })

      out = out.replace(
        isShell ? SHELL_KEYWORDS : KEYWORDS,
        '<span class="tok-keyword">$&</span>',
      )
      if (!isShell) {
        out = out.replace(/\b(\d+\.?\d*)\b/g, '<span class="tok-number">$1</span>')
      }

      for (const [token, s] of tokens) {
        out = out.split(token).join(`<span class="tok-string">${s}</span>`)
      }

      return out + comment
    })
    .join('\n')
}
