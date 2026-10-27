<script setup lang="ts">
import { RouterLink } from 'vue-router'

const year = new Date().getFullYear()

const columns = [
  {
    title: '产品',
    links: [
      { label: '工作流', to: '/workflows' },
      { label: '插件生态', to: '/plugins' },
      { label: '下载', to: '/download' },
    ],
  },
  {
    title: '资源',
    links: [
      { label: '构建指南', to: '/docs/build' },
      { label: '架构', to: '/docs/architecture' },
      { label: 'Agent 运行时', to: '/docs/agent-runtime' },
    ],
  },
]
</script>

<template>
  <footer class="footer">
    <div class="container">
      <div class="footer-grid">
        <div class="footer-brand">
          <div class="brand-row">
            <svg viewBox="0 0 64 64" width="28" height="28">
              <circle cx="16" cy="16" r="7" fill="url(#fg)" />
              <circle cx="48" cy="16" r="7" fill="url(#fg)" opacity="0.8" />
              <circle cx="32" cy="32" r="7" fill="url(#fg)" />
              <circle cx="16" cy="48" r="7" fill="url(#fg)" opacity="0.7" />
              <circle cx="48" cy="48" r="7" fill="url(#fg)" opacity="0.85" />
              <defs>
                <linearGradient id="fg" x1="0" y1="0" x2="1" y2="1">
                  <stop offset="0" stop-color="#c084fc" />
                  <stop offset="0.5" stop-color="#f472b6" />
                  <stop offset="1" stop-color="#fb923c" />
                </linearGradient>
              </defs>
            </svg>
            <span>Diffuse</span>
          </div>
          <p>AI Agent 驱动的综合创作工作站，从文本到影片，一个应用完成。</p>
          <div class="socials">
            <a href="https://github.com/AlexCat315/Diffuse" target="_blank" rel="noopener" aria-label="GitHub">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 .5C5.7.5.5 5.7.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.3.8-.6v-2c-3.2.7-3.9-1.5-3.9-1.5-.5-1.3-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.7-1.6-2.6-.3-5.3-1.3-5.3-5.8 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3.1 0 0 1-.3 3.3 1.2a11.5 11.5 0 0 1 6 0C17.3 4.7 18.3 5 18.3 5c.6 1.6.2 2.8.1 3.1.8.8 1.2 1.8 1.2 3.1 0 4.5-2.7 5.5-5.3 5.8.4.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6 4.6-1.5 7.9-5.8 7.9-10.9C23.5 5.7 18.3.5 12 .5z" />
              </svg>
            </a>
          </div>
        </div>

        <div v-for="col in columns" :key="col.title" class="footer-col">
          <h4>{{ col.title }}</h4>
          <RouterLink v-for="l in col.links" :key="l.label" :to="l.to">{{ l.label }}</RouterLink>
        </div>

        <div class="footer-col">
          <h4>底层技术</h4>
          <a href="https://github.com/AlexCat315/Cove" target="_blank" rel="noopener">Cove UI 框架</a>
          <a href="https://github.com/AlexCat315/Natsel" target="_blank" rel="noopener">Natsel 物理引擎</a>
        </div>
      </div>

      <div class="footer-bottom">
        <span>© {{ year }} Diffuse. Apache License 2.0</span>
        <span>Swift · Metal · DX12 · Vulkan · FFmpeg · Wasmtime</span>
      </div>
    </div>
  </footer>
</template>

<style scoped>
.footer {
  position: relative;
  z-index: 1;
  border-top: 1px solid var(--border);
  background: rgba(7, 4, 15, 0.75);
  padding: 72px 0 32px;
  margin-top: 40px;
}
.footer-grid {
  display: grid;
  grid-template-columns: 2fr 1fr 1fr 1fr;
  gap: 48px;
}
.brand-row {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 20px;
  font-weight: 800;
  margin-bottom: 14px;
}
.footer-brand p {
  color: var(--text-dim);
  font-size: 14px;
  max-width: 300px;
  margin-bottom: 18px;
}
.socials { display: flex; gap: 14px; }
.socials a { color: var(--text-faint); transition: color 0.2s, transform 0.2s; }
.socials a:hover { color: var(--primary); transform: translateY(-2px); }
.footer-col h4 { font-size: 14px; margin-bottom: 16px; }
.footer-col a {
  display: block;
  color: var(--text-dim);
  font-size: 14px;
  padding: 5px 0;
  transition: color 0.2s;
}
.footer-col a:hover { color: var(--primary-soft); }
.footer-bottom {
  margin-top: 56px;
  padding-top: 24px;
  border-top: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  color: var(--text-faint);
  font-size: 13px;
}
@media (max-width: 900px) {
  .footer-grid { grid-template-columns: 1fr 1fr; gap: 36px; }
  .footer-brand { grid-column: 1 / -1; }
  .footer-bottom { flex-direction: column; gap: 8px; }
}
</style>
