import { beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'

const state = vi.hoisted(() => ({
  preferenceStore: {
    config: {
      taskListWatermark: true,
      backgroundImagePath: '',
      backgroundOpacity: 35,
    },
  },
  isDark: { value: false },
  imageUrl: { value: '' },
}))

vi.mock('@/stores/preference', () => ({
  usePreferenceStore: () => state.preferenceStore,
}))

vi.mock('@/composables/useTheme', () => ({
  useTheme: () => ({ isDark: state.isDark }),
}))

vi.mock('@/composables/useLocalImageObjectUrl', () => ({
  useLocalImageObjectUrl: () => state.imageUrl,
}))

import TaskBackgroundLayer from '../TaskBackgroundLayer.vue'

describe('TaskBackgroundLayer', () => {
  beforeEach(() => {
    state.preferenceStore.config.taskListWatermark = true
    state.preferenceStore.config.backgroundImagePath = ''
    state.preferenceStore.config.backgroundOpacity = 35
    state.isDark.value = false
    state.imageUrl.value = ''
  })

  it('shows the default background icon on task pages', () => {
    const wrapper = mount(TaskBackgroundLayer, { props: { show: true } })

    expect(wrapper.find('.task-background-layer').classes()).toContain('is-visible')
    expect(wrapper.find('.task-background-icon').exists()).toBe(true)
  })

  it('keeps the layer mounted but hidden off task pages', () => {
    const wrapper = mount(TaskBackgroundLayer, { props: { show: false } })

    expect(wrapper.find('.task-background-layer').exists()).toBe(true)
    expect(wrapper.find('.task-background-layer').classes()).not.toContain('is-visible')
  })

  it('renders a custom background image ahead of the default icon', () => {
    state.preferenceStore.config.backgroundImagePath = 'C:\\Users\\me\\Pictures\\background.png'
    state.imageUrl.value = 'blob:background'

    const wrapper = mount(TaskBackgroundLayer, { props: { show: true } })

    expect(wrapper.find('.task-background-image').attributes('style')).toContain('blob:background')
    expect(wrapper.find('.task-background-icon').exists()).toBe(false)
  })

  it('applies configured background opacity only to custom background content', () => {
    state.preferenceStore.config.backgroundOpacity = 75

    const wrapper = mount(TaskBackgroundLayer, { props: { show: true } })

    const layerStyle = wrapper.find('.task-background-layer').attributes('style')
    expect(layerStyle).toContain('--task-background-content-opacity: 0.75')
    expect(layerStyle).toContain('--task-background-default-icon-opacity: 0.35')
  })

  it('keeps the full-window background base visible immediately on task pages', () => {
    const wrapper = mount(TaskBackgroundLayer, { props: { show: true } })

    expect(wrapper.find('.task-background-layer').classes()).toContain('is-visible')
    expect(wrapper.find('.task-background-layer').attributes('style')).not.toContain('--task-background-left-inset')
  })
})
