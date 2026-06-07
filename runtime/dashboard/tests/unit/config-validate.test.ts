import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import yaml from 'js-yaml';
import Ajv2020 from 'ajv/dist/2020';
import { unitsForChange } from '../../app/api/config/restart-map.js';

// Resolve schema relative to this file: runtime/dashboard/tests/unit/ -> repo root -> config/
const SCHEMA_PATH = resolve(import.meta.dirname, '../../../../config/schema.yml');

function buildValidator() {
  const schemaRaw = readFileSync(SCHEMA_PATH, 'utf-8');
  const schema = yaml.load(schemaRaw) as object;
  const ajv = new Ajv2020({ allErrors: true });
  return ajv.compile(schema);
}

// Polkit-authorized unit name pattern (Phase 3 rule).
const POLKIT_PATTERN = /^(arlowe-|qwen-)|^whisper-stt\.service$/;

describe('unitsForChange', () => {
  it('persona maps to arlowe-face.service', () => {
    const units = unitsForChange(['persona']);
    assert.deepEqual(units, ['arlowe-face.service']);
  });

  it('ota maps to [] (no live consumer in Phase 4)', () => {
    const units = unitsForChange(['ota']);
    assert.deepEqual(units, []);
  });

  it('support_mode maps to [] (no live consumer in Phase 4)', () => {
    assert.deepEqual(unitsForChange(['support_mode']), []);
  });

  it('logs maps to [] (no live consumer in Phase 4)', () => {
    assert.deepEqual(unitsForChange(['logs']), []);
  });

  it('deduplicates units when multiple knobs share a unit', () => {
    const units = unitsForChange(['persona', 'ports']);
    // both include arlowe-face.service; it should appear once
    const faceCount = units.filter(u => u === 'arlowe-face.service').length;
    assert.equal(faceCount, 1);
  });

  it('every unit returned by any knob matches the polkit-authorized prefix', () => {
    const allKnobs = ['persona', 'model', 'audio', 'ports', 'support_mode', 'ota', 'logs', 'device'];
    const units = unitsForChange(allKnobs);
    for (const unit of units) {
      assert.match(
        unit,
        POLKIT_PATTERN,
        `Unit "${unit}" does not match polkit-authorized prefix (arlowe-* | qwen-* | whisper-stt.service)`
      );
    }
  });
});

describe('ajv schema validation', () => {
  const validate = buildValidator();

  it('accepts a valid minimal config', () => {
    const config = {
      device: { hostname: 'arlowe-${device_serial}' },
      audio: { capture_device: 'auto', playback_device: 'auto' },
      model: { choice: 'qwen2.5-7b-int4-ax650' },
      persona: {
        sentiment_mapping: {
          positive: ['happy'],
          negative: ['concerned'],
          neutral: ['idle'],
        },
      },
      ports: { face: 8080, stt: 8082, dashboard: 3000 },
      logs: { transcript_retention_days: 7, transcript_logging_enabled: true },
      support_mode: { enabled: false, window_hours: 24 },
      ota: { channel: 'stable', channel_url: '' },
    };
    const ok = validate(config);
    assert.equal(ok, true, JSON.stringify(validate.errors));
  });

  it('rejects an invalid ota.channel enum value', () => {
    const config = {
      device: { hostname: 'arlowe-${device_serial}' },
      audio: { capture_device: 'auto', playback_device: 'auto' },
      model: { choice: 'qwen2.5-7b-int4-ax650' },
      persona: {
        sentiment_mapping: {
          positive: ['happy'],
          negative: ['concerned'],
          neutral: ['idle'],
        },
      },
      ports: { face: 8080, stt: 8082, dashboard: 3000 },
      logs: { transcript_retention_days: 7, transcript_logging_enabled: true },
      support_mode: { enabled: false, window_hours: 24 },
      ota: { channel: 'nightly', channel_url: '' }, // 'nightly' is not in the enum
    };
    const ok = validate(config);
    assert.equal(ok, false, 'Expected validation to fail for invalid ota.channel');
    assert.ok(
      validate.errors && validate.errors.length > 0,
      'Expected at least one validation error'
    );
  });

  it('rejects a body missing required top-level keys', () => {
    const ok = validate({ model: { choice: 'qwen2.5-7b-int4-ax650' } });
    assert.equal(ok, false, 'Expected validation to fail for missing required keys');
  });
});
