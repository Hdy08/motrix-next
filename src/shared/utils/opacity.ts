import { OPACITY_PERCENT_MAX, OPACITY_PERCENT_MIN } from '@shared/constants'

export function normalizeOpacityPercent(
  value: unknown,
  fallback: number,
  min = OPACITY_PERCENT_MIN,
  max = OPACITY_PERCENT_MAX,
): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  return Math.min(max, Math.max(min, Math.round(value)))
}

export function opacityPercentToCssValue(value: unknown, fallback: number): string {
  return String(normalizeOpacityPercent(value, fallback) / 100)
}

export function opacityPercentToCssPercent(value: unknown, fallback: number): string {
  return `${normalizeOpacityPercent(value, fallback)}%`
}
