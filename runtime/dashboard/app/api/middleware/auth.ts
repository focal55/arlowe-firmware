import { NextRequest, NextResponse } from 'next/server';

/**
 * Verifies that the request has a valid API secret token.
 * 
 * Security model:
 * - If DASHBOARD_API_SECRET is not set, ALL destructive operations are blocked (safe default)
 * - If set, requests must include Authorization: Bearer <token> header
 * 
 * @param request - The incoming NextRequest
 * @returns null if authorized, NextResponse with 401/403 if not
 */
export function verifyAuth(request: NextRequest): NextResponse | null {
  const secret = process.env.DASHBOARD_API_SECRET;
  
  // Safe default: if no secret is configured, block all destructive operations
  if (!secret) {
    console.warn('[auth] DASHBOARD_API_SECRET not set - blocking destructive operation');
    return NextResponse.json(
      { 
        error: 'Destructive operations are disabled',
        details: 'DASHBOARD_API_SECRET environment variable is not configured'
      },
      { status: 403 }
    );
  }
  
  // Check for Authorization header
  const authHeader = request.headers.get('Authorization');
  
  if (!authHeader) {
    console.warn('[auth] Missing Authorization header');
    return NextResponse.json(
      { error: 'Unauthorized', details: 'Missing Authorization header' },
      { status: 401 }
    );
  }
  
  // Expect "Bearer <token>" format
  const parts = authHeader.split(' ');
  if (parts.length !== 2 || parts[0] !== 'Bearer') {
    console.warn('[auth] Invalid Authorization header format');
    return NextResponse.json(
      { error: 'Unauthorized', details: 'Invalid Authorization header format. Expected: Bearer <token>' },
      { status: 401 }
    );
  }
  
  const token = parts[1];
  
  // Timing-safe comparison to prevent timing attacks
  if (!timingSafeEqual(token, secret)) {
    console.warn('[auth] Invalid token provided');
    return NextResponse.json(
      { error: 'Unauthorized', details: 'Invalid token' },
      { status: 401 }
    );
  }
  
  // Authorized
  return null;
}

/**
 * Timing-safe string comparison to prevent timing attacks.
 * Returns true if strings are equal.
 */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    // Still do a comparison to avoid length-based timing leaks
    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= a.charCodeAt(i) ^ (b.charCodeAt(i % b.length) || 0);
    }
    return false;
  }
  
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
