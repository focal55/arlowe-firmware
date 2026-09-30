import type { NextRequest } from 'next/server';
import { NextResponse } from 'next/server';
import { hasSession } from './lib/auth/require-session';

export function proxy(request: NextRequest) {
  if (hasSession(request)) return NextResponse.next();
  const { pathname, search } = request.nextUrl;
  if (pathname.startsWith('/api/')) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  }
  const login = new URL('/login', request.url);
  login.searchParams.set('next', `${pathname}${search}`);
  return NextResponse.redirect(login);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|login|api/auth/login).*)'],
};
