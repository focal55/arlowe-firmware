import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { dashboardStateDir } from './session';

export interface OwnerCredential {
  hash: string;
  created_at?: string;
}

// Read per request: pairing writes this file and a factory reset deletes it.
export async function loadOwnerCredential(
  dir: string = dashboardStateDir(),
): Promise<OwnerCredential | null> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(await readFile(join(dir, 'owner-credential.json'), 'utf-8'));
  } catch {
    return null;
  }
  const hash = (parsed as Partial<OwnerCredential> | null)?.hash;
  if (typeof hash !== 'string' || hash === '') return null;
  return parsed as OwnerCredential;
}

// An absent Origin is allowed (non-browser clients); a present one must name this host.
export function originMatchesHost(headers: Headers): boolean {
  const origin = headers.get('origin');
  if (origin === null) return true;
  try {
    return new URL(origin).host === headers.get('host');
  } catch {
    return false;
  }
}
