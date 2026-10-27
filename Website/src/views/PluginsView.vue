<script setup lang="ts">
import { RouterLink } from 'vue-router'
import TiltCard from '@/components/TiltCard.vue'

const pluginTypes = [
  {
    name: '原生插件',
    en: 'Native',
    desc: '通过 PluginRuntime 直接加载，性能无损，适合重型计算与深度集成。',
    icon: 'M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3',
    tint: '#c084fc',
  },
  {
    name: 'WASM 插件',
    en: 'WebAssembly',
    desc: '在 Wasmtime 沙箱中运行，跨平台、安全隔离，iOS 使用 Pulley。',
    icon: 'M12 2 2 7l10 5 10-5zM2 17l10 5 10-5M2 12l10 5 10-5',
    tint: '#f472b6',
  },
  {
    name: 'MCP 服务',
    en: 'MCP Server',
    desc: 'DiffuseMCP 把能力暴露给外部 LLM agent，标准协议、即插即用。',
    icon: 'M5 12h14M12 5l7 7-7 7',
    tint: '#fb923c',
  },
]

const plugins = [
  { name: 'FFmpeg Bridge', cat: '媒体', desc: '扩展更多编码格式与媒体处理能力。' },
  { name: 'OpenEXR Toolkit', cat: '影视', desc: 'HDR 图像与多通道 EXR 工作流。' },
  { name: 'Wasmtime Runtime', cat: '运行时', desc: '固定版本 49.0.2，SHA-256 校验。' },
  { name: 'Card Battle Kit', cat: '游戏', desc: '卡牌战斗运行时与模板。' },
  { name: 'Color Grading Lab', cat: '色彩', desc: '高级调色与 LUT 支持。' },
  { name: 'Agent Skills', cat: 'AI', desc: '为 Agent 增加可调用的专业技能。' },
]

const guarantees = [
  { t: '沙箱隔离', d: 'WASM 插件无法直接访问宿主文件与网络。' },
  { t: '能力受控', d: '插件能力经 CapabilityRuntime 显式授权。' },
  { t: '版本锁定', d: 'Wasmtime 等核心依赖固定版本并校验校验和。' },
  { t: '可观察', d: '插件行为经 ObservationBus 记录与回放。' },
]
</script>

<template>
  <div class="plugins-page">
    <section class="pl-hero">
      <div class="container">
        <span class="eyebrow reveal">插件生态</span>
        <h1 class="reveal" style="font-size: clamp(32px, 4.5vw, 50px)">按需扩展，安全可控</h1>
        <p class="reveal" style="color: var(--text-dim); max-width: 660px; font-size: 17px">
          原生插件追求极致性能，WASM 插件保证安全可移植，MCP 服务连接外部 Agent。
        </p>
      </div>
    </section>

    <section class="container pl-types">
      <div class="types-grid">
        <TiltCard v-for="(t, i) in pluginTypes" :key="t.name" class="reveal" :data-reveal-delay="i * 100">
          <div class="type-card glass">
            <div class="type-icon" :style="{ color: t.tint, background: `${t.tint}20` }">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                <path :d="t.icon" />
              </svg>
            </div>
            <div class="type-en">{{ t.en }}</div>
            <h3>{{ t.name }}</h3>
            <p>{{ t.desc }}</p>
          </div>
        </TiltCard>
      </div>
    </section>

    <section class="container pl-market">
      <div class="reveal">
        <h2 class="section-title">扩展市场</h2>
      </div>
      <div class="market-grid">
        <div v-for="(p, i) in plugins" :key="p.name" class="market-card glass reveal" :data-reveal-delay="(i % 3) * 80">
          <div class="market-top">
            <h3>{{ p.name }}</h3>
            <span class="cat">{{ p.cat }}</span>
          </div>
          <p>{{ p.desc }}</p>
          <button class="install-btn">安装</button>
        </div>
      </div>
    </section>

    <section class="container pl-guarantees">
      <div class="guarantees-grid">
        <div v-for="(g, i) in guarantees" :key="g.t" class="guarantee glass reveal" :data-reveal-delay="i * 80">
          <h4>{{ g.t }}</h4>
          <p>{{ g.d }}</p>
        </div>
      </div>
      <div class="pl-cta glass reveal">
        <h2>想开发自己的插件？</h2>
        <p>插件平台规范与 SDK 已就绪。</p>
        <RouterLink to="/docs/agent-runtime" class="btn btn-ghost">阅读开发文档</RouterLink>
      </div>
    </section>
  </div>
</template>

<style scoped>
.plugins-page { padding-top: var(--nav-h); }
.pl-hero { padding: 60px 0 20px; }
.pl-types { padding-top: 30px; }
.types-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
.type-card { padding: 30px 26px; height: 100%; }
.type-icon {
  width: 48px; height: 48px; border-radius: 13px;
  display: flex; align-items: center; justify-content: center;
  margin-bottom: 16px;
}
.type-en {
  font-family: var(--font-mono); font-size: 11px;
  text-transform: uppercase; letter-spacing: 0.1em; color: var(--text-faint);
}
.type-card h3 { font-size: 19px; margin: 4px 0 10px; }
.type-card p { font-size: 13.5px; color: var(--text-dim); }

.pl-market { padding-top: 90px; }
.market-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-top: 30px; }
.market-card { padding: 24px; transition: transform 0.3s, border-color 0.3s; }
.market-card:hover { transform: translateY(-4px); border-color: var(--border-strong); }
.market-top { display: flex; justify-content: space-between; align-items: center; }
.market-top h3 { font-size: 16px; }
.cat {
  font-size: 11px; font-family: var(--font-mono);
  padding: 2px 10px; border-radius: 999px;
  background: rgba(192, 132, 252, 0.14); color: var(--primary-soft);
}
.market-card p { font-size: 13px; color: var(--text-dim); margin: 10px 0 16px; }
.install-btn {
  width: 100%;
  padding: 9px;
  border-radius: 10px;
  border: 1px solid var(--border-strong);
  background: rgba(255, 255, 255, 0.04);
  color: var(--text);
  font-size: 13px;
  cursor: pointer;
  transition: background 0.2s, border-color 0.2s;
}
.install-btn:hover { background: rgba(192, 132, 252, 0.15); border-color: var(--primary); }

.pl-guarantees { padding-top: 90px; padding-bottom: 100px; }
.guarantees-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
.guarantee { padding: 22px; }
.guarantee h4 { font-size: 15px; margin-bottom: 8px; }
.guarantee p { font-size: 13px; color: var(--text-dim); }

.pl-cta {
  margin-top: 40px;
  text-align: center;
  padding: 54px 30px;
}
.pl-cta h2 { font-size: 25px; margin-bottom: 8px; }
.pl-cta p { color: var(--text-dim); margin-bottom: 22px; }

@media (max-width: 950px) {
  .types-grid, .market-grid { grid-template-columns: 1fr 1fr; }
  .guarantees-grid { grid-template-columns: 1fr 1fr; }
}
@media (max-width: 600px) {
  .types-grid, .market-grid, .guarantees-grid { grid-template-columns: 1fr; }
}
</style>
