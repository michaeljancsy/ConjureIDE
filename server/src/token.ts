import * as ed from "@noble/ed25519";
import type { TokenPayload, Env } from "./types";

// noble/ed25519 v2 uses webcrypto for hashing
import { sha512 } from "@noble/hashes/sha512";
ed.etc.sha512Sync = sha512;

/**
 * Sign a token payload with the server's Ed25519 private key.
 * Returns: base64(json_payload).base64(signature)
 */
export async function signToken(
  payload: TokenPayload,
  env: Env
): Promise<string> {
  const privateKeyBytes = base64ToBytes(env.ED25519_PRIVATE_KEY);
  const payloadJson = JSON.stringify(payload);
  const payloadBytes = new TextEncoder().encode(payloadJson);

  const signature = await ed.signAsync(payloadBytes, privateKeyBytes);

  const payloadB64 = bytesToBase64(payloadBytes);
  const sigB64 = bytesToBase64(signature);

  return `${payloadB64}.${sigB64}`;
}

/**
 * Create a token payload for a subscription.
 */
export function createTokenPayload(
  subscriptionId: string,
  email: string,
  status: string,
  currentPeriodEnd: string
): TokenPayload {
  const now = new Date();

  // valid_until = current_period_end + 1 day buffer for clock skew
  const periodEnd = new Date(currentPeriodEnd);
  const validUntil = new Date(periodEnd.getTime() + 24 * 60 * 60 * 1000);

  return {
    sub: subscriptionId,
    email,
    status,
    valid_until: validUntil.toISOString(),
    issued_at: now.toISOString(),
    product: "conjuredsp",
  };
}

/**
 * Parse a token to extract the payload (without verification).
 */
export function parseTokenPayload(token: string): TokenPayload | null {
  const parts = token.split(".");
  if (parts.length !== 2) return null;

  try {
    const payloadBytes = base64ToBytes(parts[0]);
    const payloadJson = new TextDecoder().decode(payloadBytes);
    return JSON.parse(payloadJson) as TokenPayload;
  } catch {
    return null;
  }
}

/**
 * Verify a token's Ed25519 signature and return the payload if valid.
 * Derives the public key from the server's private key.
 */
export async function verifyToken(
  token: string,
  env: Env
): Promise<TokenPayload | null> {
  const parts = token.split(".");
  if (parts.length !== 2) return null;

  try {
    const payloadBytes = base64ToBytes(parts[0]);
    const signatureBytes = base64ToBytes(parts[1]);
    const privateKeyBytes = base64ToBytes(env.ED25519_PRIVATE_KEY);
    const publicKey = await ed.getPublicKeyAsync(privateKeyBytes);

    const valid = await ed.verifyAsync(signatureBytes, payloadBytes, publicKey);
    if (!valid) return null;

    const payloadJson = new TextDecoder().decode(payloadBytes);
    return JSON.parse(payloadJson) as TokenPayload;
  } catch {
    return null;
  }
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}
