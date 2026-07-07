import { defineComponent, h, nextTick, ref, type Ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const invokeMock = vi.fn()
const warnMock = vi.fn()

vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}))

vi.mock('@shared/logger', () => ({
  logger: { warn: (...args: unknown[]) => warnMock(...args) },
}))

import { inferImageMimeType, useLocalImageObjectUrl } from '../useLocalImageObjectUrl'

let objectUrlIndex = 0
const createObjectURLMock = vi.fn((_blob: Blob) => `blob:background-${++objectUrlIndex}`)
const revokeObjectURLMock = vi.fn((_url: string) => undefined)

function installUrlMocks(): void {
  Object.defineProperty(URL, 'createObjectURL', {
    configurable: true,
    value: createObjectURLMock,
  })
  Object.defineProperty(URL, 'revokeObjectURL', {
    configurable: true,
    value: revokeObjectURLMock,
  })
}

function mountHarness(initialPath: string): {
  imagePath: Ref<string>
  imageUrl: Readonly<Ref<string>>
  unmount: () => void
} {
  const imagePath = ref(initialPath)
  let imageUrl!: Readonly<Ref<string>>
  const wrapper = mount(
    defineComponent({
      setup() {
        imageUrl = useLocalImageObjectUrl(imagePath)
        return () => h('div', imageUrl.value)
      },
    }),
  )

  return {
    imagePath,
    imageUrl,
    unmount: () => wrapper.unmount(),
  }
}

describe('useLocalImageObjectUrl', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    objectUrlIndex = 0
    installUrlMocks()
  })

  it('infers image MIME types from local paths', () => {
    expect(inferImageMimeType('C:\\Users\\me\\Pictures\\cover.PNG')).toBe('image/png')
    expect(inferImageMimeType('/home/me/wallpaper.jpeg')).toBe('image/jpeg')
    expect(inferImageMimeType('/home/me/wallpaper.unknown')).toBe('application/octet-stream')
  })

  it('loads a local image through Rust IPC and exposes an object URL', async () => {
    invokeMock.mockResolvedValue([1, 2, 3])

    const { imageUrl } = mountHarness('C:\\Users\\me\\Pictures\\background.png')
    await flushPromises()

    expect(invokeMock).toHaveBeenCalledWith('read_local_file', {
      path: 'C:\\Users\\me\\Pictures\\background.png',
    })
    expect(createObjectURLMock).toHaveBeenCalledTimes(1)
    const blobArg = createObjectURLMock.mock.calls[0][0]
    expect(blobArg).toBeInstanceOf(Blob)
    if (!(blobArg instanceof Blob)) throw new Error('expected Blob argument')
    expect(blobArg.type).toBe('image/png')
    expect(imageUrl.value).toBe('blob:background-1')
  })

  it('revokes the active object URL when the path is cleared', async () => {
    invokeMock.mockResolvedValue([1, 2, 3])

    const { imagePath, imageUrl } = mountHarness('C:\\Users\\me\\Pictures\\background.webp')
    await flushPromises()

    imagePath.value = ''
    await nextTick()

    expect(revokeObjectURLMock).toHaveBeenCalledWith('blob:background-1')
    expect(imageUrl.value).toBe('')
  })

  it('does not expose stale object URLs when paths change during loading', async () => {
    let resolveFirst!: (value: number[]) => void
    invokeMock
      .mockImplementationOnce(
        () =>
          new Promise<number[]>((resolve) => {
            resolveFirst = resolve
          }),
      )
      .mockResolvedValueOnce([4, 5, 6])

    const { imagePath, imageUrl } = mountHarness('C:\\Users\\me\\Pictures\\old.png')
    imagePath.value = 'C:\\Users\\me\\Pictures\\new.jpg'
    await nextTick()
    await flushPromises()

    expect(imageUrl.value).toBe('blob:background-1')

    resolveFirst([1, 2, 3])
    await flushPromises()

    expect(imageUrl.value).toBe('blob:background-1')
    expect(revokeObjectURLMock).toHaveBeenCalledWith('blob:background-2')
  })

  it('revokes the active object URL on unmount', async () => {
    invokeMock.mockResolvedValue([1, 2, 3])

    const { unmount } = mountHarness('C:\\Users\\me\\Pictures\\background.gif')
    await flushPromises()

    unmount()

    expect(revokeObjectURLMock).toHaveBeenCalledWith('blob:background-1')
  })
})
