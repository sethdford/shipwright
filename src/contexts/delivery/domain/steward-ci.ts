/**
 * CI triage for the PR steward (ADR-0017): which failed checks are the change's fault and worth a
 * fix round, which are infrastructure (rerun once, never "fixed" by editing code), and which also
 * fail on the base commit (not this PR's doing). Pure: check runs and log text come in as data.
 */

export type CheckState = "pending" | "passed" | "failed" | "neutral";

/** One check run (or commit status) on a commit, as GitHub reports it. */
export interface CheckRun {
  readonly name: string;
  /** queued | in_progress | completed (commit statuses map pending/success/failure onto these). */
  readonly status: string;
  /** success | failure | neutral | cancelled | skipped | timed_out | action_required | stale | startup_failure | null */
  readonly conclusion: string | null;
  /** The Actions job id when the check is an Actions job (logs and rerun); otherwise null. */
  readonly jobId: number | null;
  /** The app that reported it (github-actions, a status context, ...): two apps may share a name. */
  readonly app?: string;
}

export type FailureKind = "code" | "infra" | "baseline";

export interface CheckFailure {
  readonly name: string;
  readonly kind: FailureKind;
  readonly jobId: number | null;
  /** Stable across rounds while the same error repeats: "<check>: <last error line, normalized>". */
  readonly signature: string;
  /** The log lines that explain the failure (empty when no log could be read). */
  readonly excerpt: string;
}

const FAILED = new Set(["failure", "timed_out", "startup_failure"]);
const NEUTRAL = new Set(["success", "neutral", "skipped"]);

export function checkState(run: CheckRun): CheckState {
  if (run.status !== "completed") return "pending";
  // action_required: a workflow waits for someone's approval. No fix round can do that, so it
  // holds the PR like a running check until the stage times out.
  if (run.conclusion === null || run.conclusion === "action_required") return "pending";
  if (NEUTRAL.has(run.conclusion)) return run.conclusion === "success" ? "passed" : "neutral";
  // cancelled and stale: superseded or stopped by someone; neither proves the code wrong.
  if (run.conclusion === "cancelled" || run.conclusion === "stale") return "neutral";
  return FAILED.has(run.conclusion) ? "failed" : "neutral";
}

/** Log text that means the runner, network, quota or credentials failed, not the change. */
const INFRA_PATTERNS: readonly RegExp[] = [
  /runner has received a shutdown signal/i,
  /lost communication with the server/i,
  /no space left on device/i,
  /rate limit/i,
  /\b(ECONNRESET|ETIMEDOUT|ECONNREFUSED|EAI_AGAIN)\b/,
  /could not resolve host/i,
  /\b(502|503|504) (bad gateway|service unavailable|gateway time-?out)/i,
  /the operation was canceled/i,
  /bad credentials|resource not accessible by integration/i,
  /secret .* (is )?not set|token not set|missing (required )?secret/i,
  /the job was not started because/i,
  /exceeded the maximum execution time/i,
];

export function isInfraLog(log: string): boolean {
  return INFRA_PATTERNS.some((p) => p.test(log));
}

