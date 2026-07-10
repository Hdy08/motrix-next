<script setup lang="ts">
import { computed } from 'vue'
import { NInputNumber, NSlider, NText } from 'naive-ui'
import { OPACITY_PERCENT_MAX, OPACITY_PERCENT_MIN } from '@shared/constants'
import { normalizeOpacityPercent } from '@shared/utils/opacity'

const props = withDefaults(
  defineProps<{
    modelValue: number
    min?: number
    max?: number
  }>(),
  {
    min: OPACITY_PERCENT_MIN,
    max: OPACITY_PERCENT_MAX,
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: number]
}>()

const value = computed({
  get: () => props.modelValue,
  set: (nextValue: number | null) => {
    const currentValue = normalizeOpacityPercent(props.modelValue, props.min, props.min, props.max)
    emit('update:modelValue', normalizeOpacityPercent(nextValue, currentValue, props.min, props.max))
  },
})
</script>

<template>
  <div class="opacity-control">
    <NSlider v-model:value="value" :min="min" :max="max" :step="1" class="opacity-slider" />
    <NInputNumber
      v-model:value="value"
      :min="min"
      :max="max"
      :step="1"
      :precision="0"
      :show-button="false"
      class="opacity-input"
    />
    <NText depth="3" class="opacity-unit">%</NText>
  </div>
</template>

<style scoped>
.opacity-control {
  display: flex;
  align-items: center;
  gap: 12px;
  width: min(420px, 100%);
  min-width: 0;
}
.opacity-slider {
  flex: 1 1 220px;
  min-width: 160px;
}
.opacity-input {
  flex: 0 0 72px;
  width: 72px;
}
.opacity-unit {
  flex: 0 0 auto;
}
</style>
