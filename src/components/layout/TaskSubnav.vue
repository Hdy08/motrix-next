<script setup lang="ts">
/** @fileoverview Task status sub-navigation tabs (active, waiting, stopped). */
import { computed, onBeforeUnmount, onMounted, ref, watch, type Component } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRouter, useRoute } from 'vue-router'
import { PlayOutline, CheckmarkDoneOutline, ListOutline } from '@vicons/ionicons5'
import SubnavPane, { type SubnavPaneItem } from '@/components/layout/SubnavPane.vue'
import { fetchTaskList, isEngineReady } from '@/api/aria2'
import { useAppStore } from '@/stores/app'
import { useHistoryStore } from '@/stores/history'
import { usePreferenceStore } from '@/stores/preference'
import { DEFAULT_APP_CONFIG } from '@shared/constants'
import { logger } from '@shared/logger'
import { checkTaskIsEd2kSearch } from '@shared/utils'
import { opacityPercentToCssPercent } from '@shared/utils/opacity'

const { t } = useI18n()
const router = useRouter()
const route = useRoute()
const appStore = useAppStore()
const historyStore = useHistoryStore()
const preferenceStore = usePreferenceStore()
const liveTaskCount = ref(0)
const historyOverlapCount = ref(0)
let countRequestId = 0
let mounted = false

const items: { key: string; icon: Component; route: string }[] = [
  { key: 'all', icon: ListOutline, route: '/task/all' },
  { key: 'active', icon: PlayOutline, route: '/task/active' },
  { key: 'stopped', icon: CheckmarkDoneOutline, route: '/task/stopped' },
]

const subnavItems = computed<SubnavPaneItem[]>(() =>
  items.map((item) => {
    const label = t('task.' + item.key) || item.key
    const count = preferenceStore.config.sidebarTaskCounts ? taskCount(item.key) : undefined
    return {
      ...item,
      label,
      count,
      ariaLabel: count === undefined ? label : `${label} ${count}`,
      active: isActive(item.key),
    }
  }),
)

const activeTaskCount = computed(() => liveTaskCount.value)
const finishedTaskCount = computed(() => historyStore.recordTotal)
const uniqueTaskCount = computed(() => {
  const overlap = Math.min(historyOverlapCount.value, activeTaskCount.value, finishedTaskCount.value)
  return activeTaskCount.value + finishedTaskCount.value - overlap
})
const activeBackgroundOpacity = computed(() =>
  opacityPercentToCssPercent(
    preferenceStore.config.taskListSelectedBackgroundOpacity,
    DEFAULT_APP_CONFIG.taskListSelectedBackgroundOpacity,
  ),
)

onMounted(async () => {
  mounted = true
  await historyStore.refreshRecordTotal()
  await refreshTaskCounts()
})

onBeforeUnmount(() => {
  mounted = false
  countRequestId += 1
})

function taskCount(key: string): number {
  if (key === 'active') return activeTaskCount.value
  if (key === 'stopped') return finishedTaskCount.value
  return uniqueTaskCount.value
}

async function refreshTaskCounts(): Promise<void> {
  const requestId = ++countRequestId
  liveTaskCount.value = appStore.stat.numActive + appStore.stat.numWaiting
  if (!preferenceStore.config.sidebarTaskCounts) {
    historyOverlapCount.value = 0
    return
  }
  if (!isEngineReady()) {
    historyOverlapCount.value = 0
    return
  }

  try {
    const liveTasks = (await fetchTaskList({ type: 'active' })).filter((task) => !checkTaskIsEd2kSearch(task))
    const overlap = await historyStore.countRecordsMatchingTaskIdentities(liveTasks)
    if (!mounted || requestId !== countRequestId) return
    liveTaskCount.value = liveTasks.length
    historyOverlapCount.value = overlap
  } catch (e) {
    if (!mounted || requestId !== countRequestId) return
    historyOverlapCount.value = 0
    logger.debug('TaskSubnav.refreshCounts', e instanceof Error ? e.message : String(e))
  }
}

watch(
  () => [
    preferenceStore.config.sidebarTaskCounts,
    appStore.stat.numActive,
    appStore.stat.numWaiting,
    historyStore.recordTotal,
  ],
  () => {
    if (mounted) void refreshTaskCounts()
  },
)

function nav(path: string) {
  router.push({ path }).catch(() => {
    /* duplicate navigation */
  })
}

function isActive(key: string) {
  return route.path.includes(key)
}
</script>

<template>
  <SubnavPane
    :title="t('subnav.task-list') || 'Tasks'"
    :items="subnavItems"
    :active-background-opacity="activeBackgroundOpacity"
    @navigate="nav"
  />
</template>
