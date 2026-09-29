import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { verifyPassword } from '../../lib/auth/argon2.js';

// Produced by argon2-cffi 21.1.0 (the version python3-argon2 ships in bookworm)
// with ADR-0012's parameters, so a pass here means Python hashes and Node verifies.
const vector = JSON.parse(
  readFileSync(resolve(import.meta.dirname, 'fixtures/argon2-vector.json'), 'utf-8'),
) as { password: string; phc: string };

describe('verifyPassword', () => {
  it('accepts the python-produced hash for the right password', async () => {
    assert.equal(await verifyPassword(vector.phc, vector.password), true);
  });

  it('rejects a wrong password', async () => {
    assert.equal(await verifyPassword(vector.phc, 'correct horse battery staple'), false);
  });

  it('rejects argon2i', async () => {
    assert.equal(await verifyPassword(vector.phc.replace('$argon2id$', '$argon2i$'), vector.password), false);
  });

  it('rejects argon2 version 16', async () => {
    assert.equal(await verifyPassword(vector.phc.replace('$v=19$', '$v=16$'), vector.password), false);
  });

  it('returns false for malformed input without throwing', async () => {
    for (const phc of ['', 'garbage', '$argon2id$v=19$m=x,t=3,p=4$abc$def', `${vector.phc}$extra`]) {
      assert.equal(await verifyPassword(phc, vector.password), false, phc);
    }
  });
});
