import { computed } from 'vue'
import { usePreferenceStore } from '@/stores/preference'
import { BACKGROUND_OPACITY_MAX, BACKGROUND_OPACITY_MIN, DEFAULT_APP_CONFIG } from '@shared/constants'

export function useTaskBackgroundConfig() {
  const preferenceStore = usePreferenceStore()
  const backgroundImagePath = computed(() => (preferenceStore.config.backgroundImagePath ?? '').trim())
  const hasCustomBackgroundImagePath = computed(() => backgroundImagePath.value.length > 0)
  const showDefaultBackgroundIcon = computed(
    () => preferenceStore.config.taskListWatermark && !hasCustomBackgroundImagePath.value,
  )
  const isTaskBackgroundConfigured = computed(
    () => hasCustomBackgroundImagePath.value || showDefaultBackgroundIcon.value,
  )
  const backgroundOpacity = computed(() => {
    const opacity = Number(preferenceStore.config.backgroundOpacity)
    const percent = Number.isFinite(opacity) ? opacity : DEFAULT_APP_CONFIG.backgroundOpacity
    return Math.min(BACKGROUND_OPACITY_MAX, Math.max(BACKGROUND_OPACITY_MIN, percent)) / 100
  })
  const defaultIconOpacity = computed(() => DEFAULT_APP_CONFIG.backgroundOpacity / 100)

  return {
    backgroundImagePath,
    backgroundOpacity,
    defaultIconOpacity,
    hasCustomBackgroundImagePath,
    isTaskBackgroundConfigured,
    showDefaultBackgroundIcon,
  }
}
