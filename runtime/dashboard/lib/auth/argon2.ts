import { argon2, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const argon2Async = promisify(argon2);

// argon2-cffi emits unpadded standard base64 for salt and hash.
const PHC = /^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/;

export async function verifyPassword(phc: string, password: string): Promise<boolean> {
  const m = PHC.exec(phc);
  if (!m) return false;
  const [, memory, passes, parallelism, salt, hash] = m;
  const expected = Buffer.from(hash, 'base64');
  try {
    const derived = await argon2Async('argon2id', {
      message: password,
      nonce: Buffer.from(salt, 'base64'),
      parallelism: Number(parallelism),
      tagLength: expected.length,
      memory: Number(memory),
      passes: Number(passes),
    });
    return derived.length === expected.length && timingSafeEqual(derived, expected);
  } catch {
    // Out-of-range parameters in a well-formed string (p=0, a 4-byte salt) make
    // crypto.argon2 throw; to the caller that is just a hash that does not match.
    return false;
  }
}
