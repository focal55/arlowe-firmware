import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

export const SESSION_COOKIE = 'arlowe_session';
export const SESSION_MAX_AGE_S = 30 * 24 * 60 * 60;
const KEY_BYTES = 32;

export interface SessionPayload {
  iat: number;
  exp: number;
}

export function dashboardStateDir(): string {
  return process.env.ARLOWE_DASHBOARD_STATE_DIR || '/var/lib/arlowe/dashboard';
}

// No Secure attribute: the dashboard is plain HTTP on the LAN, and browsers
// drop Secure cookies set by an http origin.
export function sessionCookieAttributes(): string {
  return `HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE_S}`;
}

function sign(key: Buffer, data: string): Buffer {
  return createHmac('sha256', key).update(data).digest();
}

export function issueSession(key: Buffer, now: number = Date.now()): string {
  const payload: SessionPayload = { iat: now, exp: now + SESSION_MAX_AGE_S * 1000 };
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${body}.${sign(key, body).toString('base64url')}`;
}

export function readSession(
  value: string | undefined,
  key: Buffer | null,
  now: number = Date.now(),
): SessionPayload | null {
  if (!value || !key) return null;
  const dot = value.indexOf('.');
  if (dot < 0) return null;
  const body = value.slice(0, dot);
  const given = Buffer.from(value.slice(dot + 1), 'base64url');
  const expected = sign(key, body);
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf-8'));
  } catch {
    return null;
  }
  const { iat, exp } = (payload ?? {}) as Partial<SessionPayload>;
  if (typeof iat !== 'number' || typeof exp !== 'number' || now >= exp) return null;
  return { iat, exp };
}

// The proxy reads the key on every request; stat is cheap, the re-read is not
// needed unless pairing or a reset has rewritten the file.
const keyCache = new Map<string, { stamp: string; key: Buffer | null }>();

export function loadSessionKey(dir: string = dashboardStateDir()): Buffer | null {
  const path = join(dir, 'session.key');
  let stamp: string;
  try {
    const st = statSync(path, { bigint: true });
    stamp = `${st.mtimeNs}:${st.size}`;
  } catch {
    keyCache.delete(path);
    return null;
  }
  const cached = keyCache.get(path);
  if (cached && cached.stamp === stamp) return cached.key;
  let key: Buffer | null;
  try {
    const raw = readFileSync(path);
    key = raw.length === KEY_BYTES ? raw : null;
  } catch {
    key = null;
  }
  keyCache.set(path, { stamp, key });
  return key;
}
