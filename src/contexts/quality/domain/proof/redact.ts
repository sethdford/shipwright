/**
 * Strips secrets from text before it leaves the machine (ADR-0019). The app runs without
 * credentials, but its own .env files and logs may still print keys, and proof artifacts are
 * pushed to the repository, so every log and transcript passes through here first.
 */

const PATTERNS: readonly RegExp[] = [
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g,
  /\bsk-[A-Za-z0-9]{32,}\b/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bxox[abpors]-[A-Za-z0-9-]{10,}\b/g,
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
  /\b([A-Za-z]+:\/\/)[^\s:@/]+:[^\s@/]+@/g,
];

const ASSIGNMENT =
  /\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|CREDENTIALS?)[A-Z0-9_]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)/gi;

export const REDACTED = "[redacted]";

export function redact(text: string): string {
  let out = text.replace(ASSIGNMENT, (_m, key: string, sep: string) => `${key}${sep}${REDACTED}`);
  for (const p of PATTERNS) {
    out = out.replace(p, (m, scheme?: string) =>
      typeof scheme === "string" && m.endsWith("@") ? `${scheme}${REDACTED}@` : REDACTED,
    );
  }
  return out;
}

/** The last `max` characters, cut at a line start, so a log keeps its most recent lines. */
export function tail(text: string, max: number): string {
  if (text.length <= max) return text;
  const cut = text.slice(text.length - max);
  const nl = cut.indexOf("\n");
  return `…\n${nl >= 0 ? cut.slice(nl + 1) : cut}`;
}
