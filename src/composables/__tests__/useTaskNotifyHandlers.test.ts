/**
 * @fileoverview TDD tests for task lifecycle notification handlers.
 *
 * These tests validate the notification callbacks that MainLayout registers
 * on the lifecycle service. The callback logic is extracted into pure
 * functions in useTaskNotifyHandlers.ts for independent unit testing —
 * following the same pattern as useTaskLifecycle.ts.
 *
 * Tests written BEFORE implementation per TDD Iron Law.
 *
 * Key behaviors under test:
 *   1. onComplete handler always sends in-app toast; Rust sends native OS notification.
 *   2. onSharingComplete handler always sends in-app toast; Rust sends native OS notification.
 *   3. onError handler logs the frontend toast path; Rust sends native OS notification.
 *   4. Metadata tasks are excluded from completion notifications.
 *   5. When action callbacks are provided, toast contains a render function.
 *   6. When action callbacks are absent, toast falls back to plain string.
 *   7. handleTaskStart sends aggregated toast + OS notification.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { Aria2Task } from '@shared/types'

// ── Mock backend notification command ────────────────────────────────
const mockInvoke = vi.fn((_command: string, _args?: Record<string, unknown>): Promise<void> => Promise.resolve())
vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: [string, Record<string, unknown>?]) => mockInvoke(...args),
}))

// ── Mock renderCompletionToast ───────────────────────────────────────
// Return a render function when actions are provided, plain string otherwise.
vi.mock('../useNotificationToast', () => ({
  renderCompletionToast: (options: { body: string; onOpenFile?: () => void; onShowInFolder?: () => void }) => {
    if (options.onOpenFile || options.onShowInFolder) {
      const fn = () => `[VNode: ${options.body}]`
      return fn
    }
    return options.body
  },
}))

import { handleTaskComplete, handleSharingComplete, handleTaskError, handleTaskStart } from '../useTaskNotifyHandlers'

// ── Test data factory ────────────────────────────────────────────────

function makeTask(overrides: Partial<Aria2Task> = {}): Aria2Task {
  return {
    gid: 'abc123',
    status: 'complete',
    totalLength: '1048576',
    completedLength: '1048576',
    uploadLength: '0',
    downloadSpeed: '0',
    uploadSpeed: '0',
    connections: '0',
    numSeeders: '0',
    dir: '/downloads',
    files: [
      {
        index: '1',
        path: '/downloads/test-file.zip',
        length: '1048576',
        completedLength: '1048576',
        selected: 'true',
        uris: [{ uri: 'https://example.com/test-file.zip', status: 'used' }],
      },
    ],
    bittorrent: undefined,
    infoHash: undefined,
    errorCode: undefined,
    errorMessage: undefined,
    numPieces: undefined,
    pieceLength: undefined,
    followedBy: undefined,
    following: undefined,
    belongsTo: undefined,
    ...overrides,
  } as Aria2Task
}

import type { NotifyDeps, StartNotifyDeps } from '../useTaskNotifyHandlers'

function makeDeps(overrides: Partial<NotifyDeps> = {}): NotifyDeps {
  return {
    messageSuccess: vi.fn() as unknown as NotifyDeps['messageSuccess'],
    messageError: vi.fn() as unknown as NotifyDeps['messageError'],
    t: vi.fn((key: string, params?: Record<string, unknown>) => {
      if (key === 'task.download-complete-message' && params?.taskName) {
        return `Saved: ${params.taskName}`
      }
      if (key === 'task.bt-download-complete-message' && params?.taskName) {
        return `Seeding: ${params.taskName}`
      }
      if (key === 'task.ed2k-download-complete-message' && params?.taskName) {
        return `Sharing: ${params.taskName}`
      }
      if (key === 'task.download-fail-message' && params?.taskName && params?.reason) {
        return `${params.taskName}: ${params.reason}`
      }
      if (key === 'task.error-unknown') return 'Unknown error'
      return key
    }) as unknown as NotifyDeps['t'],
    ...overrides,
  }
}

// ── handleTaskComplete ───────────────────────────────────────────────

describe('handleTaskComplete', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('sends success toast with task display name', () => {
    const deps = makeDeps()
    const task = makeTask()

    handleTaskComplete(task, deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    // Without action callbacks, renderCompletionToast returns plain string
    expect(deps.messageSuccess).toHaveBeenCalledWith('Saved: test-file.zip')
  })

  it('skips native aria2 metadata-only tasks', () => {
    const deps = makeDeps()
    const task = makeTask({
      bittorrent: {},
    })

    handleTaskComplete(task, deps)

    expect(deps.messageSuccess).not.toHaveBeenCalled()
  })

  it('uses bittorrent info name as display name when available', () => {
    const deps = makeDeps()
    const task = makeTask({ bittorrent: { info: { name: 'Ubuntu 24.04' } } })

    handleTaskComplete(task, deps)

    expect(deps.messageSuccess).toHaveBeenCalledWith('Saved: Ubuntu 24.04')
  })

  it('sends render function when onOpenFile callback is provided', () => {
    const onOpenFile = vi.fn()
    const deps = makeDeps({ onOpenFile })
    const task = makeTask()

    handleTaskComplete(task, deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    const arg = (deps.messageSuccess as ReturnType<typeof vi.fn>).mock.calls[0][0]
    expect(typeof arg).toBe('function')
  })

  it('sends render function when onShowInFolder callback is provided', () => {
    const onShowInFolder = vi.fn()
    const deps = makeDeps({ onShowInFolder })
    const task = makeTask()

    handleTaskComplete(task, deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    const arg = (deps.messageSuccess as ReturnType<typeof vi.fn>).mock.calls[0][0]
    expect(typeof arg).toBe('function')
  })

  it('sends render function when both action callbacks are provided', () => {
    const onOpenFile = vi.fn()
    const onShowInFolder = vi.fn()
    const deps = makeDeps({ onOpenFile, onShowInFolder })
    const task = makeTask()

    handleTaskComplete(task, deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    const arg = (deps.messageSuccess as ReturnType<typeof vi.fn>).mock.calls[0][0]
    expect(typeof arg).toBe('function')
  })
})

// ── handleSharingComplete ─────────────────────────────────────────────

describe('handleSharingComplete', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('sends success toast with task display name', () => {
    const deps = makeDeps()
    const task = makeTask({ bittorrent: { info: { name: 'Big Archive' } } })

    handleSharingComplete(task, 'bt', deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    expect(deps.messageSuccess).toHaveBeenCalledWith('Seeding: Big Archive')
  })

  it('uses ED2K sharing wording for ED2K tasks', () => {
    const deps = makeDeps()
    const task = makeTask({ ed2k: { name: 'Big Archive', hash: 'ed2khash' } })

    handleSharingComplete(task, 'ed2k', deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    expect(deps.messageSuccess).toHaveBeenCalledWith('Sharing: test-file.zip')
  })

  it('sends render function when action callbacks are provided', () => {
    const onOpenFile = vi.fn()
    const onShowInFolder = vi.fn()
    const deps = makeDeps({ onOpenFile, onShowInFolder })
    const task = makeTask({ bittorrent: { info: { name: 'Big Archive' } } })

    handleSharingComplete(task, 'bt', deps)

    expect(deps.messageSuccess).toHaveBeenCalledOnce()
    const arg = (deps.messageSuccess as ReturnType<typeof vi.fn>).mock.calls[0][0]
    expect(typeof arg).toBe('function')
  })
})

// ── handleTaskError ──────────────────────────────────────────────────

describe('handleTaskError', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('sends error toast with the same task and reason format as native notification', () => {
    const deps = makeDeps()
    const task = makeTask({
      status: 'error',
      errorCode: '6',
      errorMessage: 'Network problem',
    })

    handleTaskError(task, 'Network problem', deps)

    expect(deps.messageError).toHaveBeenCalledOnce()
    expect(deps.messageError).toHaveBeenCalledWith('test-file.zip: Network problem')
    expect(mockInvoke).not.toHaveBeenCalled()
  })
})

// ── handleTaskStart ─────────────────────────────────────────────

function makeStartDeps(overrides: Partial<StartNotifyDeps> = {}): StartNotifyDeps {
  return {
    messageInfo: vi.fn(),
    t: vi.fn((key: string, params?: Record<string, unknown>) => {
      if (key === 'task.download-start-message' && params?.taskName) {
        return `Downloading: ${params.taskName}`
      }
      if (key === 'task.download-batch-start-message' && params?.taskName) {
        return `Downloading: ${params.taskName} and ${params.count} other task(s)`
      }
      return key
    }) as unknown as StartNotifyDeps['t'],
    ...overrides,
  }
}

describe('handleTaskStart', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('sends info toast for single task', () => {
    const deps = makeStartDeps()

    handleTaskStart(['movie.mp4'], deps)

    expect(deps.messageInfo).toHaveBeenCalledOnce()
    expect(deps.messageInfo).toHaveBeenCalledWith('Downloading: movie.mp4')
  })

  it('delegates single-task OS notification to Rust', () => {
    const deps = makeStartDeps()

    handleTaskStart([{ name: 'movie.mp4', gid: 'task-gid-1' }], deps)

    expect(mockInvoke).toHaveBeenCalledOnce()
    expect(mockInvoke).toHaveBeenCalledWith('send_task_start_notification', {
      taskNames: ['movie.mp4'],
      tasks: [{ name: 'movie.mp4', gid: 'task-gid-1' }],
    })
  })

  it('sends aggregated toast for batch tasks', () => {
    const deps = makeStartDeps()

    handleTaskStart(['a.zip', 'b.torrent', 'c.iso'], deps)

    expect(deps.messageInfo).toHaveBeenCalledOnce()
    expect(deps.messageInfo).toHaveBeenCalledWith('Downloading: a.zip and 2 other task(s)')
  })

  it('delegates batch OS notification to Rust', () => {
    const deps = makeStartDeps()

    handleTaskStart(['a.zip', 'b.torrent', 'c.iso'], deps)

    expect(mockInvoke).toHaveBeenCalledWith('send_task_start_notification', {
      taskNames: ['a.zip', 'b.torrent', 'c.iso'],
      tasks: [{ name: 'a.zip' }, { name: 'b.torrent' }, { name: 'c.iso' }],
    })
  })

  it('skips all when taskNames is empty', () => {
    const deps = makeStartDeps()

    handleTaskStart([], deps)

    expect(deps.messageInfo).not.toHaveBeenCalled()
    expect(mockInvoke).not.toHaveBeenCalled()
  })
})
