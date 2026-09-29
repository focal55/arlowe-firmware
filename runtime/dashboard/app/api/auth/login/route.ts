import { NextRequest, NextResponse } from 'next/server';
import { verifyPassword } from '../../../../lib/auth/argon2';
import { loadOwnerCredential, originMatchesHost } from '../../../../lib/auth/credential';
import {
  SESSION_COOKIE,
  issueSession,
  loadSessionKey,
  sessionCookieAttributes,
} from '../../../../lib/auth/session';
import { loginThrottle } from '../../../../lib/auth/throttle';

export async function POST(request: NextRequest) {
  if (!originMatchesHost(request.headers)) {
    return NextResponse.json({ error: 'forbidden' }, { status: 403 });
  }
  if (loginThrottle.blocked()) {
    return NextResponse.json({ error: 'too_many_attempts' }, { status: 429 });
  }

  let password: unknown;
  try {
    password = ((await request.json()) as { password?: unknown } | null)?.password;
  } catch {
    password = undefined;
  }
  if (typeof password !== 'string') {
    return NextResponse.json({ error: 'bad_request' }, { status: 400 });
  }

  // No credential or no session key means an unpaired or wiped unit: nothing logs in.
  const credential = await loadOwnerCredential();
  const key = loadSessionKey();
  if (!credential || !key || !(await verifyPassword(credential.hash, password))) {
    loginThrottle.fail();
    return NextResponse.json({ error: 'invalid_credentials' }, { status: 401 });
  }

  loginThrottle.succeed();
  const response = NextResponse.json({ ok: true });
  response.headers.set(
    'Set-Cookie',
    `${SESSION_COOKIE}=${issueSession(key)}; ${sessionCookieAttributes()}`,
  );
  return response;
}
