<script setup lang="ts">
import { Box, ChevronDown, ChevronRight, Circle, Eye, Lightbulb, LockKeyhole, MousePointer2, Play, Rotate3D, Sparkles } from '@lucide/vue'
import { useLocale } from '@/composables/useLocale'

const { t } = useLocale()
</script>

<template>
  <figure class="editor-concept">
    <figcaption><span></span>{{ t.home.conceptLabel }}</figcaption>
    <div class="concept-window">
      <div class="concept-topbar">
        <div class="traffic"><i></i><i></i><i></i></div>
        <b>Guava Editor</b>
        <div class="concept-tools"><MousePointer2 :size="13" /><Rotate3D :size="13" /><button><Play :size="11" /> Run</button></div>
      </div>
      <div class="concept-body">
        <aside class="concept-hierarchy">
          <h4>WORLD <span>+</span></h4>
          <p><ChevronDown :size="12" /><Box :size="12" /> Orchard</p>
          <p class="indent active"><ChevronRight :size="12" /><Box :size="12" /> Player <Eye :size="11" /></p>
          <p class="indent"><ChevronRight :size="12" /><Lightbulb :size="12" /> Sun Light</p>
          <p class="indent"><ChevronRight :size="12" /><Box :size="12" /> Environment <LockKeyhole :size="10" /></p>
        </aside>
        <div class="concept-viewport">
          <div class="viewport-label"><Circle :size="7" fill="currentColor" /> PERSPECTIVE</div>
          <div class="horizon"></div><div class="ground-grid"></div>
          <div class="scene-object object-one"><i></i><i></i><i></i></div>
          <div class="scene-object object-two"><i></i><i></i><i></i></div>
          <div class="gizmo"><b>X</b><b>Y</b><b>Z</b></div>
          <div class="intent-prompt"><Sparkles :size="14" /><span>Make the orchard feel alive at sunset…</span><kbd>⌘↵</kbd></div>
        </div>
        <aside class="concept-inspector">
          <h4>INSPECTOR</h4><strong>Player</strong><small>Entity · 7 components</small>
          <div class="property"><span>Position</span><div><i>X</i> 0.0</div><div><i>Y</i> 1.2</div><div><i>Z</i> -2.4</div></div>
          <div class="property"><span>Character</span><p>Speed <b>6.0</b></p><p>Jump <b>4.5</b></p></div>
          <div class="semantic-chip"><Sparkles :size="11" /> playable.character</div>
        </aside>
      </div>
      <div class="concept-status"><span><i></i> World synchronized</span><span>60 FPS · WebGPU</span></div>
    </div>
  </figure>
</template>
