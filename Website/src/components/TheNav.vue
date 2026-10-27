<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { RouterLink, useRoute } from 'vue-router'

const scrolled = ref(false)
const menuOpen = ref(false)
const route = useRoute()

const links = [
  { to: '/', label: '首页' },
  { to: '/workflows', label: '工作流' },
  { to: '/plugins', label: '插件' },
  { to: '/docs', label: '文档' },
  { to: '/download', label: '下载' },
]

function onScroll() {
  scrolled.value = window.scrollY > 24
}
function closeMenu() {
  menuOpen.value = false
}

onMounted(() => window.addEventListener('scroll', onScroll, { passive: true }))
onBeforeUnmount(() => window.removeEventListener('scroll', onScroll))
</script>

<template>
  <header class="nav" :class="{ scrolled }">
    <div class="container nav-inner">
      <RouterLink to="/" class="brand" @click="closeMenu">
        <span class="brand-mark">
          <svg viewBox="0 0 64 64" width="30" height="30">
            <circle cx="16" cy="16" r="7" fill="url(#ng)" />
            <circle cx="48" cy="16" r="7" fill="url(#ng)" opacity="0.8" />
            <circle cx="32" cy="32" r="7" fill="url(#ng)" />
            <circle cx="16" cy="48" r="7" fill="url(#ng)" opacity="0.7" />
            <circle cx="48" cy="48" r="7" fill="url(#ng)" opacity="0.85" />
            <defs>
              <linearGradient id="ng" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0" stop-color="#c084fc" />
                <stop offset="0.5" stop-color="#f472b6" />
                <stop offset="1" stop-color="#fb923c" />
              </linearGradient>
            </defs>
          </svg>
        </span>
        <span class="brand-name">Diffuse</span>
      </RouterLink>

      <nav class="nav-links" :class="{ open: menuOpen }">
        <RouterLink
          v-for="l in links"
          :key="l.to"
          :to="l.to"
          class="nav-link"
          :class="{ active: route.path === l.to || (l.to === '/docs' && route.path.startsWith('/docs')) }"
          @click="closeMenu"
        >
          {{ l.label }}
        </RouterLink>
        <a class="nav-link" href="https://github.com/AlexCat315/Diffuse" target="_blank" rel="noopener">GitHub</a>
      </nav>

      <div class="nav-actions">
        <RouterLink to="/download" class="btn btn-primary nav-cta">立即体验</RouterLink>
        <button class="burger" :class="{ active: menuOpen }" aria-label="菜单" @click="menuOpen = !menuOpen">
          <span></span><span></span><span></span>
        </button>
      </div>
    </div>
  </header>
</template>

<style scoped>
.nav {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  z-index: 100;
  height: var(--nav-h);
  display: flex;
  align-items: center;
  transition: background 0.3s, border-color 0.3s, backdrop-filter 0.3s;
  border-bottom: 1px solid transparent;
}
.nav.scrolled {
  background: rgba(10, 7, 20, 0.8);
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
  border-bottom-color: var(--border);
}
.nav-inner {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
}
.brand-name {
  font-size: 22px;
  font-weight: 800;
  letter-spacing: -0.03em;
}
.nav-links {
  display: flex;
  gap: 6px;
}
.nav-link {
  padding: 8px 16px;
  border-radius: 999px;
  font-size: 15px;
  font-weight: 500;
  color: var(--text-dim);
  transition: color 0.2s, background 0.2s;
}
.nav-link:hover {
  color: var(--text);
  background: rgba(255, 255, 255, 0.05);
}
.nav-link.active {
  color: var(--primary-soft);
  background: rgba(192, 132, 252, 0.12);
}
.nav-actions {
  display: flex;
  align-items: center;
  gap: 12px;
}
.nav-cta {
  padding: 10px 22px;
  font-size: 14px;
}
.burger {
  display: none;
  flex-direction: column;
  gap: 5px;
  background: none;
  border: none;
  cursor: pointer;
  padding: 8px;
}
.burger span {
  width: 22px;
  height: 2px;
  background: var(--text);
  border-radius: 2px;
  transition: transform 0.3s, opacity 0.3s;
}
.burger.active span:nth-child(1) { transform: translateY(7px) rotate(45deg); }
.burger.active span:nth-child(2) { opacity: 0; }
.burger.active span:nth-child(3) { transform: translateY(-7px) rotate(-45deg); }

@media (max-width: 900px) {
  .burger { display: flex; }
  .nav-cta { display: none; }
  .nav-links {
    position: fixed;
    top: var(--nav-h);
    left: 0;
    right: 0;
    flex-direction: column;
    padding: 16px;
    gap: 4px;
    background: rgba(10, 7, 20, 0.98);
    backdrop-filter: blur(20px);
    border-bottom: 1px solid var(--border);
    transform: translateY(-12px);
    opacity: 0;
    pointer-events: none;
    transition: transform 0.3s, opacity 0.3s;
  }
  .nav-links.open { transform: none; opacity: 1; pointer-events: auto; }
  .nav-link { padding: 14px 18px; font-size: 16px; }
}
</style>
