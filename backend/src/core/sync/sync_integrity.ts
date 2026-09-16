import { createHmac, timingSafeEqual } from 'node:crypto';
import { canonicalJsonStringify } from '../idempotency/canonical_json.js';

function key(): string {
  const secret = process.env.JWT_SECRET;
  if (!secret) throw new Error('JWT_SECRET is required');
  return secret;
}
export function syncMac(purpose: string, payload: unknown): string {
  return createHmac('sha256', key()).update(`AssistAiLab:FE02B:${purpose}\n`).update(canonicalJsonStringify(payload)).digest('base64url');
}
export function verifySyncMac(purpose: string, payload: unknown, signature: unknown): boolean {
  if (typeof signature !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(signature)) return false;
  return timingSafeEqual(Buffer.from(syncMac(purpose, payload)), Buffer.from(signature));
}
