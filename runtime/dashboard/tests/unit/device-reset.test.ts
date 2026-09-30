import { afterEach, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { NextRequest } from 'next/server';
import { POST as reset } from '../../app/api/device/reset/route.js';
import { resetDeps } from '../../lib/device/reset.js';
import { SESSION_COOKIE, issueSession } from '../../lib/auth/session.js';
import { loginThrottle } from '../../lib/auth/throttle.js';

const vector = JSON.parse(
  readFileSync(resolve(import.meta.dirname, 'fixtures/argon2-vector.json'), 'utf-8'),
) as { password: string; phc: string };

const HOST = 'kitchen-test.local:3000';
const realExecFile = resetDeps.execFile;
let key: Buffer;
let calls: Array<[string, string[]]>;
let execError: Error | null;

beforeEach(() => {
  const dir = mkdtempSync(join(tmpdir(), 'arlowe-reset-'));
  key = randomBytes(32);
  writeFileSync(join(dir, 'session.key'), key);
  writeFileSync(join(dir, 'owner-credential.json'), JSON.stringify({ hash: vector.phc }));
  process.env.ARLOWE_DASHBOARD_STATE_DIR = dir;
  loginThrottle.succeed();
  calls = [];
  execError = null;
  resetDeps.execFile = async (file, args) => {
    calls.push([file, args]);
    if (execError) throw execError;
  };
});

afterEach(() => {
  resetDeps.execFile = realExecFile;
});

function request(
  body: string,
  opts: { session?: boolean; origin?: string | null } = {},
): NextRequest {
  const headers: Record<string, string> = { host: HOST, 'content-type': 'application/json' };
  if (opts.session !== false) headers.cookie = `${SESSION_COOKIE}=${issueSession(key)}`;
  const origin = opts.origin === undefined ? `http://${HOST}` : opts.origin;
  if (origin !== null) headers.origin = origin;
  return new NextRequest(`http://${HOST}/api/device/reset`, { method: 'POST', headers, body });
}

const body = (password: string) => JSON.stringify({ password, confirm: 'RESET' });

describe('POST /api/device/reset', () => {
  it('starts the dashboard reset unit once and answers 202 for the right password', async () => {
    const res = await reset(request(body(vector.password)));
    assert.equal(res.status, 202);
    assert.deepEqual(await res.json(), { status: 'resetting' });
    assert.deepEqual(calls, [
      ['systemctl', ['start', '--no-block', 'arlowe-factory-reset@dashboard.service']],
    ]);
  });

  it('answers 401 without a session and starts nothing', async () => {
    const res = await reset(request(body(vector.password), { session: false }));
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: 'unauthorized' });
    assert.equal(calls.length, 0);
  });

  it('answers 401 for a wrong password, counts it toward the login throttle, starts nothing', async () => {
    for (let i = 0; i < 5; i++) {
      const res = await reset(request(body('wrong')));
      assert.equal(res.status, 401);
      assert.deepEqual(await res.json(), { error: 'invalid_credentials' });
    }
    assert.ok(loginThrottle.blocked());
    assert.equal(calls.length, 0);
  });

  it('answers 403 for a cross-origin request and starts nothing', async () => {
    for (const origin of ['http://evil.example', 'null']) {
      assert.equal((await reset(request(body(vector.password), { origin }))).status, 403);
    }
    assert.equal(calls.length, 0);
  });

  it('answers 429 while the login throttle is locked, even for the right password', async () => {
    for (let i = 0; i < 5; i++) loginThrottle.fail();
    const res = await reset(request(body(vector.password)));
    assert.equal(res.status, 429);
    assert.deepEqual(await res.json(), { error: 'too_many_attempts' });
    assert.equal(calls.length, 0);
  });

  it('answers 400 for a malformed body or a missing confirmation', async () => {
    for (const raw of [
      '{not json',
      '{"password":1,"confirm":"RESET"}',
      JSON.stringify({ password: vector.password }),
      JSON.stringify({ password: vector.password, confirm: 'reset' }),
    ]) {
      const res = await reset(request(raw));
      assert.equal(res.status, 400, raw);
      assert.deepEqual(await res.json(), { error: 'bad_request' });
    }
    assert.equal(calls.length, 0);
  });

  it('answers 500 when systemctl refuses the start', async () => {
    execError = new Error('exit 1');
    const res = await reset(request(body(vector.password)));
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: 'reset_failed' });
    assert.equal(calls.length, 1);
  });
});
