<script setup lang="ts">
import { RouterLink } from 'vue-router'
import ParticleField from '@/components/ParticleField.vue'
import AgentChat from '@/components/AgentChat.vue'
import TiltCard from '@/components/TiltCard.vue'

const workflows = [
  {
    name: '文本与代码',
    en: 'Write & Code',
    desc: '文档与代码编辑共用一套 Agent 工具入口，语言服务提供补全、诊断与重构。',
    icon: 'M4 6h16M4 12h16M4 18h10',
    tint: '#c084fc',
  },
  {
    name: '游戏开发',
    en: 'Game Dev',
    desc: '场景、三维渲染、物理与 Swift 脚本全链路打通，静态编译直达桌面与移动端。',
    icon: 'M6 12h4m-2-2v4M15 11h.01M18 13h.01M2 12a10 10 0 1 1 20 0 10 10 0 0 1-20 0z',
    tint: '#f472b6',
  },
  {
    name: '动画制作',
    en: 'Animation',
    desc: '序列、骨骼动画与布娃娃，关键帧与时间线联动，影视级渲染随时预览。',
    icon: 'M12 3v18M5 8l7-5 7 5M5 16l7 5 7-5',
    tint: '#fb923c',
  },
  {
    name: '视频剪辑',
    en: 'Video Cut',
    desc: '裁剪、排序、帧预览、播放与 MP4 导出，FFmpeg 负责解码与重采样。',
    icon: 'M4 5h16v14H4zM10 9l5 3-5 3z',
    tint: '#a78bfa',
  },
]

const engineCaps = [
  { name: 'Native Renderer', desc: 'Metal / DX12 / Vulkan 统一渲染后端' },
  { name: 'Cinematic Renderer', desc: 'OpenEXR 影视管线与色彩管线' },
  { name: 'Natsel Physics', desc: '刚体、车辆、角色、布娃娃与软体' },
  { name: 'Script Runtime', desc: 'Swift 游戏脚本静态编译' },
  { name: 'Wasmtime Plugins', desc: 'WASM 插件沙箱，49.0.2' },
  { name: 'Observation Bus', desc: 'Agent 可观察的引擎事件总线' },
]

const timelineSteps = [
  { t: '导入素材', d: 'FFmpeg 解码视频、音频与图像' },
  { t: '时间线编排', d: '裁剪、排序、帧预览' },
  { t: 'Agent 协作', d: '自然语言生成剪辑与转场' },
  { t: 'MP4 导出', d: '重采样、编码、一键交付' },
]
</script>

<template>
  <ParticleField />

  <!-- ================= HERO ================= -->
  <section class="hero">
    <div class="container hero-inner">
      <div class="hero-content">
        <div class="hero-badge">
          <span class="spark">✦</span>
          AI Agent 驱动 · Swift 原生 · 一个应用四种创作
        </div>
        <h1 class="hero-title">
          让创意<br />
          <span class="gradient-text">自由漫反射</span>
        </h1>
        <p class="hero-sub">
          Diffuse 是基于 Swift 构建的综合创作工作站：文本与代码编辑、游戏开发、动画制作、视频剪辑——
          由 AI Agent 贯穿始终，你说想法，它来动手。
        </p>
        <div class="hero-cta">
          <RouterLink to="/download" class="btn btn-primary">
            下载体验
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <path d="M5 12h14M12 5l7 7-7 7" />
            </svg>
          </RouterLink>
          <RouterLink to="/workflows" class="btn btn-ghost">探索工作流</RouterLink>
        </div>
        <div class="hero-pills">
          <span>Metal</span><span>DX12</span><span>Vulkan</span><span>FFmpeg</span><span>Wasmtime</span><span>OpenEXR</span>
        </div>
      </div>

      <div class="hero-demo">
        <AgentChat />
      </div>
    </div>
  </section>

  <!-- ================= WORKFLOWS ================= -->
  <section class="section" id="workflows">
    <div class="container">
      <div class="reveal">
        <span class="eyebrow">四大工作流</span>
        <h2 class="section-title">一个工作站，装下整个创作管线</h2>
        <p class="section-sub">所有工作流共享同一份引擎、同一套 UI 与同一个 Agent，工具之间不再割裂。</p>
      </div>

      <div class="wf-grid">
        <TiltCard v-for="(w, i) in workflows" :key="w.name" class="reveal" :data-reveal-delay="i * 90">
          <div class="wf-card glass">
            <div class="wf-icon" :style="{ color: w.tint, background: `${w.tint}1f` }">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                <path :d="w.icon" />
              </svg>
            </div>
            <div class="wf-en">{{ w.en }}</div>
            <h3>{{ w.name }}</h3>
            <p>{{ w.desc }}</p>
          </div>
        </TiltCard>
      </div>
    </div>
  </section>

  <!-- ================= ENGINE CAPS ================= -->
  <section class="section caps-section">
    <div class="container">
      <div class="caps-layout">
        <div class="caps-copy reveal">
          <span class="eyebrow">引擎底座</span>
          <h2 class="section-title">专业级引擎，为创作托底</h2>
          <p class="section-sub">
            26 个引擎模块协同工作：渲染、物理、音频、脚本、AI 运行时、资产管线与观察总线，
            全部由 Swift 与原生代码构建。
          </p>
          <RouterLink to="/docs/architecture" class="btn btn-ghost">查看架构</RouterLink>
        </div>
        <div class="caps-grid">
          <div v-for="(c, i) in engineCaps" :key="c.name" class="cap-item glass reveal" :data-reveal-delay="i * 70">
            <strong>{{ c.name }}</strong>
            <span>{{ c.desc }}</span>
          </div>
        </div>
      </div>
    </div>
  </section>

  <!-- ================= VIDEO TIMELINE ================= -->
  <section class="section">
    <div class="container">
      <div class="reveal">
        <span class="eyebrow">视频管线</span>
        <h2 class="section-title">从素材到成片，四步完成</h2>
      </div>
      <div class="timeline">
        <div class="timeline-line"></div>
        <div v-for="(s, i) in timelineSteps" :key="s.t" class="timeline-step reveal" :data-reveal-delay="i * 120">
          <div class="step-dot">{{ i + 1 }}</div>
          <h4>{{ s.t }}</h4>
          <p>{{ s.d }}</p>
        </div>
      </div>
    </div>
  </section>

  <!-- ================= FINAL CTA ================= -->
  <section class="section">
    <div class="container reveal">
      <div class="cta-box glass">
        <h2>把下一个作品交给 Diffuse</h2>
        <p>下载工作站，和 Agent 一起，从一句话开始创作。</p>
        <div class="hero-cta" style="justify-content: center">
          <RouterLink to="/download" class="btn btn-primary">立即下载</RouterLink>
          <RouterLink to="/plugins" class="btn btn-ghost">浏览插件生态</RouterLink>
        </div>
      </div>
    </div>
  </section>
