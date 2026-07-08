import { UI_CONTROL_OPACITY_MAX, UI_CONTROL_OPACITY_MIN } from '@shared/constants'

export function normalizeOpacityPercent(
  value: unknown,
  fallback: number,
  min = UI_CONTROL_OPACITY_MIN,
  max = UI_CONTROL_OPACITY_MAX,
): number {
  const opacity = Number(value)
  if (!Number.isFinite(opacity)) return fallback
  return Math.min(max, Math.max(min, Math.round(opacity)))
}

export function opacityPercentToCssValue(value: unknown, fallback: number): string {
  return String(normalizeOpacityPercent(value, fallback) / 100)
}

export function opacityPercentToCssPercent(value: unknown, fallback: number): string {
  return `${normalizeOpacityPercent(value, fallback)}%`
}
