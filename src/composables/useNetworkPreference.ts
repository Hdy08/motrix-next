/**
 * @fileoverview Pure functions for the Network preference tab.
 *
 * Manages: proxy, port mapping (UPnP, BT/DHT ports), P2P sharing policy,
 * transfer parameters (connect-timeout, timeout, file-allocation, async DNS), and User-Agent.
 * All keys here map to aria2 engine options via buildNetworkSystemConfig.
 *
 * Proxy validation logic is co-located here since it is only used in
 * this tab's save flow.
 */
import type { AppConfig, PortConflictRecoveryConfig, UserAgentProfile, UserAgentRule } from '@shared/types'
import {
  PORT_RECOVERY_RANGE_END,
  PORT_RECOVERY_RANGE_START,
  PROXY_SCOPE_OPTIONS,
  DEFAULT_APP_CONFIG as D,
} from '@shared/constants'
import { generateRandomInt } from '@shared/utils'
import { isValidAria2ProxyUrl, UNSUPPORTED_PROXY_SCHEME_RE } from '@shared/utils/proxy'
import { buildDownloadProxyOptions, normalizeProxyMode, type EngineProxyMode } from '@shared/utils/proxy'

export { isValidAria2ProxyUrl } from '@shared/utils/proxy'

// ── Types ───────────────────────────────────────────────────────────

export interface NetworkForm {
  [key: string]: unknown
  proxy: {
    mode: EngineProxyMode
    server: string
    username?: string
    password?: string
    bypass: string
    scope: string[]
  }
  enableUpnp: boolean
  autoChangeConflictingPorts: boolean
  portConflictRecovery: PortConflictRecoveryConfig
  listenPort: number
  dhtListenPort: number
  sharingMode: 'stop-by-condition' | 'manual-stop'
  shareRatio: number
  shareTime: number
  connectTimeout: number
  timeout: number
  fileAllocation: string
  asyncDns: boolean
  userAgent: string
  userAgentProfiles: UserAgentProfile[]
  userAgentRules: UserAgentRule[]
  recentUserAgentProfileIds: string[]
}

function buildPortConflictRecovery(config: AppConfig): PortConflictRecoveryConfig {
  const defaults = D.portConflictRecovery
  const saved = config.portConflictRecovery
  return {
    enabled: saved?.enabled ?? config.autoChangeConflictingPorts ?? defaults.enabled,
    rangeStart: Number(saved?.rangeStart ?? defaults.rangeStart),
    rangeEnd: Number(saved?.rangeEnd ?? defaults.rangeEnd),
    rpc: saved?.rpc ?? defaults.rpc,
    extensionApi: saved?.extensionApi ?? defaults.extensionApi,
    bt: saved?.bt ?? defaults.bt,
    dht: saved?.dht ?? defaults.dht,
    ed2k: saved?.ed2k ?? defaults.ed2k,
    ed2kUdp: saved?.ed2kUdp ?? defaults.ed2kUdp,
  }
}

// ── Pure Functions ──────────────────────────────────────────────────

/**
 * Builds the network form state from the preference store config.
 * All fallback values reference DEFAULT_APP_CONFIG (single source of truth).
 */
