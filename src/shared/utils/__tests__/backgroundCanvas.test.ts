import { describe, expect, it } from 'vitest'
import {
  MAX_BACKGROUND_CANVAS_PIXELS,
  calculateCanvasPixelSize,
  calculateCoverSourceRect,
} from '@shared/utils/backgroundCanvas'

describe('background canvas utilities', () => {
  it('uses device pixels while capping excessive pixel ratios', () => {
    expect(calculateCanvasPixelSize(800, 600, 2)).toEqual({ width: 1600, height: 1200 })
    expect(calculateCanvasPixelSize(800, 600, 4)).toEqual({ width: 1600, height: 1200 })
  })

  it('caps the backing store without changing its aspect ratio', () => {
    const size = calculateCanvasPixelSize(7680, 4320, 2)

    expect(size).not.toBeNull()
    expect(size!.width * size!.height).toBeLessThanOrEqual(MAX_BACKGROUND_CANVAS_PIXELS)
    expect(size!.width / size!.height).toBeCloseTo(16 / 9, 3)
  })

  it('calculates centered cover crops for wide and tall sources', () => {
    expect(calculateCoverSourceRect(4000, 2000, 1000, 1000)).toEqual({
      x: 1000,
      y: 0,
      width: 2000,
      height: 2000,
    })
    expect(calculateCoverSourceRect(2000, 4000, 1000, 500)).toEqual({
      x: 0,
      y: 1500,
      width: 2000,
      height: 1000,
    })
  })

  it('rejects empty dimensions', () => {
    expect(calculateCanvasPixelSize(0, 600, 2)).toBeNull()
    expect(calculateCoverSourceRect(0, 100, 100, 100)).toBeNull()
  })
})
