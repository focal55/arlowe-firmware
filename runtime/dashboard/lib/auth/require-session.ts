import type { NextRequest } from 'next/server';
import { NextResponse } from 'next/server';
import { originMatchesHost } from './credential';
import { SESSION_COOKIE, loadSessionKey, readSession } from './session';

export function hasSession(request: NextRequest): boolean {
  return readSession(request.cookies.get(SESSION_COOKIE)?.value, loadSessionKey()) !== null;
}

// Next's docs warn against relying on the proxy alone, so every mutating handler
// calls this first; it returns the refusal to send, or null to proceed.
export function requireSession(request: NextRequest): NextResponse | null {
  if (!hasSession(request)) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  }
  if (!originMatchesHost(request.headers)) {
    return NextResponse.json({ error: 'forbidden' }, { status: 403 });
  }
  return null;
}