export function buildNetworkForm(config: AppConfig): NetworkForm {
  const proxy = config.proxy ?? D.proxy
  return {
    proxy: {
      mode: normalizeProxyMode(proxy.mode),
      server: proxy.server ?? D.proxy.server,
      username: proxy.username ?? D.proxy.username,
      password: proxy.password ?? D.proxy.password,
      bypass: proxy.bypass ?? D.proxy.bypass,
      scope: proxy.scope ?? [...PROXY_SCOPE_OPTIONS],
    },
    enableUpnp: config.enableUpnp ?? D.enableUpnp,
    autoChangeConflictingPorts: config.autoChangeConflictingPorts ?? D.autoChangeConflictingPorts,
    portConflictRecovery: buildPortConflictRecovery(config),
    listenPort: Number(config.listenPort ?? D.listenPort),
    dhtListenPort: Number(config.dhtListenPort ?? D.dhtListenPort),
    sharingMode: (config.keepSharing ?? D.keepSharing) ? 'manual-stop' : 'stop-by-condition',
    shareRatio: config.shareRatio ?? D.shareRatio,
    shareTime: config.shareTime ?? D.shareTime,
    connectTimeout: config.connectTimeout ?? D.connectTimeout,
    timeout: config.timeout ?? D.timeout,
    fileAllocation: config.fileAllocation ?? D.fileAllocation,
    asyncDns: config.asyncDns ?? D.asyncDns,
    userAgent: config.userAgent ?? D.userAgent,
    userAgentProfiles: config.userAgentProfiles ?? D.userAgentProfiles,
    userAgentRules: config.userAgentRules ?? D.userAgentRules,
    recentUserAgentProfileIds: config.recentUserAgentProfileIds ?? D.recentUserAgentProfileIds,
  }
}

/**
 * Converts the network form into aria2 system config key-value pairs.
 * Handles proxy scope filtering: only sets all-proxy if download scope is active.
 */
export function buildNetworkSystemConfig(f: NetworkForm): Record<string, string> {
  const keepSharing = f.sharingMode === 'manual-stop'
  const config: Record<string, string> = {
    'listen-port': String(f.listenPort),
    'dht-listen-port': String(f.dhtListenPort),
    'detach-share-only': 'true',
    'seed-ratio': keepSharing ? '0' : String(f.shareRatio),
    'keep-sharing': String(keepSharing),
    'user-agent': f.userAgent || '',
    'connect-timeout': String(f.connectTimeout),
    timeout: String(f.timeout),
    'file-allocation': f.fileAllocation || D.fileAllocation,
    'async-dns': String(!!f.asyncDns),
    ...buildDownloadProxyOptions(f.proxy),
  }

  config['seed-time'] = keepSharing ? '' : String(f.shareTime)

  return config
}

/**
 * Transforms the network form for store persistence.
 * Preserves port values as numbers and proxy as nested object.
 */
export function transformNetworkForStore(f: NetworkForm): Partial<AppConfig> {
  const data = { ...f } as Partial<AppConfig> & Record<string, unknown>
  delete data.sharingMode
  data.keepSharing = f.sharingMode === 'manual-stop'
  return {
    ...data,
    autoChangeConflictingPorts: f.portConflictRecovery.enabled,
  }
}

// ── Form Validation ─────────────────────────────────────────────────

/**
 * Validates the network preference form before saving.
 * Returns null if valid, or an i18n error key if invalid.
 */
export function validateNetworkForm(f: NetworkForm): string | null {
  const recovery = f.portConflictRecovery
  if (
    recovery.enabled &&
    (!Number.isInteger(recovery.rangeStart) ||
      !Number.isInteger(recovery.rangeEnd) ||
      recovery.rangeStart < 1024 ||
      recovery.rangeEnd > 65535 ||
      recovery.rangeStart > recovery.rangeEnd)
  ) {
    return 'preferences.port-conflict-recovery-invalid-range'
  }
  if (f.proxy.mode === 'manual' && f.proxy.server) {
    if (!isValidAria2ProxyUrl(f.proxy.server)) {
      return UNSUPPORTED_PROXY_SCHEME_RE.test(f.proxy.server.trim())
        ? 'preferences.proxy-unsupported-protocol'
        : 'preferences.invalid-proxy-url'
    }
  }
  return null
}

// ── Port Randomization ──────────────────────────────────────────────

export function randomBtPort(): number {
  return generateRandomInt(PORT_RECOVERY_RANGE_START, PORT_RECOVERY_RANGE_END + 1)
}

export function randomDhtPort(): number {
  return generateRandomInt(PORT_RECOVERY_RANGE_START, PORT_RECOVERY_RANGE_END + 1)
}
