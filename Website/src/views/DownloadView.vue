<script setup lang="ts">
import { ref } from 'vue'
import { RouterLink } from 'vue-router'

const active = ref<'mac' | 'windows' | 'linux'>('mac')

const buildCmds: Record<string, string> = {
  mac: `git clone https://github.com/AlexCat315/Diffuse.git
cd Diffuse
git submodule update --init --recursive
./cove studio native-bootstrap
./cove build Editor --mac
./cove run Editor`,
  windows: `git clone https://github.com/AlexCat315/Diffuse.git
cd Diffuse
git submodule update --init --recursive
cove studio native-bootstrap
cove build Editor --win
cove run Editor`,
  linux: `git clone https://github.com/AlexCat315/Diffuse.git
cd Diffuse
git submodule update --init --recursive
./cove studio native-bootstrap
./cove build Editor --linux
./cove run Editor`,
}

const copied = ref(false)
async function copyCmd() {
  await navigator.clipboard.writeText(buildCmds[active.value])
  copied.value = true
  setTimeout(() => (copied.value = false), 1600)
}

const prereqs = [
  { name: 'Swift', version: '6.4.1' },
  { name: 'CMake', version: '4.4.4' },
  { name: '编译器', version: 'Xcode 27 / VS 2026 / GCC' },
  { name: 'Git', version: '最新稳定版' },
]

const deps = [
  { name: 'Yoga', version: '3.2.1' },
  { name: 'FreeType / HarfBuzz', version: '随 SDK' },
  { name: 'SDL3', version: '随 SDK' },
  { name: 'OpenEXR / Imath', version: 'submodule' },
  { name: 'Wasmtime', version: '49.0.2' },
  { name: 'FFmpeg', version: '8.1.3' },
]
</script>

<template>
  <div class="dl-page">
    <section class="dl-hero">
      <div class="container">
        <span class="eyebrow reveal">下载</span>
        <h1 class="reveal" style="font-size: clamp(32px, 4.5vw, 50px)">获取 Diffuse 工作站</h1>
        <p class="reveal" style="color: var(--text-dim); max-width: 660px; font-size: 17px">
          Diffuse 从源码构建。先安装 <a href="https://github.com/AlexCat315/Cove" target="_blank" rel="noopener" style="color: var(--primary-soft)">Cove SDK</a>，
          然后按下面的步骤构建 Editor。
        </p>
      </div>
    </section>

    <section class="container dl-body">
      <div class="prereq-grid reveal">
        <div v-for="p in prereqs" :key="p.name" class="prereq glass">
          <strong>{{ p.name }}</strong>
          <span>{{ p.version }}</span>
        </div>
      </div>

      <div class="platform-switch reveal">
        <button
          v-for="p in (['mac', 'windows', 'linux'] as const)"
          :key="p"
          class="switch-btn"
          :class="{ active: active === p }"
          @click="active = p"
        >
          {{ p === 'mac' ? 'macOS' : p === 'windows' ? 'Windows' : 'Linux' }}
        </button>
      </div>

      <div class="cmd-card glass reveal">
        <div class="cmd-head">
          <span>构建命令</span>
          <button class="copy-btn" @click="copyCmd">{{ copied ? '已复制 ✓' : '复制全部' }}</button>
        </div>
        <pre class="cmd-body">{{ buildCmds[active] }}</pre>
      </div>

      <div class="deps-card glass reveal">
        <h3>第三方依赖</h3>
        <div class="deps-grid">
          <div v-for="d in deps" :key="d.name" class="dep-row">
            <span>{{ d.name }}</span>
            <code>{{ d.version }}</code>
          </div>
        </div>
        <RouterLink to="/docs/build" class="more-link">查看完整构建指南 →</RouterLink>
      </div>
    </section>
  </div>
</template>

<style scoped>
.dl-page { padding-top: var(--nav-h); }
.dl-hero { padding: 60px 0 20px; }
.dl-body { padding-bottom: 100px; }

.prereq-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 14px;
  margin: 30px 0 22px;
}
.prereq {
  padding: 20px;
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.prereq strong { font-size: 15px; }
.prereq span { font-size: 13px; color: var(--text-dim); font-family: var(--font-mono); }

.platform-switch { display: flex; gap: 10px; margin-bottom: 18px; }
.switch-btn {
  padding: 11px 26px;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--text-dim);
  font-size: 14px;
  cursor: pointer;
}
.switch-btn.active {
  border-color: var(--primary);
  background: rgba(192, 132, 252, 0.14);
  color: var(--primary-soft);
}

.cmd-card { overflow: hidden; margin-bottom: 26px; }
.cmd-head {
  display: flex;
  justify-content: space-between;
  padding: 12px 20px;
  border-bottom: 1px solid var(--border);
  background: rgba(38, 25, 66, 0.5);
  font-size: 13px;
  color: var(--text-faint);
}
.copy-btn {
  background: none; border: none;
  color: var(--text-dim); font-size: 13px; cursor: pointer;
}
.copy-btn:hover { color: var(--primary-soft); }
.cmd-body {
  padding: 24px 28px;
  font-family: var(--font-mono);
  font-size: 13.5px;
  line-height: 1.85;
  color: #ecdffa;
}

.deps-card { padding: 30px 34px; }
.deps-card h3 { margin-bottom: 16px; font-size: 18px; }
.deps-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.dep-row {
  display: flex;
  justify-content: space-between;
  padding: 10px 16px;
  border: 1px solid var(--border);
  border-radius: 10px;
  font-size: 14px;
}
.dep-row code { font-size: 12.5px; color: var(--primary-soft); }
.more-link { display: inline-block; margin-top: 18px; color: var(--primary-soft); font-size: 14px; }

@media (max-width: 800px) {
  .prereq-grid { grid-template-columns: 1fr 1fr; }
  .deps-grid { grid-template-columns: 1fr; }
}
@media (max-width: 500px) {
  .prereq-grid { grid-template-columns: 1fr; }
}
</style>
