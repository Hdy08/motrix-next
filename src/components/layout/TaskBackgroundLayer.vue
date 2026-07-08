<script setup lang="ts">
/** @fileoverview Stable task-list background layer kept outside route transitions. */
import { computed } from 'vue'
import { useTheme } from '@/composables/useTheme'
import { useLocalImageObjectUrl } from '@/composables/useLocalImageObjectUrl'
import { useTaskBackgroundConfig } from '@/composables/useTaskBackgroundConfig'
import watermarkDark from '@/assets/logo-bolt-dark.png'
import watermarkLight from '@/assets/logo-bolt-light.png'

const props = defineProps<{ show: boolean }>()

const { isDark } = useTheme()
const taskBackground = useTaskBackgroundConfig()
const watermarkSrc = computed(() => (isDark.value ? watermarkLight : watermarkDark))
const customBackgroundImageUrl = useLocalImageObjectUrl(taskBackground.backgroundImagePath)
const showCustomBackgroundImage = computed(() => props.show && customBackgroundImageUrl.value.length > 0)
const showDefaultBackgroundIcon = computed(() => props.show && taskBackground.showDefaultBackgroundIcon.value)
const showTaskBackground = computed(() => showCustomBackgroundImage.value || showDefaultBackgroundIcon.value)
const backgroundLayerStyle = computed(() => ({
  '--task-background-content-opacity': String(taskBackground.backgroundOpacity.value),
  '--task-background-default-icon-opacity': String(taskBackground.defaultIconOpacity.value),
}))
const customBackgroundImageStyle = computed(() => ({
  backgroundImage: customBackgroundImageUrl.value ? `url(${JSON.stringify(customBackgroundImageUrl.value)})` : 'none',
}))
</script>

<template>
  <div
    class="task-background-layer"
    :class="{ 'is-visible': show }"
    :style="backgroundLayerStyle"
    aria-hidden="true"
    @dragstart.prevent
    @selectstart.prevent
  >
    <Transition name="task-background-content">
      <div v-if="showTaskBackground" class="task-background-content">
        <div v-if="showCustomBackgroundImage" class="task-background-image" :style="customBackgroundImageStyle" />
        <img v-else :src="watermarkSrc" alt="" class="task-background-icon" draggable="false" />
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.task-background-layer {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  left: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(
    90deg,
    var(--aside-bg) 0 var(--aside-width),
    var(--subnav-bg) var(--aside-width)
      calc(var(--aside-width) + var(--task-background-subnav-width, var(--subnav-width))),
    var(--main-bg) calc(var(--aside-width) + var(--task-background-subnav-width, var(--subnav-width))) 100%
  );
  pointer-events: none;
  user-select: none;
  z-index: 0;
  opacity: 0;
  visibility: hidden;
  contain: layout paint;
}
.task-background-layer.is-visible {
  opacity: 1;
  visibility: visible;
}
.task-background-content {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
}
.task-background-icon {
  max-width: 480px;
  width: 80%;
  opacity: var(--task-background-default-icon-opacity);
  user-select: none;
  -webkit-user-drag: none;
}
.task-background-image {
  width: 100%;
  height: 100%;
  background-position: center;
  background-repeat: no-repeat;
  background-size: cover;
  opacity: var(--task-background-content-opacity);
}
.task-background-content-enter-active,
.task-background-content-leave-active {
  transition: opacity 0.28s cubic-bezier(0.2, 0, 0, 1);
}
.task-background-content-enter-from,
.task-background-content-leave-to {
  opacity: 0;
}
@media (max-width: 799px) {
  .task-background-layer {
    --task-background-subnav-width: var(--subnav-width-compact);
  }
}
@media (max-width: 600px) {
  .task-background-layer {
    --task-background-subnav-width: 0px;
  }
}
</style>
