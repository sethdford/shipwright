// Sign-in helpers for the dashboard: OAuth `state` (CSRF on the OAuth callback) and single-use
// join tokens. No file or network I/O; server.ts owns persistence.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export const OAUTH_STATE_COOKIE = "oauth_state";

/** The `oauth_state` cookie value, or null. */
export function oauthStateFromCookie(cookie: string | null): string | null {
  const match = (cookie ?? "").match(/(?:^|;\s*)oauth_state=([0-9a-f]+)/);
  return match?.[1] ?? null;
}

const digest = (s: string): Buffer => createHash("sha256").update(s, "utf8").digest();

/**
 * Issued OAuth states. A state is random, bound to the browser by an HttpOnly cookie, expires
 * after `ttlMs`, and is single use: consume() deletes it whether or not the check passes.
 */
export class OAuthStateStore {
  private readonly issued = new Map<string, number>();

  constructor(private readonly ttlMs = 10 * 60 * 1000) {}

  issue(now: number): string {
    for (const [s, at] of this.issued) if (now - at > this.ttlMs) this.issued.delete(s);
    const state = randomBytes(32).toString("hex");
    this.issued.set(state, now);
    return state;
  }

  /** True only when the query state equals the cookie state and was issued here, unexpired. */
  consume(cookieState: string | null, queryState: string | null, now: number): boolean {
    if (!cookieState || !queryState) return false;
    const issuedAt = this.issued.get(cookieState);
    this.issued.delete(cookieState);
    if (issuedAt === undefined || now - issuedAt > this.ttlMs) return false;
    return timingSafeEqual(digest(cookieState), digest(queryState));
  }
}

export type JoinRedemption =
  | { ok: true; entry: Record<string, unknown> }
  | { ok: false; reason: "unknown" | "used" };

/** Marks a join token used (mutating `tokens`), refusing unknown or already-used tokens. */
export function redeemJoinToken(
  tokens: Array<Record<string, unknown>>,
  token: string,
  nowIso: string,
): JoinRedemption {
  const entry = token ? tokens.find((t) => t.token === token) : undefined;
  if (!entry) return { ok: false, reason: "unknown" };
  if (entry.used === true) return { ok: false, reason: "used" };
  entry.used = true;
  entry.used_at = nowIso;
  return { ok: true, entry };
}
