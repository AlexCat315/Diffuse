import { readonly, ref } from 'vue'
import { fetchGitHubSnapshot } from '@/services/github'
import type { GitHubSnapshot } from '@/types/github'

const snapshot = ref<GitHubSnapshot>()
const loading = ref(false)

export function useGitHub() {
  async function load() {
    if (snapshot.value || loading.value || typeof window === 'undefined') return
    loading.value = true
    snapshot.value = await fetchGitHubSnapshot()
    loading.value = false
  }
  return { snapshot: readonly(snapshot), loading: readonly(loading), load }
}
