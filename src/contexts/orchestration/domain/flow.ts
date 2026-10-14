// Flow control (spec §6.2, research decision 11): a review-WIP limit and a fix-loop cap.

export interface PullSummary {
  readonly number: number;
  /** gh login, e.g. "app/github-actions" for the Actions bot. */
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

export const DEFAULT_FLOW_POLICY: FlowPolicy = {
  reviewWipLimit: 5,
  agentAuthors: ["app/github-actions"],
  agentLabel: "shipwright",
  fixLoopCap: 3,
};

export interface WipVerdict {
  readonly allowed: boolean;
  /** Open, non-draft, unapproved agent PRs. */
  readonly awaitingReview: readonly number[];
  /** Pipeline runs queued or running; each may open another PR. */
  readonly inFlight: number;
  readonly limit: number;
}

const isAgentPr = (p: PullSummary, policy: FlowPolicy) =>
  policy.agentAuthors.includes(p.author) || p.labels.includes(policy.agentLabel);

export function reviewWip(
  pulls: readonly PullSummary[],
  inFlight: number,
  policy: FlowPolicy = DEFAULT_FLOW_POLICY,
): WipVerdict {
  const awaitingReview = pulls
    .filter((p) => isAgentPr(p, policy) && !p.draft && !p.approved)
    .map((p) => p.number);
  const allowed = awaitingReview.length + inFlight < policy.reviewWipLimit;
  return { allowed, awaitingReview, inFlight, limit: policy.reviewWipLimit };
}

export function describeWip(v: WipVerdict): string {
  const prs = `${v.awaitingReview.length} agent PRs awaiting review`;
  return `${prs} + ${v.inFlight} runs in flight (limit ${v.limit})`;
}

/** `attempt` is the retry number (1 = first retry); null for a first dispatch. */
export function fixLoopAllows(attempt: number | null, policy: FlowPolicy = DEFAULT_FLOW_POLICY) {
  return attempt === null || attempt <= policy.fixLoopCap;
}
