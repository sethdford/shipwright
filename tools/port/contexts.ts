const RULES: readonly [RegExp, string][] = [
  [
    /^sw-(status|dora|pipeline-vitals|logs|ps|activity|stream|replay|trace|otel|widgets|dashboard|public-dashboard|mission-control|fleet-viz|heartbeat|standup|stall-detector|instrument|eventbus)\b/,
    "observability",
  ],
  [/^sw-(pipeline|loop|worktree|checkpoint|durable|tmux-pipeline)\b/, "delivery"],
  [/^sw-(daemon|fleet|scale|remote|launchd|fix)\b/, "orchestration"],
  [/^sw-(triage|decompose|strategic|pm)\b/, "planning"],
  [
    /^sw-(code-review|adversarial|security-audit|testgen|quality|oversight|evidence|architecture|review-rerun|regression|developer-simulation)\b/,
    "quality",
  ],
  [/^sw-(memory|discovery|guild|self-optimize|adaptive|feedback|retro)\b/, "learning"],
  [/^sw-(intelligence|predictive|model-router|cost)\b/, "intelligence"],
  [/^sw-(github|tracker|jira|linear|webhook|ci|pr-lifecycle|connect|auth|deps)\b/, "integrations"],
  [/^sw-(session|team-stages|swarm|recruit|tmux|reaper|templates)\b/, "teams"],
];

/** Bounded context for a bash script (spec §3.1). Anything unmatched is platform tooling. */
export function contextFor(script: string): string {
  return RULES.find(([re]) => re.test(script))?.[1] ?? "platform";
}
