/**
 * @fileoverview Pure functions for the BitTorrent preference tab.
 *
 * Manages BT-specific config: auto-download content, encryption,
 * discovery, max peers, and tracker management. Key business logic:
 * - btAutoDownloadContent ↔ pauseMetadata
 * - Tracker comma ↔ newline format conversion
 *
 * Tracker source URL validation (isValidTrackerSourceUrl) is co-located
 * here since it is only used in the BT tab's tracker source management.
 */
import type { AppConfig } from '@shared/types'
import { DEFAULT_APP_CONFIG as D } from '@shared/constants'
import { convertCommaToLine, convertLineToComma } from '@shared/utils'

// ── URL Validation ──────────────────────────────────────────────────

/**
 * Validates whether a string is a valid HTTP/HTTPS URL suitable for use as a
 * tracker source. Custom tracker sources are fetched over HTTP, so only
 * HTTP-based protocols are accepted.
 */
export function isValidTrackerSourceUrl(input: string): boolean {
  const trimmed = input.trim()
  if (!trimmed) return false
  try {
    const url = new URL(trimmed)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

// ── Types ───────────────────────────────────────────────────────────

export interface BtForm {
  [key: string]: unknown
  btAutoDownloadContent: boolean
  btForceEncryption: boolean
  btDhtIpv4Enabled: boolean
  btDhtIpv6Enabled: boolean
  btPeerExchangeEnabled: boolean
  btLocalPeerDiscoveryEnabled: boolean
  btMaxPeers: number
  btPeerBlocklistEnabled: boolean
  btPeerBlocklistUrl: string
  btPeerBlocklistAutoSync: boolean
  btPeerBlocklistSyncIntervalHours: number
  trackerSource: string[]
  customTrackerUrls: string[]
  btTracker: string
  btTrackerAutoSync: boolean
  btTrackerSyncIntervalHours: number
  lastSyncTrackerTime: number
}

// ── Pure Functions ──────────────────────────────────────────────────

/**
 * Builds the BT form state from the preference store config.
 * Maps pauseMetadata into btAutoDownloadContent.
 */
export function buildBtForm(config: AppConfig): BtForm {
  const pauseMetadata = config.pauseMetadata ?? D.pauseMetadata
  const btAutoDownloadContent = !pauseMetadata

  return {
    btAutoDownloadContent,
    btForceEncryption: config.btForceEncryption ?? D.btForceEncryption,
    btDhtIpv4Enabled: config.btDhtIpv4Enabled ?? D.btDhtIpv4Enabled,
    btDhtIpv6Enabled: config.btDhtIpv6Enabled ?? D.btDhtIpv6Enabled,
    btPeerExchangeEnabled: config.btPeerExchangeEnabled ?? D.btPeerExchangeEnabled,
    btLocalPeerDiscoveryEnabled: config.btLocalPeerDiscoveryEnabled ?? D.btLocalPeerDiscoveryEnabled,
    btMaxPeers: config.btMaxPeers ?? D.btMaxPeers,
    btPeerBlocklistEnabled: config.btPeerBlocklistEnabled ?? D.btPeerBlocklistEnabled,
    btPeerBlocklistUrl: config.btPeerBlocklistUrl ?? D.btPeerBlocklistUrl,
    btPeerBlocklistAutoSync: config.btPeerBlocklistAutoSync ?? D.btPeerBlocklistAutoSync,
    btPeerBlocklistSyncIntervalHours: Number(
      config.btPeerBlocklistSyncIntervalHours ?? D.btPeerBlocklistSyncIntervalHours,
    ),
    trackerSource: config.trackerSource ?? [...D.trackerSource],
    customTrackerUrls: config.customTrackerUrls ?? [...D.customTrackerUrls],
    btTracker: convertCommaToLine(config.btTracker ?? D.btTracker),
    btTrackerAutoSync: config.btTrackerAutoSync ?? D.btTrackerAutoSync,
    btTrackerSyncIntervalHours: Number(config.btTrackerSyncIntervalHours ?? D.btTrackerSyncIntervalHours),
    lastSyncTrackerTime: config.lastSyncTrackerTime ?? D.lastSyncTrackerTime,
  }
}

/**
 * Converts the BT form into aria2 system config key-value pairs.
 * Handles btAutoDownloadContent → pause-metadata.
 *
 * IMPORTANT: force-save is intentionally excluded from global config.
 * It must only be set per-download on BT tasks to prevent aria2 from
 * re-downloading completed HTTP tasks on restart.
 */
export function buildBtSystemConfig(f: BtForm): Record<string, string> {
  const autoContent = !!f.btAutoDownloadContent
  return {
    'bt-max-peers': String(f.btMaxPeers),
    'bt-force-encryption': String(!!f.btForceEncryption),
    'bt-require-crypto': String(!!f.btForceEncryption),
    'enable-dht': String(!!f.btDhtIpv4Enabled),
    'enable-dht6': String(!!f.btDhtIpv6Enabled),
    'enable-peer-exchange': String(!!f.btPeerExchangeEnabled),
    'bt-enable-lpd': String(!!f.btLocalPeerDiscoveryEnabled),
    'pause-metadata': String(!autoContent),
    'bt-tracker': convertLineToComma(f.btTracker),
  }
}

/**
 * Transforms the BT form for store persistence.
 * Expands btAutoDownloadContent back into pauseMetadata.
 * Converts tracker newline format back to comma-separated for storage.
 */
export function transformBtForStore(f: BtForm): Partial<AppConfig> {
  const data = { ...f } as Partial<AppConfig> & Record<string, unknown>

  delete data.btAutoDownloadContent

  if (f.btAutoDownloadContent) {
    data.pauseMetadata = false
  } else {
    data.pauseMetadata = true
  }

  data.btTracker = convertLineToComma(f.btTracker)

  return data
}
