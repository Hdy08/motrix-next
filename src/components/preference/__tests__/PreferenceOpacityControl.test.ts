import { describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

vi.mock('naive-ui', async () => {
  const { defineComponent, h } = await import('vue')
  const control = (name: string) =>
    defineComponent({
      name,
      props: { value: { type: Number, default: null } },
      emits: ['update:value'],
      setup() {
        return () => h('div')
      },
    })

  return {
    NInputNumber: control('NInputNumber'),
    NSlider: control('NSlider'),
    NText: defineComponent({
      name: 'NText',
      setup(_, { slots }) {
        return () => h('span', slots.default?.())
      },
    }),
  }
})

import PreferenceOpacityControl from '../PreferenceOpacityControl.vue'

describe('PreferenceOpacityControl', () => {
  it('preserves the current value when the numeric input is cleared', async () => {
    const wrapper = mount(PreferenceOpacityControl, { props: { modelValue: 75 } })

    wrapper.findComponent({ name: 'NInputNumber' }).vm.$emit('update:value', null)
    await nextTick()

    expect(wrapper.emitted('update:modelValue')).toEqual([[75]])
  })

  it('clamps emitted values to the configured range', async () => {
    const wrapper = mount(PreferenceOpacityControl, {
      props: { modelValue: 75, min: 10, max: 90 },
    })

    wrapper.findComponent({ name: 'NSlider' }).vm.$emit('update:value', 100)
    await nextTick()

    expect(wrapper.emitted('update:modelValue')).toEqual([[90]])
  })
})
