import { afterEach, beforeEach, describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { NextRequest } from 'next/server';
import { config, proxy } from '../../proxy.js';
import { SESSION_COOKIE, SESSION_MAX_AGE_S, issueSession } from '../../lib/auth/session.js';
import { POST as configPost } from '../../app/api/config/route.js';
import { POST as voicePost } from '../../app/api/voice/route.js';
import { POST as chatPost } from '../../app/api/npu/chat/route.js';
import { POST as benchmarkPost } from '../../app/api/npu/benchmark/route.js';
import { POST as connectPost } from '../../app/api/connectivity/connect/route.js';
import { DELETE as savedDelete } from '../../app/api/connectivity/saved/route.js';

const HOST = 'kitchen-test.local:3000';
let key: Buffer;

beforeEach(() => {
  const dir = mkdtempSync(join(tmpdir(), 'arlowe-proxy-'));
  key = randomBytes(32);
  writeFileSync(join(dir, 'session.key'), key);
  process.env.ARLOWE_DASHBOARD_STATE_DIR = dir;
});

function request(
  path: string,
  opts: { method?: string; cookie?: string; origin?: string; body?: string } = {},
): NextRequest {
  const headers: Record<string, string> = { host: HOST, 'content-type': 'application/json' };
  if (opts.cookie !== undefined) headers.cookie = `${SESSION_COOKIE}=${opts.cookie}`;
  if (opts.origin !== undefined) headers.origin = opts.origin;
  return new NextRequest(`http://${HOST}${path}`, {
    method: opts.method ?? 'GET',
    headers,
    body: opts.body,
  });
}

const passes = (res: Response) => res.headers.get('x-middleware-next') === '1';

describe('proxy', () => {
  it('redirects a page to /login with next when there is no session', async () => {
    const res = await proxy(request('/'));
    assert.equal(res.status, 307);
    assert.equal(res.headers.get('location'), `http://${HOST}/login?next=%2F`);
    assert.ok(passes(await proxy(request('/', { cookie: issueSession(key) }))));
  });

  it('keeps the query string in next', async () => {
    const res = await proxy(request('/logs?unit=voice'));
    assert.equal(res.headers.get('location'), `http://${HOST}/login?next=%2Flogs%3Funit%3Dvoice`);
  });

  it('answers 401 JSON for an API route when there is no session', async () => {
    const res = await proxy(request('/api/health'));
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: 'unauthorized' });
    assert.ok(passes(await proxy(request('/api/health', { cookie: issueSession(key) }))));
  });

  it('does not match the login page, the login API or static assets', () => {
    const matcher = new RegExp(`^${config.matcher[0]}$`);
    for (const path of ['/login', '/api/auth/login', '/_next/static/chunks/a.js', '/_next/image', '/favicon.ico']) {
      assert.ok(!matcher.test(path), path);
    }
    for (const path of ['/', '/logs', '/api/health', '/api/config', '/api/auth/logout']) {
      assert.ok(matcher.test(path), path);
    }
  });

  it('treats an expired, tampered or foreign-key cookie as none', async () => {
    const expired = issueSession(key, Date.now() - SESSION_MAX_AGE_S * 1000 - 1);
    const good = issueSession(key);
    const tampered = `x${good.slice(1)}`;
    const foreign = issueSession(randomBytes(32));
    for (const cookie of [expired, tampered, foreign, 'garbage']) {
      assert.equal((await proxy(request('/api/health', { cookie }))).status, 401, cookie);
    }
  });

  it('refuses every session once the key is gone', async () => {
    const cookie = issueSession(key);
    process.env.ARLOWE_DASHBOARD_STATE_DIR = mkdtempSync(join(tmpdir(), 'arlowe-proxy-'));
    assert.equal((await proxy(request('/api/health', { cookie }))).status, 401);
  });
});

// Each "proceeds" request is shaped to stop at the handler's own input check or at a
// mocked fetch, so no nmcli, systemctl, curl or file write runs.
const handlers: Array<{
  name: string;
  path: string;
  method: string;
  call: (r: NextRequest) => Promise<Response>;
  body: string;
  proceeds: number;
}> = [
  { name: 'config POST', path: '/api/config', method: 'POST', call: configPost, body: '{', proceeds: 500 },
  { name: 'voice POST', path: '/api/voice', method: 'POST', call: voicePost, body: '{', proceeds: 500 },
  { name: 'npu chat POST', path: '/api/npu/chat', method: 'POST', call: chatPost, body: '{', proceeds: 500 },
  { name: 'npu benchmark POST', path: '/api/npu/benchmark', method: 'POST', call: benchmarkPost, body: '', proceeds: 503 },
  { name: 'Wi-Fi connect POST', path: '/api/connectivity/connect', method: 'POST', call: connectPost, body: '{}', proceeds: 400 },
  { name: 'Wi-Fi forget DELETE', path: '/api/connectivity/saved', method: 'DELETE', call: savedDelete, body: '{}', proceeds: 400 },
];

describe('mutating handlers check the session themselves', () => {
  beforeEach(() => {
    mock.method(globalThis, 'fetch', async () => {
      throw new Error('NPU API down');
    });
  });
  afterEach(() => mock.restoreAll());

  for (const h of handlers) {
    it(`${h.name}: 401 without a session, 403 cross-origin, proceeds otherwise`, async () => {
      const cookie = issueSession(key);
      const send = (opts: { cookie?: string; origin?: string }) =>
        h.call(request(h.path, { method: h.method, body: h.body, ...opts }));

      const none = await send({ origin: `http://${HOST}` });
      assert.equal(none.status, 401);
      assert.deepEqual(await none.json(), { error: 'unauthorized' });

      const cross = await send({ cookie, origin: 'http://evil.example' });
      assert.equal(cross.status, 403);
      assert.deepEqual(await cross.json(), { error: 'forbidden' });

      assert.equal((await send({ cookie, origin: `http://${HOST}` })).status, h.proceeds);
    });
  }
});

describe('legacy bearer-secret check', () => {
  it('is deleted', () => {
    assert.ok(!existsSync(resolve(import.meta.dirname, '../../app/api/middleware/auth.ts')));
  });
});
