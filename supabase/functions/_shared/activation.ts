// School OS — shared helpers for the account-activation flow
// (create-user, reissue-activation-code, activate-account).

const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I — avoids misread codes
export const ACTIVATION_CODE_TTL_MS = 72 * 60 * 60 * 1000; // 72 hours
export const ACTIVATION_MAX_ATTEMPTS = 5;

/** Cryptographically random one-time activation code, e.g. "K7QX9M2P". */
export function generateActivationCode(length = 8): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let code = "";
  for (let i = 0; i < length; i++) {
    code += CODE_CHARS[bytes[i] % CODE_CHARS.length];
  }
  return code;
}

/** SHA-256 hex digest — the plaintext code is never stored, only this. */
export async function hashActivationCode(code: string): Promise<string> {
  const data = new TextEncoder().encode(code.trim().toUpperCase());
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
