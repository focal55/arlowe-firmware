import { NextRequest, NextResponse } from 'next/server';
import { verifyPassword } from '../../../../lib/auth/argon2';
import { loadOwnerCredential } from '../../../../lib/auth/credential';
import { requireSession } from '../../../../lib/auth/require-session';
import { loginThrottle } from '../../../../lib/auth/throttle';
import { startReset } from '../../../../lib/device/reset';

export async function POST(request: NextRequest) {
  const denied = requireSession(request);
  if (denied) return denied;
  // Shared with login so the re-entry field cannot be used to brute-force the password.
  if (loginThrottle.blocked()) {
    return NextResponse.json({ error: 'too_many_attempts' }, { status: 429 });
  }

  let body: { password?: unknown; confirm?: unknown } | null;
  try {
    body = await request.json();
  } catch {
    body = null;
  }
  if (typeof body?.password !== 'string' || body.confirm !== 'RESET') {
    return NextResponse.json({ error: 'bad_request' }, { status: 400 });
  }

  const credential = await loadOwnerCredential();
  if (!credential || !(await verifyPassword(credential.hash, body.password))) {
    loginThrottle.fail();
    return NextResponse.json({ error: 'invalid_credentials' }, { status: 401 });
  }
  loginThrottle.succeed();

  try {
    await startReset();
  } catch (error) {
    console.error('factory reset start failed:', error instanceof Error ? error.message : error);
    return NextResponse.json({ error: 'reset_failed' }, { status: 500 });
  }
  console.log('factory reset requested (dashboard)');
  return NextResponse.json({ status: 'resetting' }, { status: 202 });
}
