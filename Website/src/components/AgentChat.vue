<script setup lang="ts">
/**
 * AgentChat — scripted conversation that demonstrates an AI agent
 * planning and calling Diffuse tools. Lines type out sequentially;
 * tool calls appear as animated chips. Loops forever.
 */
import { onBeforeUnmount, onMounted, ref } from 'vue'

interface ToolCall {
  tool: string
  args: string
}
interface Line {
  role: 'user' | 'agent'
  text?: string
  tools?: ToolCall[]
}

const script: Line[] = [
  {
    role: 'user',
    text: '帮我做一个「推箱子」的关卡：玩家、三个箱子、三个目标点，靠墙围起来。',
  },
  {
    role: 'agent',
    text: '好的，我来规划关卡：先建地面和围墙，再放置玩家、箱子与目标点，最后为所有物体挂上碰撞体。',
  },
  {
    role: 'agent',
    tools: [
      { tool: 'scene.create', args: 'level_sokoban' },
      { tool: 'scene.addWall', args: '12 × 1 · 四周' },
      { tool: 'scene.addPlayer', args: 'transform(1, 1)' },
      { tool: 'scene.addBox', args: '×3' },
      { tool: 'scene.addGoal', args: '×3' },
      { tool: 'physics.addCollider', args: 'all bodies' },
    ],
  },
  {
    role: 'agent',
    text: '关卡已生成，碰撞与推箱逻辑都已就绪。你可以直接在编辑器里试玩，或让我继续加移动步数统计。',
  },
]

const visibleLines = ref(0)
const typedText = ref('')
const visibleTools = ref(0)
let timers: number[] = []

function wait(ms: number) {
  return new Promise<void>((resolve) => {
    const id = window.setTimeout(resolve, ms)
    timers.push(id)
  })
}

async function typeText(text: string) {
  typedText.value = ''
  for (const ch of text) {
    typedText.value += ch
    await wait(22)
  }
}

async function play() {
  for (let i = 0; i < script.length; i++) {
    visibleLines.value = i + 1
    const line = script[i]
    if (line.text) {
      typedText.value = ''
      await typeText(line.text)
      await wait(500)
    }
    if (line.tools) {
      visibleTools.value = 0
      for (let t = 0; t < line.tools.length; t++) {
        visibleTools.value = t + 1
        await wait(420)
      }
      await wait(500)
    }
  }
  await wait(4200)
  // reset and loop
  visibleLines.value = 0
  visibleTools.value = 0
  typedText.value = ''
  await wait(400)
  play()
}

onMounted(play)
onBeforeUnmount(() => timers.forEach(clearTimeout))
</script>

<template>
  <div class="agent-chat">
    <div class="chat-head">
      <span class="chat-status"><span class="status-dot"></span>Diffuse Agent</span>
      <span class="chat-model">guava-agent · 本地</span>
    </div>

    <div class="chat-body">
      <template v-for="(line, i) in script" :key="i">
        <div v-if="visibleLines > i" class="chat-line" :class="line.role">
          <div v-if="line.role === 'user'" class="bubble user-bubble">{{ line.text }}</div>

          <template v-else>
            <div class="agent-row">
              <div class="agent-avatar">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M12 2v4M12 18v4M2 12h4M18 12h4M5 5l3 3M16 16l3 3M19 5l-3 3M8 16l-3 3" stroke-linecap="round" />
                  <circle cx="12" cy="12" r="3" />
                </svg>
              </div>
              <div v-if="line.text" class="bubble agent-bubble">
                <span v-if="visibleLines === i + 1 && !line.tools">{{ typedText }}</span>
                <template v-else>{{ line.text }}</template>
              </div>
            </div>

            <div v-if="line.tools" class="tool-list">
              <div v-for="(tool, ti) in line.tools" :key="ti" v-show="visibleTools > ti" class="tool-chip">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2">
                  <path d="M20 6 9 17l-5-5" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
                <span class="tool-name">{{ tool.tool }}</span>
                <span class="tool-args">{{ tool.args }}</span>
              </div>
            </div>
          </template>
        </div>
      </template>

      <div class="typing-indicator" v-if="visibleLines < script.length">
        <span></span><span></span><span></span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.agent-chat {
  border-radius: var(--radius-lg);
  border: 1px solid var(--border);
  background: rgba(16, 10, 30, 0.82);
  backdrop-filter: blur(20px);
  overflow: hidden;
  box-shadow: 0 30px 80px -30px rgba(124, 58, 237, 0.5);
}

.chat-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 13px 20px;
  border-bottom: 1px solid var(--border);
  background: rgba(38, 25, 66, 0.5);
}
.chat-status {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13.5px;
  font-weight: 600;
}
.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #4ade80;
  box-shadow: 0 0 8px #4ade80;
}
.chat-model {
  font-family: var(--font-mono);
  font-size: 11px;
  color: var(--text-faint);
}

.chat-body {
  padding: 22px;
  display: flex;
  flex-direction: column;
  gap: 16px;
  min-height: 380px;
}

.agent-row {
  display: flex;
  gap: 10px;
  align-items: flex-start;
}
.agent-avatar {
  width: 28px;
  height: 28px;
  border-radius: 9px;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--gradient);
  color: #1e0b33;
}

.bubble {
  padding: 11px 16px;
  border-radius: 14px;
  font-size: 14px;
  line-height: 1.65;
}
.user-bubble {
  background: linear-gradient(120deg, rgba(192, 132, 252, 0.25), rgba(244, 114, 182, 0.2));
  border: 1px solid var(--border);
  margin-left: auto;
  max-width: 88%;
}
.agent-bubble {
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--border);
  border-top-left-radius: 4px;
}

.tool-list {
  display: flex;
  flex-direction: column;
  gap: 7px;
  margin: 4px 0 4px 38px;
}
.tool-chip {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 13px;
  border-radius: 10px;
  border: 1px solid rgba(74, 222, 128, 0.25);
  background: rgba(74, 222, 128, 0.07);
  font-family: var(--font-mono);
  font-size: 12px;
  animation: toolIn 0.4s ease;
}
@keyframes toolIn {
  from { opacity: 0; transform: translateX(-10px); }
}
.tool-chip svg {
  color: #4ade80;
}
.tool-name {
  color: #86efac;
  font-weight: 600;
}
.tool-args {
  color: var(--text-faint);
}

.typing-indicator {
  display: flex;
  gap: 5px;
  padding: 6px 0 6px 38px;
}
.typing-indicator span {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--text-faint);
  animation: typing 1.2s infinite;
}
.typing-indicator span:nth-child(2) { animation-delay: 0.2s; }
.typing-indicator span:nth-child(3) { animation-delay: 0.4s; }
@keyframes typing {
  0%, 60%, 100% { opacity: 0.3; transform: translateY(0); }
  30% { opacity: 1; transform: translateY(-4px); }
}
</style>
