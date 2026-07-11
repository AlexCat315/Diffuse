<script setup lang="ts">
import { inject, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
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

async function copyText(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value)
    return
  }
  const textarea = document.createElement('textarea')
  textarea.value = value
  textarea.style.position = 'fixed'
  textarea.style.opacity = '0'
  document.body.append(textarea)
  textarea.select()
  document.execCommand('copy')
  textarea.remove()
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
    button.textContent = 'Copy'
    button.addEventListener('click', async () => {
      await copyText(pre.querySelector('code')?.textContent || '')
      button.textContent = 'Copied'
      button.setAttribute('aria-label', 'Code copied')
      setTimeout(() => {
        button.textContent = 'Copy'
        button.setAttribute('aria-label', 'Copy code')
      }, 1400)
    })
    pre.append(button)
  }
})
</script>

<template><div ref="root"><slot /></div></template>
