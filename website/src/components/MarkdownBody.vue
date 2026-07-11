<script setup lang="ts">
import { inject, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { Check, Copy } from '@lucide/vue'
import { createApp, h } from 'vue'
import { contentEntries } from 'virtual:guava-content'
import type { ContentEntry } from '@/types/content'

const root = ref<HTMLElement>()
const router = useRouter()
const entry = inject<ContentEntry>('content-entry')

function normalize(path: string) {
  const parts: string[] = []
  for (const part of path.split('/')) {
    if (part === '..') parts.pop()
    else if (part && part !== '.') parts.push(part)
  }
  return parts.join('/')
}

function onClick(event: MouseEvent) {
  const anchor = (event.target as HTMLElement).closest('a')
  if (!anchor || !entry) return
  const href = anchor.getAttribute('href') || ''
  if (href.startsWith('#') || href.startsWith('http') || !href.includes('.md')) return
  const sourceDirectory = entry.editPath.split('/').slice(0, -1).join('/')
  const [file, hash] = href.split('#')
  const targetSource = normalize(`${sourceDirectory}/${file}`)
  const target = contentEntries.find((candidate) => candidate.editPath === targetSource)
  if (target) {
    event.preventDefault()
    void router.push(`${target.path}${hash ? `#${hash}` : ''}`)
  }
}

onMounted(() => {
  if (!root.value) return
  root.value.addEventListener('click', onClick)
  for (const anchor of root.value.querySelectorAll<HTMLAnchorElement>('a[href^="http"]')) {
    anchor.target = '_blank'
    anchor.rel = 'noreferrer'
  }
  for (const pre of root.value.querySelectorAll('pre')) {
    const button = document.createElement('button')
    button.className = 'copy-code'
    button.type = 'button'
    button.setAttribute('aria-label', 'Copy code')
    const icon = createApp({ render: () => h(Copy, { size: 14 }) })
    icon.mount(button)
    button.addEventListener('click', async () => {
      await navigator.clipboard.writeText(pre.querySelector('code')?.textContent || '')
      icon.unmount()
      createApp({ render: () => h(Check, { size: 14 }) }).mount(button)
      setTimeout(() => { button.textContent = '✓' }, 1000)
    })
    pre.append(button)
  }
})
</script>

<template><div ref="root"><slot /></div></template>
