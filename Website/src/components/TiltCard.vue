<script setup lang="ts">
/**
 * TiltCard — a wrapper that tilts in 3D toward the pointer and
 * exposes a moving highlight. Resets on pointer leave.
 */
import { onBeforeUnmount, ref } from 'vue'

const el = ref<HTMLElement | null>(null)
const rx = ref(0)
const ry = ref(0)
const gx = ref(50)
const gy = ref(50)

function onMove(e: PointerEvent) {
  const node = el.value
  if (!node) return
  const rect = node.getBoundingClientRect()
  const px = (e.clientX - rect.left) / rect.width
  const py = (e.clientY - rect.top) / rect.height
  ry.value = (px - 0.5) * 14
  rx.value = (0.5 - py) * 14
  gx.value = px * 100
  gy.value = py * 100
}

function reset() {
  rx.value = 0
  ry.value = 0
}

onBeforeUnmount(() => reset())
</script>

<template>
  <div
    ref="el"
    class="tilt-card"
    :style="{
      transform: `perspective(900px) rotateX(${rx}deg) rotateY(${ry}deg)`,
      '--gx': `${gx}%`,
      '--gy': `${gy}%`,
    }"
    @pointermove="onMove"
    @pointerleave="reset"
  >
    <div class="tilt-glow"></div>
    <slot />
  </div>
</template>

<style scoped>
.tilt-card {
  position: relative;
  transition: transform 0.2s ease-out;
  transform-style: preserve-3d;
  border-radius: var(--radius-lg);
}
.tilt-glow {
  position: absolute;
  inset: 0;
  border-radius: inherit;
  pointer-events: none;
  background: radial-gradient(
    380px circle at var(--gx) var(--gy),
    rgba(244, 114, 182, 0.14),
    transparent 55%
  );
  opacity: 0;
  transition: opacity 0.3s;
}
.tilt-card:hover .tilt-glow {
  opacity: 1;
}
</style>
