import { ViteSSG } from 'vite-ssg'
import App from './App.vue'
import MarkdownBody from '@/components/MarkdownBody.vue'
import { routes } from './router'
import './styles/main.css'

export const createApp = ViteSSG(
  App,
  {
    routes,
    scrollBehavior: (to) => to.hash
      ? { el: `#${encodeURIComponent(to.hash.slice(1))}`, top: 96, behavior: 'smooth' }
      : { top: 0 },
  },
  ({ app }) => {
    app.component('MarkdownBody', MarkdownBody)
  },
)
