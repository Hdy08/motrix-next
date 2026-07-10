/**
 * @fileoverview Loads a user-selected local image through Rust IPC and exposes
 * a revokable object URL for use in CSS backgrounds and image elements.
 */
import { readonly, ref, toValue, watch, onBeforeUnmount, type MaybeRefOrGetter, type Ref } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { logger } from '@shared/logger'
import { getErrorMessage } from '@shared/utils/errorMessage'

const IMAGE_MIME_BY_EXTENSION: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  bmp: 'image/bmp',
  gif: 'image/gif',
}

export function inferImageMimeType(path: string): string {
  const extension = path.split(/[\\/]/).pop()?.split('.').pop()?.toLowerCase() ?? ''
  return IMAGE_MIME_BY_EXTENSION[extension] ?? 'application/octet-stream'
}

export function useLocalImageObjectUrl(pathSource: MaybeRefOrGetter<string>): Readonly<Ref<string>> {
  const objectUrl = ref('')
  let activeUrl = ''
  let requestId = 0

  function clearActiveUrl(): void {
    if (activeUrl) {
      URL.revokeObjectURL(activeUrl)
      activeUrl = ''
    }
    objectUrl.value = ''
  }

  watch(
    () => toValue(pathSource).trim(),
    async (path) => {
      const currentRequestId = ++requestId
      clearActiveUrl()

      if (!path) return

      try {
        const bytes = await invoke<ArrayBuffer>('read_local_image', { path })
        if (currentRequestId !== requestId) {
          return
        }

        const nextUrl = URL.createObjectURL(new Blob([bytes], { type: inferImageMimeType(path) }))
        activeUrl = nextUrl
        objectUrl.value = nextUrl
      } catch (e) {
        if (currentRequestId === requestId) {
          logger.warn('LocalImageObjectUrl.load', getErrorMessage(e))
        }
      }
    },
    { immediate: true },
  )

  onBeforeUnmount(() => {
    requestId += 1
    clearActiveUrl()
  })

  return readonly(objectUrl)
}
