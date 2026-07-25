export interface CanvasPixelSize {
  width: number
  height: number
}

export interface ImageSourceRect extends CanvasPixelSize {
  x: number
  y: number
}

// A 24 Mi-pixel RGBA backing store costs about 96 MiB. This retains native
// detail on common high-DPI displays while bounding renderer/GPU memory.
export const MAX_BACKGROUND_CANVAS_PIXELS = 24 * 1024 * 1024

export function calculateCanvasPixelSize(
  cssWidth: number,
  cssHeight: number,
  devicePixelRatio: number,
): CanvasPixelSize | null {
  if (!Number.isFinite(cssWidth) || !Number.isFinite(cssHeight) || cssWidth <= 0 || cssHeight <= 0) return null
  const cssPixelCount = cssWidth * cssHeight
  if (!Number.isFinite(cssPixelCount)) return null

  const requestedPixelRatio = Number.isFinite(devicePixelRatio) && devicePixelRatio > 0 ? devicePixelRatio : 1
  // Do not hard-cap DPR: a 3x/4x display should remain sharp whenever its
  // backing store fits the bounded pixel budget.
  const pixelRatio = Math.max(1, Math.min(requestedPixelRatio, Math.sqrt(MAX_BACKGROUND_CANVAS_PIXELS / cssPixelCount)))
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
