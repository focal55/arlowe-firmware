// Minimum valid config satisfying schema.yml required keys + AJV 2020-12.
// Used as the base when the overlay is absent (pre-pairing) or missing keys.
// Must stay in sync with config/defaults.yml.
export const CONFIG_DEFAULTS: Record<string, unknown> = {
  device: { hostname: 'arlowe-${device_serial}' },
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

// Builds the POST body for POST /api/config by merging the audio selection into
// the current overlay.  POST /api/config AJV-validates the raw body against
// config/schema.yml which requires all 8 top-level keys — a partial body returns
// 422.  This function ensures the body is always schema-complete:
//
//   - If currentConfig has all 8 required keys (the overlay written by a prior
//     save), it is used as-is with the audio keys overwritten.
//   - Otherwise (overlay absent pre-pairing, or partially-written by another
//     tool), CONFIG_DEFAULTS fills the missing keys.
//
// The "auto" sentinel is preserved: selecting Auto passes "auto" as the device
// string, which is the correct default value per the schema.
export function buildSaveBody(
  currentConfig: Record<string, unknown> | null,
  captureDevice: string,
  playbackDevice: string,
): Record<string, unknown> {
  const base = isFullConfig(currentConfig)
    ? { ...currentConfig }
    : { ...CONFIG_DEFAULTS };

  return {
    ...base,
    audio: {
      capture_device: captureDevice,
      playback_device: playbackDevice,
    },
  };
}
