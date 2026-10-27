<script setup lang="ts">
import { RouterLink } from 'vue-router'
import TiltCard from '@/components/TiltCard.vue'

interface Workflow {
  id: string
  name: string
  en: string
  tint: string
  desc: string
  points: string[]
}

const workflows: Workflow[] = [
  {
    id: 'write',
    name: '文本与代码编辑',
    en: 'Write & Code',
    tint: '#c084fc',
    desc: '文档与代码在同一个应用中完成，语言服务与 Agent 共同辅助。',
    points: ['语言服务：补全、诊断、重构', 'Markdown 文档实时预览', 'Agent 生成、改写与解释代码', '多标签与多光标编辑'],
  },
  {
    id: 'game',
    name: '游戏开发',
    en: 'Game Dev',
    tint: '#f472b6',
    desc: '从场景搭建到物理与脚本，编辑器内一键试玩。',
    points: ['场景编辑器与三维视口', 'Natsel 物理：刚体 / 车辆 / 角色', 'Swift 游戏脚本静态编译', '桌面与 Android / iOS 一键导出'],
  },
  {
    id: 'anim',
    name: '动画制作',
    en: 'Animation',
    tint: '#fb923c',
    desc: '序列、骨骼与布娃娃动画，关键帧时间线实时联动。',
    points: ['骨骼动画与骨骼映射', '布娃娃与物理动画', '关键帧序列时间线', '影视级渲染即时预览'],
  },
  {
    id: 'video',
    name: '视频剪辑',
    en: 'Video Cut',
    tint: '#a78bfa',
    desc: '面向创作者的轻量剪辑管线，支持 Agent 自然语言操作。',
    points: ['裁剪、排序、帧预览', '多轨道与播放预览', 'Agent 语言剪辑与转场', 'MP4 导出（FFmpeg）'],
  },
]
</script>

<template>
  <div class="wf-page">
    <section class="wf-hero">
      <div class="container">
        <span class="eyebrow reveal">工作流</span>
        <h1 class="reveal" style="font-size: clamp(32px, 4.5vw, 50px)">四种创作，无缝切换</h1>
        <p class="reveal" style="color: var(--text-dim); max-width: 660px; font-size: 17px">
          不必在五六个软件之间来回导出。Diffuse 让所有工作流共享同一引擎、同一套素材与同一个 Agent。
        </p>
      </div>
    </section>

    <section class="container wf-list">
      <TiltCard v-for="(w, i) in workflows" :key="w.id" class="reveal" :data-reveal-delay="(i % 2) * 100">
        <div class="wf-detail glass">
          <div class="detail-head">
            <div class="detail-badge" :style="{ background: `${w.tint}22`, color: w.tint }">
              <span class="detail-en">{{ w.en }}</span>
            </div>
            <span class="detail-index">0{{ i + 1 }}</span>
          </div>
          <h2>{{ w.name }}</h2>
          <p class="detail-desc">{{ w.desc }}</p>
          <ul class="point-list">
            <li v-for="p in w.points" :key="p">
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" :stroke="w.tint" stroke-width="2.5">
                <path d="M20 6 9 17l-5-5" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
              {{ p }}
            </li>
          </ul>
        </div>
      </TiltCard>

      <div class="wf-cta glass reveal">
        <h2>全部工作流，一个安装包</h2>
        <p>下载 Diffuse，立即体验完整创作管线。</p>
        <RouterLink to="/download" class="btn btn-primary">前往下载</RouterLink>
      </div>
    </section>
  </div>
</template>

<style scoped>
.wf-page { padding-top: var(--nav-h); }
.wf-hero { padding: 60px 0 20px; }
.wf-list { padding-bottom: 100px; display: flex; flex-direction: column; gap: 22px; }

.wf-detail { padding: 40px 44px; }
.detail-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
}
.detail-badge {
  padding: 6px 16px;
  border-radius: 999px;
}
.detail-en {
  font-family: var(--font-mono);
  font-size: 12px;
  letter-spacing: 0.08em;
}
.detail-index {
  font-family: var(--font-mono);
  font-size: 30px;
  font-weight: 800;
  color: var(--text-faint);
  opacity: 0.5;
}
.wf-detail h2 { font-size: 27px; margin-bottom: 10px; }
.detail-desc { color: var(--text-dim); font-size: 15.5px; margin-bottom: 22px; }

.point-list {
  list-style: none;
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
}
.point-list li {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 14.5px;
  padding: 12px 16px;
  border: 1px solid var(--border);
  border-radius: 12px;
  background: rgba(255, 255, 255, 0.03);
}

.wf-cta {
  text-align: center;
  padding: 56px 30px;
}
.wf-cta h2 { font-size: 26px; margin-bottom: 10px; }
.wf-cta p { color: var(--text-dim); margin-bottom: 24px; }

@media (max-width: 700px) {
  .wf-detail { padding: 30px 24px; }
  .point-list { grid-template-columns: 1fr; }
}
</style>
