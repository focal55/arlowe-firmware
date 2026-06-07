// knob -> affected systemd unit(s)
// INVARIANT: every unit returned here MUST match arlowe-* | qwen-* | whisper-stt.service —
// those are the only prefixes the Phase 3 polkit rule (50-arlowe-systemctl.rules) authorizes.
// Never add daemon-reload or a non-prefixed unit name.

const RESTART_MAP: Record<string, string[]> = {
  persona: ['arlowe-face.service'],
  model: ['qwen-tokenizer.service', 'qwen-api.service'],
  audio: ['arlowe-voice.service'],
  // ports has NO live consumer in Phase 4: no service reads the port knob yet.
  // It is wired here for when Phase 5+ services bind configured ports. A ports
  // change restarting face/voice is currently a no-op-on-behavior restart.
  ports: ['arlowe-face.service', 'arlowe-voice.service'],
  // knobs with no live consumer in Phase 4 — no restart issued:
  support_mode: [],
  ota: [],
  logs: [],
  device: [],
};

/**
 * Returns the de-duplicated union of units affected by the given top-level knob names.
 * Only units matching arlowe-* / qwen-* / whisper-stt.service are ever returned,
 * preserving the Phase 3 polkit contract.
 */
export function unitsForChange(changedTopLevelKeys: string[]): string[] {
  const seen = new Set<string>();
  for (const key of changedTopLevelKeys) {
    const units = RESTART_MAP[key] ?? [];
    for (const unit of units) {
      seen.add(unit);
    }
  }
  return Array.from(seen);
}
