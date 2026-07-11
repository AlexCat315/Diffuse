/// <reference types="vite/client" />

declare module '*.md' {
  import type { Component } from 'vue'
  const component: Component
  export default component
}

declare module 'virtual:guava-content' {
  import type { ContentEntry } from '@/types/content'
  export const contentEntries: ContentEntry[]
}