</template>

<style scoped>
/* HERO */
.hero {
  position: relative;
  min-height: 100vh;
  display: flex;
  align-items: center;
  padding: calc(var(--nav-h) + 50px) 0 60px;
}
.hero-inner {
  position: relative;
  z-index: 1;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 56px;
  align-items: center;
}
.hero-badge {
  display: inline-flex;
  align-items: center;
  gap: 9px;
  padding: 7px 16px;
  border-radius: 999px;
  border: 1px solid var(--border-strong);
  background: var(--surface);
  font-size: 13px;
  color: var(--text-dim);
  margin-bottom: 26px;
}
.spark {
  color: var(--secondary);
  animation: spin 6s linear infinite;
  display: inline-block;
}
@keyframes spin { to { transform: rotate(360deg); } }

.hero-title {
  font-size: clamp(40px, 5.4vw, 66px);
  margin-bottom: 22px;
}
.hero-sub {
  font-size: 17px;
  color: var(--text-dim);
  max-width: 540px;
  margin-bottom: 34px;
}
.hero-cta {
  display: flex;
  gap: 14px;
  flex-wrap: wrap;
  margin-bottom: 32px;
}
.hero-pills {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.hero-pills span {
  font-family: var(--font-mono);
  font-size: 12px;
  padding: 4px 12px;
  border-radius: 999px;
  border: 1px solid var(--border);
  color: var(--text-faint);
}

/* WORKFLOWS */
.wf-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 18px;
  margin-top: 50px;
}
.wf-card {
  padding: 28px 22px;
  height: 100%;
}
.wf-icon {
  width: 48px;
  height: 48px;
  border-radius: 13px;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 16px;
}
.wf-en {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--text-faint);
}
.wf-card h3 {
  font-size: 19px;
  margin: 4px 0 10px;
}
.wf-card p {
  font-size: 13.5px;
  color: var(--text-dim);
}

/* CAPS */
.caps-section {
  background: linear-gradient(180deg, transparent, rgba(18, 12, 34, 0.6), transparent);
}
.caps-layout {
  display: grid;
  grid-template-columns: 1fr 1.2fr;
  gap: 52px;
  align-items: center;
}
.caps-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 14px;
}
.cap-item {
  padding: 20px 22px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  transition: transform 0.3s, border-color 0.3s;
}
.cap-item:hover {
  transform: translateY(-4px);
  border-color: var(--border-strong);
}
.cap-item strong {
  font-size: 14.5px;
}
.cap-item span {
  font-size: 12.5px;
  color: var(--text-dim);
}

/* TIMELINE */
.timeline {
  position: relative;
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 24px;
  margin-top: 60px;
}
.timeline-line {
  position: absolute;
  top: 22px;
  left: 6%;
  right: 6%;
  height: 2px;
  background: var(--gradient);
  opacity: 0.5;
}
.timeline-step {
  position: relative;
  text-align: center;
}
.step-dot {
  width: 44px;
  height: 44px;
  margin: 0 auto 16px;
  border-radius: 50%;
  background: var(--bg);
  border: 2px solid var(--primary);
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
  color: var(--primary-soft);
  position: relative;
  z-index: 1;
}
.timeline-step h4 {
  font-size: 16px;
  margin-bottom: 6px;
}
.timeline-step p {
  font-size: 13px;
  color: var(--text-dim);
}

/* CTA */
.cta-box {
  text-align: center;
  padding: 68px 40px;
}
.cta-box h2 {
  font-size: clamp(26px, 3.5vw, 38px);
  margin-bottom: 12px;
}
.cta-box p {
  color: var(--text-dim);
  margin-bottom: 30px;
}

@media (max-width: 1000px) {
  .hero-inner { grid-template-columns: 1fr; gap: 40px; }
  .wf-grid { grid-template-columns: repeat(2, 1fr); }
  .caps-layout { grid-template-columns: 1fr; }
  .timeline { grid-template-columns: repeat(2, 1fr); gap: 36px; }
  .timeline-line { display: none; }
}
@media (max-width: 560px) {
  .wf-grid, .caps-grid { grid-template-columns: 1fr; }
}
</style>
