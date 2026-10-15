// Flow control (spec §6.2, research decision 11): a review-WIP limit and a fix-loop cap.

export interface PullSummary {
  readonly number: number;
  /**
   * The login as `gh pr list` prints it: `app/<slug>` for a GitHub App (the Actions bot is
   * "app/github-actions"), the plain username for a user. A PR opened with a PAT or a custom app
   * has another author and is counted only through the agent label.
   */
  readonly author: string;
  readonly labels: readonly string[];
  readonly draft: boolean;
  readonly approved: boolean;
}

export interface FlowPolicy {
  /** No dispatch while this many agent PRs await review or are being produced. */
  readonly reviewWipLimit: number;
  /** PRs by these authors are agent PRs. */
  readonly agentAuthors: readonly string[];
  /** PRs with this label (propagated from dispatched issues) are agent PRs. */
  readonly agentLabel: string;
  /** Retries of one issue allowed before it escalates to a human. */
  readonly fixLoopCap: number;
}

/** Rejects a policy that would make the gates meaningless; mirrors `breakerPolicy`. */
export function flowPolicy(policy: FlowPolicy): FlowPolicy {
  if (!Number.isInteger(policy.reviewWipLimit) || policy.reviewWipLimit < 1) {
    throw new Error(`review WIP limit must be an integer >= 1, got ${policy.reviewWipLimit}`);
  }
  if (!Number.isInteger(policy.fixLoopCap) || policy.fixLoopCap < 0) {
    throw new Error(`fix-loop cap must be an integer >= 0, got ${policy.fixLoopCap}`);
  }
  return policy;
}

export const DEFAULT_FLOW_POLICY: FlowPolicy = flowPolicy({
  reviewWipLimit: 5,
  agentAuthors: ["app/github-actions"],
  agentLabel: "shipwright",
  fixLoopCap: 3,
});

export interface WipVerdict {
  readonly allowed: boolean;
  /** Open, non-draft, unapproved agent PRs. */
  readonly awaitingReview: readonly number[];
  /** Pipeline runs queued or running; each may open another PR. */
  readonly inFlight: number;
  readonly limit: number;
}

const isAgentPr = (p: PullSummary, policy: FlowPolicy) =>
  policy.agentAuthors.includes(p.author) ||
  p.labels.some((l) => l.toLowerCase() === policy.agentLabel.toLowerCase());

/**
 * `inFlight` must be the number of pipeline runs with `RunRecord.finished === null`. The caller
 * (Task 11) must also block when every fetched run is unfinished: the history window then cannot
 * show how many more are in flight. An invalid `inFlight` blocks here (unknown is not allowed).
 */
export function reviewWip(
  pulls: readonly PullSummary[],
  inFlight: number,
  policy: FlowPolicy = DEFAULT_FLOW_POLICY,
): WipVerdict {
  const awaitingReview = pulls
    .filter((p) => isAgentPr(p, policy) && !p.draft && !p.approved)
    .map((p) => p.number);
  const known = Number.isSafeInteger(inFlight) && inFlight >= 0;
  const allowed = known && awaitingReview.length + inFlight < policy.reviewWipLimit;
  return { allowed, awaitingReview, inFlight, limit: policy.reviewWipLimit };
}

export function describeWip(v: WipVerdict): string {
  const prs = `${v.awaitingReview.length} agent PRs awaiting review`;
  return `${prs} + ${v.inFlight} runs in flight (limit ${v.limit})`;
}

/**
 * `retry` is the retry number about to be dispatched: 0 for the first dispatch, N for the Nth.
 * Cap 3 allows the original run plus 3 retries. A missing or invalid count is unknown, so blocked.
 */
export function fixLoopAllows(
  retry: number | null | undefined,
  policy: FlowPolicy = DEFAULT_FLOW_POLICY,
): boolean {
  if (retry === null || retry === undefined || !Number.isSafeInteger(retry) || retry < 0) {
    return false;
  }
  return retry <= policy.fixLoopCap;
}
