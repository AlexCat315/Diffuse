<script setup lang="ts">
/**
 * ParticleField — drifting light points that softly connect to nearby
 * neighbours (a "diffuse" network). The pointer acts as a moving light
 * source: particles within its radius brighten and drift away.
 * Pure Canvas 2D, DPR-aware, pauses on hidden tabs.
 */
import { onBeforeUnmount, onMounted, ref } from 'vue'

const canvas = ref<HTMLCanvasElement | null>(null)
let ctx: CanvasRenderingContext2D | null = null
let raf = 0
let width = 0
let height = 0

const pointer = { x: -9999, y: -9999, active: false }

interface P {
  x: number
  y: number
  vx: number
  vy: number
  r: number
  hue: number
}
let points: P[] = []

const LINK_DIST = 120
const LIGHT_RADIUS = 190

function resize() {
  if (!canvas.value) return
  const dpr = Math.min(window.devicePixelRatio || 1, 2)
  width = window.innerWidth
  height = window.innerHeight
  canvas.value.width = width * dpr
  canvas.value.height = height * dpr
  canvas.value.style.width = `${width}px`
  canvas.value.style.height = `${height}px`
  ctx?.setTransform(dpr, 0, 0, dpr, 0, 0)

  const count = Math.min(110, Math.floor((width * height) / 16000))
  points = Array.from({ length: count }, () => ({
    x: Math.random() * width,
    y: Math.random() * height,
    vx: (Math.random() - 0.5) * 0.35,
    vy: (Math.random() - 0.5) * 0.35,
    r: Math.random() * 1.8 + 0.7,
    hue: 265 + Math.random() * 45, // violet → pink
  }))
}

function frame() {
  if (!ctx) return
  ctx.clearRect(0, 0, width, height)

  // pointer light wash
  if (pointer.active) {
    const g = ctx.createRadialGradient(pointer.x, pointer.y, 0, pointer.x, pointer.y, LIGHT_RADIUS)
    g.addColorStop(0, 'rgba(244, 114, 182, 0.12)')
    g.addColorStop(1, 'rgba(244, 114, 182, 0)')
    ctx.fillStyle = g
    ctx.fillRect(0, 0, width, height)
  }

  for (const p of points) {
    // pointer repulsion + light
    let lit = 0
    if (pointer.active) {
      const dx = p.x - pointer.x
      const dy = p.y - pointer.y
      const d = Math.hypot(dx, dy)
      if (d < LIGHT_RADIUS) {
        lit = 1 - d / LIGHT_RADIUS
        const f = (lit * 0.9) / (d || 1)
        p.vx += dx * f * 0.06
        p.vy += dy * f * 0.06
      }
    }

    p.x += p.vx
    p.y += p.vy
    // friction + gentle wander
    p.vx *= 0.985
    p.vy *= 0.985
    p.vx += (Math.random() - 0.5) * 0.015
    p.vy += (Math.random() - 0.5) * 0.015

    if (p.x < -20) p.x = width + 20
    if (p.x > width + 20) p.x = -20
    if (p.y < -20) p.y = height + 20
    if (p.y > height + 20) p.y = -20

    const alpha = 0.45 + lit * 0.55
    const radius = p.r + lit * 1.6
    ctx.beginPath()
    ctx.arc(p.x, p.y, radius, 0, Math.PI * 2)
    ctx.fillStyle = `hsla(${p.hue}, 90%, ${72 + lit * 20}%, ${alpha})`
    ctx.fill()
  }

  // links
  for (let i = 0; i < points.length; i++) {
    for (let j = i + 1; j < points.length; j++) {
      const a = points[i]
      const b = points[j]
      const d = Math.hypot(a.x - b.x, a.y - b.y)
      if (d < LINK_DIST) {
        const alpha = (1 - d / LINK_DIST) * 0.22
        ctx.beginPath()
        ctx.moveTo(a.x, a.y)
        ctx.lineTo(b.x, b.y)
        ctx.strokeStyle = `rgba(216, 180, 254, ${alpha})`
        ctx.lineWidth = 1
        ctx.stroke()
      }
    }
  }

  raf = requestAnimationFrame(frame)
}

function onPointer(e: PointerEvent) {
  pointer.x = e.clientX
  pointer.y = e.clientY
  pointer.active = true
}
function onLeave() {
  pointer.active = false
  pointer.x = -9999
  pointer.y = -9999
}
function onVisibility() {
  if (document.hidden) cancelAnimationFrame(raf)
  else raf = requestAnimationFrame(frame)
}

onMounted(() => {
  if (!canvas.value) return
  ctx = canvas.value.getContext('2d')
  resize()
  window.addEventListener('resize', resize)
  window.addEventListener('pointermove', onPointer)
  window.addEventListener('pointerleave', onLeave)
  document.addEventListener('visibilitychange', onVisibility)
  raf = requestAnimationFrame(frame)
})

onBeforeUnmount(() => {
  cancelAnimationFrame(raf)
  window.removeEventListener('resize', resize)
  window.removeEventListener('pointermove', onPointer)
  window.removeEventListener('pointerleave', onLeave)
  document.removeEventListener('visibilitychange', onVisibility)
})
</script>

<template>
  <canvas ref="canvas" class="particle-field" aria-hidden="true"></canvas>
</template>

<style scoped>
.particle-field {
  position: fixed;
  inset: 0;
  z-index: 0;
  pointer-events: none;
}
</style>
