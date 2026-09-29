import { NextRequest, NextResponse } from 'next/server';
import { originMatchesHost } from '../../../../lib/auth/credential';
import { SESSION_COOKIE } from '../../../../lib/auth/session';

export async function POST(request: NextRequest) {
  if (!originMatchesHost(request.headers)) {
    return NextResponse.json({ error: 'forbidden' }, { status: 403 });
  }
  const response = NextResponse.json({ ok: true });
  response.headers.set('Set-Cookie', `${SESSION_COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);
  return response;
}
