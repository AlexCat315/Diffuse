<script setup lang="ts">
import { RouterLink } from 'vue-router'
</script>

<template>
  <div class="nf-page">
    <div class="nf-content">
      <div class="nf-code">404</div>
      <h1>信号丢失，画面中断</h1>
      <p>你访问的页面不存在，或已被时间线裁掉。</p>
      <RouterLink to="/" class="btn btn-primary">返回首页</RouterLink>
    </div>
  </div>
</template>

<style scoped>
.nf-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 20px;
}
.nf-code {
  font-size: clamp(90px, 18vw, 180px);
  font-weight: 800;
  line-height: 1;
  background: var(--gradient);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
  animation: nfFloat 4s ease-in-out infinite;
}
@keyframes nfFloat { 50% { transform: translateY(-12px); } }
.nf-content h1 { font-size: 24px; margin: 10px 0; }
.nf-content p { color: var(--text-dim); margin-bottom: 28px; }
</style>
