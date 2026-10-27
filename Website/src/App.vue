<script setup lang="ts">
import { RouterView } from 'vue-router'
import TheNav from '@/components/TheNav.vue'
import TheFooter from '@/components/TheFooter.vue'
import { revealDirective } from '@/directives/reveal'

const vReveal = revealDirective
</script>

<template>
  <TheNav />
  <main>
    <RouterView v-slot="{ Component }">
      <transition name="page" mode="out-in">
        <component :is="Component" v-reveal />
      </transition>
    </RouterView>
  </main>
  <TheFooter />
</template>
