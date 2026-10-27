import type { Directive } from 'vue'

/**
 * Scroll-reveal. Uses a single global IntersectionObserver plus a
 * MutationObserver so dynamically inserted `.reveal` nodes (including inside
 * multi-root / transitioned views) are tracked without relying on a
 * component's root element.
 */

let io: IntersectionObserver | null = null

function ensureObserver(): IntersectionObserver {
  if (io) return io
  io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        const t = entry.target as HTMLElement
        const delay = t.dataset.revealDelay
        if (delay) t.style.transitionDelay = `${delay}ms`
        t.classList.add('is-visible')
        io?.unobserve(t)
      }
    },
    { threshold: 0.12, rootMargin: '0px 0px -40px 0px' },
  )
  return io
}

export function observeReveals(root: ParentNode = document): void {
  if (!('IntersectionObserver' in window)) {
    root.querySelectorAll<HTMLElement>('.reveal').forEach((el) => el.classList.add('is-visible'))
    return
  }
  const observer = ensureObserver()
  root
    .querySelectorAll<HTMLElement>('.reveal:not(.is-visible)')
    .forEach((el) => observer.observe(el))
}

export function startRevealWatcher(): void {
  if (!('IntersectionObserver' in window)) {
    observeReveals()
    return
  }
  observeReveals()
  const mo = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of Array.from(m.addedNodes)) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue
        const el = node as HTMLElement
        if (el.classList?.contains('reveal')) ensureObserver().observe(el)
        el
          .querySelectorAll?.<HTMLElement>('.reveal:not(.is-visible)')
          .forEach((n) => ensureObserver().observe(n))
      }
    }
  })
  mo.observe(document.body, { childList: true, subtree: true })
}

/** Backwards-compatible directive: observe the element and its descendants. */
export const revealDirective: Directive<HTMLElement> = {
  mounted(el) {
    if (el.classList.contains('reveal')) ensureObserver().observe(el)
    observeReveals(el)
  },
}
