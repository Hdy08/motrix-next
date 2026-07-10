export interface CanvasPixelSize {
  width: number
  height: number
}

export interface ImageSourceRect extends CanvasPixelSize {
  x: number
  y: number
}

export const MAX_BACKGROUND_CANVAS_PIXELS = 16 * 1024 * 1024
export const MAX_BACKGROUND_DEVICE_PIXEL_RATIO = 2

export function calculateCanvasPixelSize(
  cssWidth: number,
  cssHeight: number,
  devicePixelRatio: number,
): CanvasPixelSize | null {
  if (cssWidth <= 0 || cssHeight <= 0) return null

  const pixelRatio = Math.min(
    MAX_BACKGROUND_DEVICE_PIXEL_RATIO,
    Math.max(1, Number.isFinite(devicePixelRatio) ? devicePixelRatio : 1),
  )
  let width = Math.max(1, Math.round(cssWidth * pixelRatio))
  let height = Math.max(1, Math.round(cssHeight * pixelRatio))
  const pixelCount = width * height

  if (pixelCount > MAX_BACKGROUND_CANVAS_PIXELS) {
    const limitScale = Math.sqrt(MAX_BACKGROUND_CANVAS_PIXELS / pixelCount)
    width = Math.max(1, Math.floor(width * limitScale))
    height = Math.max(1, Math.floor(height * limitScale))
  }

  return { width, height }
}

export function calculateCoverSourceRect(
  sourceWidth: number,
  sourceHeight: number,
  targetWidth: number,
  targetHeight: number,
): ImageSourceRect | null {
  if (sourceWidth <= 0 || sourceHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) return null

  const sourceRatio = sourceWidth / sourceHeight
  const targetRatio = targetWidth / targetHeight

  if (sourceRatio > targetRatio) {
    const width = sourceHeight * targetRatio
    return { x: (sourceWidth - width) / 2, y: 0, width, height: sourceHeight }
  }

  const height = sourceWidth / targetRatio
  return { x: 0, y: (sourceHeight - height) / 2, width: sourceWidth, height }
}
