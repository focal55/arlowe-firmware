import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  SESSION_COOKIE,
  issueSession,
  loadSessionKey,
  readSession,
  sessionCookieAttributes,
} from '../../lib/auth/session.js';
import { Throttle } from '../../lib/auth/throttle.js';

const KEY = Buffer.alloc(32, 7);
const NOW = 1_800_000_000_000;
const DAY_MS = 24 * 60 * 60 * 1000;

function flipChar(s: string, i: number): string {
  return s.slice(0, i) + (s[i] === 'A' ? 'B' : 'A') + s.slice(i + 1);
}

describe('issueSession / readSession', () => {
  it('issues <b64url payload>.<b64url hmac> expiring in 30 days', () => {
    const value = issueSession(KEY, NOW);
    assert.match(value, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    assert.deepEqual(readSession(value, KEY, NOW), { iat: NOW, exp: NOW + 30 * DAY_MS });
  });

  it('is valid until expiry and null after it', () => {
    const value = issueSession(KEY, NOW);
    assert.notEqual(readSession(value, KEY, NOW + 30 * DAY_MS - 1), null);
    assert.equal(readSession(value, KEY, NOW + 30 * DAY_MS), null);
  });

  it('is null when a payload or signature byte changes', () => {
    const value = issueSession(KEY, NOW);
    const dot = value.indexOf('.');
    assert.equal(readSession(flipChar(value, 2), KEY, NOW), null);
    assert.equal(readSession(flipChar(value, dot + 2), KEY, NOW), null);
  });

  it('is null under a different key', () => {
    assert.equal(readSession(issueSession(KEY, NOW), Buffer.alloc(32, 8), NOW), null);
  });

  it('is null for a value with no dot, an empty value, or no key', () => {
    const value = issueSession(KEY, NOW);
    assert.equal(readSession(value.replace('.', ''), KEY, NOW), null);
    assert.equal(readSession('', KEY, NOW), null);
    assert.equal(readSession(undefined, KEY, NOW), null);
    assert.equal(readSession(value, null, NOW), null);
  });
});

describe('loadSessionKey', () => {
  it('returns null when the key file is absent or not 32 bytes, else the key', () => {
    const dir = mkdtempSync(join(tmpdir(), 'arlowe-session-'));
    assert.equal(loadSessionKey(dir), null);
    writeFileSync(join(dir, 'session.key'), Buffer.alloc(31, 1));
    assert.equal(loadSessionKey(dir), null);
    writeFileSync(join(dir, 'session.key'), KEY);
    assert.deepEqual(loadSessionKey(dir), KEY);
  });
});

describe('session cookie', () => {
  it('is named arlowe_session and never Secure', () => {
    assert.equal(SESSION_COOKIE, 'arlowe_session');
    const attrs = sessionCookieAttributes();
    assert.equal(attrs, 'HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000');
    assert.doesNotMatch(attrs, /Secure/);
  });
});

describe('Throttle', () => {
  it('blocks for 30 s after 5 failures, then unblocks', () => {
    const t = new Throttle();
    for (let i = 0; i < 4; i++) t.fail(NOW);
    assert.equal(t.blocked(NOW), false);
    t.fail(NOW);
    assert.equal(t.blocked(NOW), true);
    assert.equal(t.blocked(NOW + 29_999), true);
    assert.equal(t.blocked(NOW + 30_000), false);
  });

  it('resets the failure count on success', () => {
    const t = new Throttle();
    for (let i = 0; i < 4; i++) t.fail(NOW);
    t.succeed();
    t.fail(NOW);
    assert.equal(t.blocked(NOW), false);
  });
});
