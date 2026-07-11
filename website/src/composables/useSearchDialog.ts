import { ref } from 'vue'

const searchOpen = ref(false)

export function useSearchDialog() {
  return {
    searchOpen,
    openSearch: () => { searchOpen.value = true },
    closeSearch: () => { searchOpen.value = false },
  }
}
