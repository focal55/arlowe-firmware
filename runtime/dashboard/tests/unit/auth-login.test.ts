import { afterEach, beforeEach, describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { NextRequest } from 'next/server';
import { POST as login } from '../../app/api/auth/login/route.js';
import { POST as logout } from '../../app/api/auth/logout/route.js';
import { loginThrottle } from '../../lib/auth/throttle.js';

const vector = JSON.parse(
  readFileSync(resolve(import.meta.dirname, 'fixtures/argon2-vector.json'), 'utf-8'),
) as { password: string; phc: string };

const HOST = 'kitchen-test.local:3000';

function stateDir(withCredential: boolean): string {
  const dir = mkdtempSync(join(tmpdir(), 'arlowe-login-'));
  writeFileSync(join(dir, 'session.key'), randomBytes(32));
  if (withCredential) {
    writeFileSync(
      join(dir, 'owner-credential.json'),
      JSON.stringify({ hash: vector.phc, created_at: '2026-09-28T00:00:00Z' }),
    );
  }
  process.env.ARLOWE_DASHBOARD_STATE_DIR = dir;
  return dir;
}

function request(path: string, body: string, origin: string | null = `http://${HOST}`): NextRequest {
  const headers: Record<string, string> = { host: HOST, 'content-type': 'application/json' };
  if (origin !== null) headers.origin = origin;
  return new NextRequest(`http://${HOST}${path}`, { method: 'POST', headers, body });
}

const attempt = (password: string, origin?: string | null) =>
  login(request('/api/auth/login', JSON.stringify({ password }), origin));

describe('POST /api/auth/login', () => {
  beforeEach(() => loginThrottle.succeed());
  afterEach(() => mock.timers.reset());

  it('issues the session cookie for the right password', async () => {
    stateDir(true);
    const res = await attempt(vector.password);
    assert.equal(res.status, 200);
    const cookie = res.headers.get('set-cookie') ?? '';
    assert.match(cookie, /^arlowe_session=[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+; /);
    assert.match(cookie, /HttpOnly; SameSite=Strict; Path=\/; Max-Age=2592000/);
    assert.doesNotMatch(cookie, /Secure/);
  });

  it('answers 401 invalid_credentials with no cookie for a wrong password', async () => {
    stateDir(true);
    const res = await attempt('wrong');
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: 'invalid_credentials' });
    assert.equal(res.headers.get('set-cookie'), null);
  });

  it('answers 429 on the sixth attempt after five failures until 30 s pass', async () => {
    mock.timers.enable({ apis: ['Date'], now: 1_800_000_000_000 });
    stateDir(true);
    for (let i = 0; i < 5; i++) assert.equal((await attempt('wrong')).status, 401);
    const locked = await attempt(vector.password);
    assert.equal(locked.status, 429);
    assert.deepEqual(await locked.json(), { error: 'too_many_attempts' });
    mock.timers.tick(29_999);
    assert.equal((await attempt(vector.password)).status, 429);
    mock.timers.tick(1);
    assert.equal((await attempt(vector.password)).status, 200);
  });

  it('refuses every password when no owner credential exists', async () => {
    stateDir(false);
    for (const password of [vector.password, '', 'arlowe', 'admin']) {
      loginThrottle.succeed();
      assert.equal((await attempt(password)).status, 401, password);
    }
  });

  it('answers 403 when Origin does not match Host', async () => {
    stateDir(true);
    assert.equal((await attempt(vector.password, 'http://evil.example')).status, 403);
    assert.equal((await attempt(vector.password, 'null')).status, 403);
    assert.equal((await attempt(vector.password, null)).status, 200);
  });

  it('answers 400 for a malformed body', async () => {
    stateDir(true);
    assert.equal((await login(request('/api/auth/login', '{not json'))).status, 400);
    assert.equal((await login(request('/api/auth/login', '{"password":1}'))).status, 400);
  });
});

describe('POST /api/auth/logout', () => {
  it('expires the session cookie', async () => {
    const res = await logout(request('/api/auth/logout', ''));
    assert.equal(res.status, 200);
    const cookie = res.headers.get('set-cookie') ?? '';
    assert.match(cookie, /^arlowe_session=; /);
    assert.match(cookie, /Max-Age=0/);
  });
});