// biome-ignore lint/suspicious/noControlCharactersInRegex: ANSI escapes are what this strips
const ANSI = /\u001b\[[0-9;]*[A-Za-z]/g;
const STAMP = /^\d{4}-\d\d-\d\dT[\d:.]+Z\s?/;

/**
 * Actions log lines without timestamps, colour codes, or the step scripts and environment that
 * Actions echoes inside each `##[group]Run …` block: those quote the workflow's own text ("token
 * not set", "failed"), which would otherwise read as the failure.
 */
export function cleanLog(log: string): string[] {
  const out: string[] = [];
  // Lines of an echoed step script, held until ##[endgroup] confirms it. A group the log never
  // closes (a test can print the opener) is kept, so it cannot hide the rest of the log.
  let held: string[] | null = null;
  for (const raw of log.replace(/\r\n?/g, "\n").split("\n")) {
    const l = raw.replace(STAMP, "").replace(ANSI, "").trimEnd();
    if (l.startsWith("##[group]Run ")) {
      if (held) out.push(...held);
      held = [l];
    } else if (held && l.startsWith("##[endgroup]")) held = null;
    else if (held) held.push(l);
    else out.push(l);
  }
  if (held) out.push(...held);
  return out;
}

const ERROR_LINE =
  /##\[error\]|\berror\b|\bfail(ed|ure|ing)?\b|✗|✘|\bassert|exception|traceback|panic|not ok \d|expected .* (to|but)/i;
const NOISE = /^(##\[(group|endgroup)\]|\s*$)/;
/** The runner's closing line says nothing about which error it was. */
const GENERIC = /process completed with exit code \d+/i;

/**
 * The lines around errors, at most `maxLines` lines and `maxChars` characters, newest errors kept
 * (the end of a log is where the failure is). Falls back to the log's tail.
 */
export function failureExcerpt(log: string, maxLines = 80, maxChars = 6000): string {
  const lines = cleanLog(log).filter((l) => !NOISE.test(l));
  const keep = new Set<number>();
  lines.forEach((l, i) => {
    if (!ERROR_LINE.test(l)) return;
    for (let j = Math.max(0, i - 3); j <= Math.min(lines.length - 1, i + 3); j++) keep.add(j);
  });
  const picked = keep.size > 0 ? [...keep].sort((a, b) => a - b).map((i) => lines[i] ?? "") : lines;
  const tail = picked.slice(-maxLines).join("\n");
  return tail.length > maxChars ? tail.slice(tail.length - maxChars) : tail;
}

/**
 * "<check>: <last error line>", numbers and hashes blurred. The last one, like the excerpt: an
 * early harmless "error" line would make every round look the same and stop the steward early.
 */
export function failureSignature(name: string, log: string): string {
  const errors = cleanLog(log).filter(
    (l) => ERROR_LINE.test(l) && !NOISE.test(l) && !GENERIC.test(l),
  );
  const last = errors[errors.length - 1] ?? "";
  const norm = last
    .replace(/\b[0-9a-f]{7,40}\b/gi, "#")
    .replace(/\d+(\.\d+)?/g, "N")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 160);
  return `${name}: ${norm}`;
}

export interface FailedCheckInput {
  readonly run: CheckRun;
  /** The job log, or "" when it could not be read. */
  readonly log: string;
}

/**
 * Classifies each failed check. `baseFailing` names checks that also fail on the PR's base commit:
 * those are not this change's fault, so a fix round would only widen the diff.
 */
export function triageFailures(
  failed: readonly FailedCheckInput[],
  baseFailing: ReadonlySet<string>,
): CheckFailure[] {
  return failed.map(({ run, log }) => {
    const kind: FailureKind = baseFailing.has(run.name)
      ? "baseline"
      : run.conclusion === "timed_out" ||
          run.conclusion === "startup_failure" ||
          isInfraLog(failureExcerpt(log))
        ? "infra"
        : "code";
    return {
      name: run.name,
      kind,
      jobId: run.jobId,
      signature: failureSignature(run.name, log),
      excerpt: failureExcerpt(log),
    };
  });
}

export interface ChecksSummary {
  readonly total: number;
  readonly pending: number;
  readonly passed: number;
  readonly failed: number;
}

/**
 * One run per (app, check name): the first GitHub listed (it lists the newest first). Keyed by app
 * too, so a passing check from one app cannot hide a failing one with the same name from another.
 */
export function latestRuns(runs: readonly CheckRun[]): CheckRun[] {
  const latest = new Map<string, CheckRun>();
  for (const r of runs) {
    const key = `${r.app ?? ""}\u0000${r.name}`;
    if (!latest.has(key)) latest.set(key, r);
  }
  return [...latest.values()];
}

/** Counts by state, one run per check name. */
export function summarizeChecks(runs: readonly CheckRun[]): ChecksSummary {
  const states = latestRuns(runs).map(checkState);
  const count = (s: CheckState) => states.filter((x) => x === s).length;
  return {
    total: states.length,
    pending: count("pending"),
    passed: count("passed"),
    failed: count("failed"),
  };
}
