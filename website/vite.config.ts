import { fileURLToPath, URL } from 'node:url'
import Vue from '@vitejs/plugin-vue'
import Markdown from 'unplugin-vue-markdown/vite'
import MarkdownItAnchor from 'markdown-it-anchor'
import { defineConfig } from 'vitest/config'
import { contentManifestPlugin } from './plugins/content-manifest'

export default defineConfig({
  plugins: [
    contentManifestPlugin(),
    Vue({ include: [/\.vue$/, /\.md$/] }),
    Markdown({
      wrapperComponent: 'MarkdownBody',
      wrapperClasses: 'markdown-body',
      headEnabled: false,
      markdownOptions: { html: false, linkify: true, typographer: true },
      markdownSetup(md) {
        // markdown-exit intentionally accepts markdown-it plugins, but their
        // independently published TypeScript declarations are not identical.
        // @ts-expect-error compatible plugin API with divergent declarations
        md.use(MarkdownItAnchor, {
          permalink: MarkdownItAnchor.permalink.linkInsideHeader({
            symbol: '#',
            placement: 'before',
            ariaHidden: true,
          }),
        })
      },
    }),
  ],
  resolve: {
    alias: [
      { find: /^@root\/(.*)/, replacement: `${fileURLToPath(new URL('..', import.meta.url))}/$1` },
      { find: /^@\/(.*)/, replacement: `${fileURLToPath(new URL('./src', import.meta.url))}/$1` },
      { find: /^vue\/server-renderer$/, replacement: fileURLToPath(new URL('./node_modules/vue/server-renderer/index.mjs', import.meta.url)) },
      { find: /^vue$/, replacement: fileURLToPath(new URL('./node_modules/vue/dist/vue.esm-bundler.js', import.meta.url)) },
    ],
  },
  server: {
    fs: { allow: [fileURLToPath(new URL('..', import.meta.url))] },
  },
  ssgOptions: {
    dirStyle: 'nested',
    formatting: 'minify',
  },
  test: {
    environment: 'jsdom',
    globals: true,
  },
})
