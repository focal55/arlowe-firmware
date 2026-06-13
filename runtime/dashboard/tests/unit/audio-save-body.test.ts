import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import yaml from 'js-yaml';
import Ajv2020 from 'ajv/dist/2020';
import { buildSaveBody, CONFIG_DEFAULTS } from '../../app/audio/save-body.js';

const SCHEMA_PATH = resolve(import.meta.dirname, '../../../../config/schema.yml');

function buildValidator() {
  const schemaRaw = readFileSync(SCHEMA_PATH, 'utf-8');
  const schema = yaml.load(schemaRaw) as object;
  const ajv = new Ajv2020({ allErrors: true });
  return ajv.compile(schema);
}

// --- Before/After AJV evidence -----------------------------------------
//
// BEFORE fix: the page POSTed { audio: { capture_device, playback_device } }.
// That partial body fails AJV with 7 "must have required property" errors:
//   device, model, persona, ports, logs, support_mode, ota
//
// AFTER fix: buildSaveBody returns a full schema-valid object.
// The test below proves both facts against the real schema.
// -----------------------------------------------------------------------

describe('audio save-body: AJV round-trip evidence', () => {
  const validate = buildValidator();

  it('BEFORE — partial body { audio: {...} } fails AJV with missing required keys (422)', () => {
    const partialBody = {
      audio: { capture_device: 'Headphones', playback_device: 'auto' },
    };
    const ok = validate(partialBody);
    assert.equal(ok, false, 'Expected partial body to fail schema validation');
    const errorMessages = (validate.errors ?? []).map(e => e.message ?? '');
    // At least one "must have required property" error should be present
    const missingPropErrors = errorMessages.filter(m => m.includes('must have required property'));
    assert.ok(
      missingPropErrors.length >= 7,
      `Expected >=7 missing-property errors, got ${missingPropErrors.length}: ${JSON.stringify(validate.errors)}`,
    );
  });

  it('AFTER — buildSaveBody from null (pre-pairing) passes AJV (200)', () => {
    const body = buildSaveBody(null, 'Headphones', 'auto');
    const ok = validate(body);
    assert.equal(ok, true, `Expected full body to pass schema validation: ${JSON.stringify(validate.errors)}`);
  });

  it('AFTER — buildSaveBody from full overlay passes AJV (200)', () => {
    const existingOverlay = {
      ...CONFIG_DEFAULTS,
      audio: { capture_device: 'USB', playback_device: 'USB' },
    };
    const body = buildSaveBody(existingOverlay, 'Headphones', 'auto');
    const ok = validate(body);
    assert.equal(ok, true, `Expected merged body to pass schema validation: ${JSON.stringify(validate.errors)}`);
  });
});

describe('buildSaveBody: body construction', () => {
  it('sets audio.capture_device and audio.playback_device from arguments', () => {
    const body = buildSaveBody(null, 'MyMic', 'MySpeaker');
    const audio = body.audio as { capture_device: string; playback_device: string };
    assert.equal(audio.capture_device, 'MyMic');
    assert.equal(audio.playback_device, 'MySpeaker');
  });

  it('preserves "auto" sentinel — selecting Auto clears override to "auto"', () => {
    const body = buildSaveBody(null, 'auto', 'auto');
    const audio = body.audio as { capture_device: string; playback_device: string };
    assert.equal(audio.capture_device, 'auto');
    assert.equal(audio.playback_device, 'auto');
  });

  it('uses existing full overlay as base (does not clobber non-audio keys)', () => {
    const overlay = {
      ...CONFIG_DEFAULTS,
      model: { choice: 'qwen2.5-1.5b-int4-ax650' },
    };
    const body = buildSaveBody(overlay, 'auto', 'auto');
    const model = body.model as { choice: string };
    assert.equal(model.choice, 'qwen2.5-1.5b-int4-ax650', 'Non-audio keys from overlay must be preserved');
  });

  it('falls back to CONFIG_DEFAULTS when overlay is partial (missing required keys)', () => {
    const partialOverlay = { audio: { capture_device: 'USB', playback_device: 'USB' } } as Record<string, unknown>;
    const body = buildSaveBody(partialOverlay, 'Headphones', 'auto');
    // Should contain all required keys from defaults
    const required = ['device', 'audio', 'model', 'persona', 'ports', 'logs', 'support_mode', 'ota'];
    for (const key of required) {
      assert.ok(key in body, `Expected key "${key}" in body built from partial overlay`);
    }
    // Audio override must still apply
    const audio = body.audio as { capture_device: string; playback_device: string };
    assert.equal(audio.capture_device, 'Headphones');
  });

  it('falls back to CONFIG_DEFAULTS when overlay is null', () => {
    const body = buildSaveBody(null, 'auto', 'auto');
    assert.equal((body.device as { hostname: string }).hostname, 'arlowe-${device_serial}');
    assert.equal((body.ota as { channel: string }).channel, 'stable');
  });
});
