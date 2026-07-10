import { describe, expect, it } from 'vitest'
import { normalizeOpacityPercent, opacityPercentToCssPercent, opacityPercentToCssValue } from '@shared/utils/opacity'

describe('opacity utilities', () => {
  it('rounds and clamps finite numeric values', () => {
    expect(normalizeOpacityPercent(42.6, 100)).toBe(43)
    expect(normalizeOpacityPercent(-1, 100)).toBe(0)
    expect(normalizeOpacityPercent(101, 100)).toBe(100)
  })

  it('uses the fallback for non-finite values', () => {
    expect(normalizeOpacityPercent(Number.NaN, 35)).toBe(35)
    expect(normalizeOpacityPercent(Number.POSITIVE_INFINITY, 35)).toBe(35)
    expect(normalizeOpacityPercent(undefined, 35)).toBe(35)
    expect(normalizeOpacityPercent('75', 35)).toBe(35)
  })

  it('formats normalized values for CSS', () => {
    expect(opacityPercentToCssValue(75, 100)).toBe('0.75')
    expect(opacityPercentToCssPercent(75, 100)).toBe('75%')
  })
})
