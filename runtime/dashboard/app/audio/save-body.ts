// Minimum valid config satisfying schema.yml required keys + AJV 2020-12.
// Used as the base when the overlay is absent (pre-pairing) or missing keys.
// Must stay in sync with config/defaults.yml.
export const CONFIG_DEFAULTS: Record<string, unknown> = {
  device: { hostname: 'arlowe-${device_serial}', display_name: 'Arlowe' },
  audio: { capture_device: 'auto', playback_device: 'auto' },
  model: { choice: 'qwen2.5-7b-int4-ax650' },
  persona: {
    sentiment_mapping: {
      positive: ['happy', 'excited'],
      negative: ['concerned', 'sad'],
      neutral: ['idle', 'attentive'],
    },
  },
  ports: { face: 8080, stt: 8082, dashboard: 3000 },
  logs: { transcript_retention_days: 7, transcript_logging_enabled: true },
  support_mode: { enabled: false, window_hours: 24 },
  ota: { channel: 'stable', channel_url: '' },
};

// Required top-level keys defined in schema.yml.
const REQUIRED_KEYS = ['device', 'audio', 'model', 'persona', 'ports', 'logs', 'support_mode', 'ota'];

// Returns true if obj contains all required top-level schema keys.
export function isFullConfig(obj: Record<string, unknown> | null): obj is Record<string, unknown> {
  if (!obj || typeof obj !== 'object') return false;
  return REQUIRED_KEYS.every(k => k in obj);
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function mergeOneLevel(
  defaults: Record<string, unknown>,
  overlay: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...defaults };
  for (const [k, v] of Object.entries(overlay)) {
    const d = defaults[k];
    out[k] = isPlainObject(d) && isPlainObject(v) ? { ...d, ...v } : v;
  }
  return out;
}

// Builds the POST body for POST /api/config. That route AJV-validates the raw
// body against config/schema.yml, which requires all 8 top-level keys, so a
// partial body returns 422. But GET /api/config returns the raw overlay, and a
// pairing overlay is partial by design (device, owner, network, identity). So
// the overlay is merged over CONFIG_DEFAULTS rather than replaced by them: every
// overlay key survives, including identity.provisioning_url, which reset needs to
// revoke the certificate; defaults fill only what is missing.
//
// The "auto" sentinel is preserved: selecting Auto passes "auto" as the device
// string, which is the correct default value per the schema.
export function buildSaveBody(
  currentConfig: Record<string, unknown> | null,
  captureDevice: string,
  playbackDevice: string,
): Record<string, unknown> {
  const base = mergeOneLevel(CONFIG_DEFAULTS, currentConfig ?? {});

  return {
    ...base,
    audio: {
      capture_device: captureDevice,
      playback_device: playbackDevice,
    },
  };
}
