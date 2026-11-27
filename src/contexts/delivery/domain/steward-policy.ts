/**
 * The PR steward's state machine (ADR-0017). After a PR opens, each round reads the PR and picks
 * one action:
 *
 *   fix    a check failed because of the change, or a trusted reviewer asked for something:
 *          run one fix round (through the patch handoff), push, reply
 *   rerun  only infrastructure failures: re-run those jobs once
 *   wait   checks still running and nothing to fix yet
 *   done   checks green (failures that also fail on the base do not count) and nothing to answer
 *   stop   the PR is closed, the round limit is reached, or a fix made no progress
 *
 * Guards are pure functions of the observed PR and the steward's own history.
 */
import type { CheckFailure, ChecksSummary } from "./steward-ci";
import type { ActionableComment } from "./steward-reviews";

export type StewardAction = "fix" | "rerun" | "wait" | "done" | "stop";

export interface StewardHistory {
  /** Fix rounds already run on this PR. */
  readonly rounds: number;
  /** Failure signatures each earlier fix round targeted, oldest first. */
  readonly fixedSignatures: readonly (readonly string[])[];
  /**
   * Check names already re-run once. Names, not job ids: a re-run gives the job a new id, so ids
   * would let the same flaky check be re-run every round.
   */
  readonly rerunChecks: readonly string[];
  /** Comment id -> fix rounds that included it without the fixer reporting it handled. */
  readonly commentAttempts: Readonly<Record<string, number>>;
}

export const EMPTY_HISTORY: StewardHistory = {
  rounds: 0,
  fixedSignatures: [],
  rerunChecks: [],
  commentAttempts: {},
};

export interface StewardLimits {
  /** Fix rounds per PR (default 3). */
  readonly maxRounds: number;
  /** Rounds that may target the same failure signature before the steward gives up (default 2). */
  readonly maxSameFailure: number;
  /** Rounds a comment may be offered to the fixer (default 2). */
  readonly maxCommentAttempts: number;
}

export const DEFAULT_LIMITS: StewardLimits = {
  maxRounds: 3,
  maxSameFailure: 2,
  maxCommentAttempts: 2,
};

export interface StewardObservation {
  readonly prState: "open" | "closed" | "merged";
  /** The PR's branch is in a fork: never the pipeline's own PR, so the steward does not act. */
  readonly fork?: boolean;
  /** The caller has waited its grace period: no checks now means the PR has no CI, not "not yet". */
  readonly noChecksOk?: boolean;
  readonly checks: ChecksSummary;
  readonly failures: readonly CheckFailure[];
  readonly comments: readonly ActionableComment[];
}

export interface StewardDecision {
  readonly action: StewardAction;
  readonly reason: string;
  /** For fix: the failures and comments the round should address. */
  readonly fixFailures: readonly CheckFailure[];
  readonly fixComments: readonly ActionableComment[];
  /** For rerun: Actions job ids to re-run, and their check names (recorded in the history). */
  readonly rerunJobs: readonly number[];
  readonly rerunChecks: readonly string[];
}

const decision = (
  action: StewardAction,
  reason: string,
  extra: Partial<Omit<StewardDecision, "action" | "reason">> = {},
): StewardDecision => ({
  action,
  reason,
  fixFailures: extra.fixFailures ?? [],
  fixComments: extra.fixComments ?? [],
  rerunJobs: extra.rerunJobs ?? [],
  rerunChecks: extra.rerunChecks ?? [],
});

function timesTargeted(signature: string, history: StewardHistory): number {
  return history.fixedSignatures.filter((round) => round.includes(signature)).length;
}

/** Code failures still worth a round, and those the steward has given up on. */
function splitCodeFailures(
  obs: StewardObservation,
  history: StewardHistory,
  limits: StewardLimits,
) {
  const code = obs.failures.filter((f) => f.kind === "code");
  const stuck = code.filter((f) => timesTargeted(f.signature, history) >= limits.maxSameFailure);
  return { fixable: code.filter((f) => !stuck.includes(f)), stuck };
}

function openComments(obs: StewardObservation, history: StewardHistory, limits: StewardLimits) {
  return obs.comments.filter(
    (c) => (history.commentAttempts[String(c.id)] ?? 0) < limits.maxCommentAttempts,
  );
}

const names = (fs: readonly CheckFailure[]): string => fs.map((f) => f.name).join(", ");

export function decideNext(
  obs: StewardObservation,
  history: StewardHistory,
  limits: StewardLimits = DEFAULT_LIMITS,
): StewardDecision {
  if (obs.prState === "merged") return decision("done", "the PR is merged");
  if (obs.prState === "closed") return decision("stop", "the PR was closed");
  if (obs.fork === true)
    return decision("stop", "the PR's branch is in a fork, not this repository");
  const { fixable, stuck } = splitCodeFailures(obs, history, limits);
  const comments = openComments(obs, history, limits);
  if (stuck.length > 0 && fixable.length === 0 && comments.length === 0) {
    return decision(
      "stop",
      `no progress after ${limits.maxSameFailure} fix rounds: ${names(stuck)}`,
    );
  }
  if (fixable.length > 0 || comments.length > 0) {
    if (history.rounds >= limits.maxRounds) {
      return decision("stop", `fix round limit (${limits.maxRounds}) reached`);
    }
    const why = [
      fixable.length > 0 ? `${fixable.length} failing check(s): ${names(fixable)}` : "",
      comments.length > 0 ? `${comments.length} review comment(s)` : "",
    ].filter(Boolean);
    return decision("fix", why.join("; "), { fixFailures: fixable, fixComments: comments });
  }
  return decideWithoutFix(obs, history);
}

function decideWithoutFix(obs: StewardObservation, history: StewardHistory): StewardDecision {
  const infra = obs.failures.filter((f) => f.kind === "infra");
  const rerun = infra.filter((f) => f.jobId !== null && !history.rerunChecks.includes(f.name));
  if (rerun.length > 0) {
    return decision("rerun", `infrastructure failure(s): ${names(rerun)}`, {
      rerunJobs: rerun.map((f) => f.jobId as number),
      rerunChecks: rerun.map((f) => f.name),
    });
  }
  if (obs.checks.pending > 0)
    return decision("wait", `${obs.checks.pending} check(s) still running`);
  // Right after a push GitHub has not created the new head's checks yet: none is not green.
  if (obs.checks.total === 0 && !obs.noChecksOk)
    return decision("wait", "no checks reported on this commit yet");
  if (infra.length > 0) {
    const why = infra.some((f) => f.jobId === null)
      ? "cannot be re-run here"
      : "persist after a re-run";
    return decision("stop", `infrastructure failure(s) ${why}: ${names(infra)}`);
  }
  const baseline = obs.failures.filter((f) => f.kind === "baseline");
  const note = baseline.length > 0 ? ` (also failing on the base: ${names(baseline)})` : "";
  const green = obs.checks.total === 0 ? "no checks reported (no CI)" : "checks green";
  return decision("done", `${green} and no open review comments${note}`);
}
