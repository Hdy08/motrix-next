/**
 * @fileoverview Extracted notification handlers for task lifecycle events.
 *
 * These handlers are registered by MainLayout as callbacks on the lifecycle
 * service. Extracted here as pure functions for independent unit testing —
 * following the same pattern as useTaskLifecycle.ts.
 *
 * **Notification architecture:**
 * - In-app toast (Naive UI message) — always fires for immediate feedback.
 * - OS-level completion/error notification is sent by Rust's task monitor so
 *   lightweight mode works after the WebView is destroyed.
 *
 * When `onOpenFile` / `onShowInFolder` callbacks are provided in deps,
 * the in-app toast renders inline action buttons so the user can open
 * the downloaded file or reveal it in the system file manager directly
 * from the notification — without navigating through the task list.
 */
import type { VNodeChild } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import type { Aria2Task, TaskStartNotificationTask } from '@shared/types'
import { getTaskDisplayName } from '@shared/utils'
import type { TaskSharingKind } from '@shared/utils/task'
import { logger } from '@shared/logger'
import { isMetadataTask } from '@/composables/useTaskLifecycle'
import { renderCompletionToast } from '@/composables/useNotificationToast'

/** Dependency interface for testability. */
export interface NotifyDeps {
  messageSuccess: (content: string | (() => VNodeChild)) => void
  messageError: (content: string) => void
  t: (key: string, params?: Record<string, unknown>) => string
  /** Optional: open the downloaded file with the default application. */
  onOpenFile?: (task: Aria2Task) => void
  /** Optional: reveal the downloaded file in the system file manager. */
  onShowInFolder?: (task: Aria2Task) => void
}

/**
 * Handle a completed HTTP/FTP download.
 * Always sends in-app toast. Native OS notification is sent by Rust monitor.
 *
 * When action callbacks are provided, the toast includes inline buttons
 * for "Open File" and "Show in Folder".
 */
export function handleTaskComplete(task: Aria2Task, deps: NotifyDeps): void {
  if (isMetadataTask(task)) return

  const taskName = getTaskDisplayName(task)
  const body = deps.t('task.download-complete-message', { taskName })

  const toastContent = renderCompletionToast({
    body,
    t: deps.t,
    onOpenFile: deps.onOpenFile ? () => deps.onOpenFile!(task) : undefined,
    onShowInFolder: deps.onShowInFolder ? () => deps.onShowInFolder!(task) : undefined,
  })
  deps.messageSuccess(toastContent)
  logger.info('TaskNotify.complete', `gid=${task.gid} name="${taskName}"`)
}

/**
 * Handle a P2P download entering shared-upload state.
 * Always sends in-app toast. Native OS notification is sent by Rust monitor.
 *
 * When action callbacks are provided, the toast includes inline buttons
 * for "Open File" and "Show in Folder".
 */
export function handleSharingComplete(task: Aria2Task, kind: TaskSharingKind, deps: NotifyDeps): void {
  const taskName = getTaskDisplayName(task)
  const bodyKey = kind === 'bt' ? 'task.bt-download-complete-message' : 'task.ed2k-download-complete-message'
  const body = deps.t(bodyKey, { taskName })

  const toastContent = renderCompletionToast({
    body,
    t: deps.t,
    onOpenFile: deps.onOpenFile ? () => deps.onOpenFile!(task) : undefined,
    onShowInFolder: deps.onShowInFolder ? () => deps.onShowInFolder!(task) : undefined,
  })
  deps.messageSuccess(toastContent)
  logger.info('TaskNotify.sharingComplete', `gid=${task.gid} kind=${kind} name="${taskName}"`)
}

/**
 * Handle a download error.
 * Always sends in-app toast. Native OS notification is sent by Rust monitor.
 */
export function handleTaskError(task: Aria2Task, reason: string, deps: NotifyDeps): void {
  const taskName = getTaskDisplayName(task, { defaultName: 'Unknown' })
  const body = deps.t('task.download-fail-message', { taskName, reason })
  deps.messageError(body)
  logger.warn('TaskNotify.error', `gid=${task.gid} error="${body}"`)
}

// ── Download-start notification ─────────────────────────────────────

/** Dependency interface for start notification — minimal subset. */
export interface StartNotifyDeps {
  messageInfo: (content: string) => void
  t: (key: string, params?: Record<string, unknown>) => string
}

/**
 * Handle download submission success — send start notification.
 *
 * For single tasks:  "Downloading: movie.mp4"
 * For batch tasks:   "Downloading: movie.mp4 and 2 other task(s)"
 *
 * Toast always fires; OS notification is delegated to Rust so lightweight mode
 * uses the same backend-owned native path as completion/error notifications.
 */
export function handleTaskStart(tasks: Array<string | TaskStartNotificationTask>, deps: StartNotifyDeps): void {
  const normalizedTasks = tasks
    .map((task) => {
      if (typeof task === 'string') return { name: task.trim() }

      const name = task.name.trim()
      const gid = task.gid?.trim()
      return gid ? { name, gid } : { name }
    })
    .filter((task) => task.name.length > 0)

  if (normalizedTasks.length === 0) return

  const taskNames = normalizedTasks.map((task) => task.name)
  const firstName = taskNames[0]
  const body =
    taskNames.length === 1
      ? deps.t('task.download-start-message', { taskName: firstName })
      : deps.t('task.download-batch-start-message', {
          taskName: firstName,
          count: taskNames.length - 1,
        })

  deps.messageInfo(body)
  Promise.resolve(invoke('send_task_start_notification', { taskNames, tasks: normalizedTasks })).catch((error) =>
    logger.debug('TaskNotify.start', `native notification failed: ${error}`),
  )
  logger.info('TaskNotify.start', `count=${taskNames.length} first="${firstName}"`)
}
