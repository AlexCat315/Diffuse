import { ref } from 'vue'

export type Theme = 'dark' | 'light'
const theme = ref<Theme>('dark')
let initialized = false

function applyTheme(value: Theme) {
  theme.value = value
  if (typeof document !== 'undefined') document.documentElement.dataset.theme = value
}

export function useTheme() {
  if (!initialized && typeof window !== 'undefined') {
    const saved = window.localStorage.getItem('guava-theme') as Theme | null
    applyTheme(saved === 'light' ? 'light' : 'dark')
    initialized = true
  }

  function toggleTheme() {
    const next = theme.value === 'dark' ? 'light' : 'dark'
    applyTheme(next)
    if (typeof window !== 'undefined') window.localStorage.setItem('guava-theme', next)
  }

  return { theme, toggleTheme }
}
