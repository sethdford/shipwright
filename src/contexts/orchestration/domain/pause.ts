// Kill switch (spec §6.2): a local pause flag (shared with the bash daemon) or the
// `shipwright:pause` label on any open issue stops dispatch everywhere.

export const PAUSE_LABEL = "shipwright:pause";

export interface LocalPause {
  readonly reason: string;
  /** ISO timestamp when the flag was set; empty when unknown. */
  readonly since: string;
  /** Epoch ms after which the flag no longer pauses (the daemon's failure backoff); null = never. */
  readonly resumeAfter: number | null;
}

export interface PauseStatus {
  readonly paused: boolean;
  readonly reasons: readonly string[];
}

const MAX_REASON = 200;

/** Reasons reach terminals and logs: drop control characters (ESC, NUL, newlines) and cap length. */
export function sanitizeReason(reason: string): string {
  // biome-ignore lint/suspicious/noControlCharactersInRegex: stripping control characters is the point
  return reason.replace(/[\x00-\x1f\x7f]/g, "").slice(0, MAX_REASON);
}

/**
 * `labelled` is null only in no-GitHub mode (label not checked); callers must never map a gh
 * error to null.
 */
export function pauseStatus(
  flag: LocalPause | null,
  labelled: readonly number[] | null,
  now: number,
): PauseStatus {
  const reasons: string[] = [];
  if (flag && (flag.resumeAfter === null || now < flag.resumeAfter)) {
    const since = flag.since ? ` (since ${flag.since})` : "";
    reasons.push(`local pause flag: ${sanitizeReason(flag.reason)}${since}`);
  }
  if (labelled && labelled.length > 0) {
    reasons.push(`label ${PAUSE_LABEL} on ${labelled.map((n) => `#${n}`).join(", ")}`);
  }
  return { paused: reasons.length > 0, reasons };
}
