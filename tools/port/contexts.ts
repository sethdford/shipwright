export const CONTEXTS = [
  "observability",
  "delivery",
  "orchestration",
  "planning",
  "quality",
  "learning",
  "intelligence",
  "integrations",
  "teams",
  "platform",
] as const;
export type Context = (typeof CONTEXTS)[number];

const RULES: readonly [RegExp, Context][] = [
  [
    /^sw-(status|dora|pipeline-vitals|logs|ps|activity|stream|replay|trace|otel|widgets|dashboard|public-dashboard|mission-control|fleet-viz|heartbeat|stall-detector|instrument|eventbus)\b/,
    "observability",
  ],
  [/^sw-(pipeline|loop|worktree|checkpoint|durable|tmux-pipeline|context)\b/, "delivery"],
  [/^sw-(daemon|fleet|scale|remote|launchd|fix|autonomous|incident)\b/, "orchestration"],
  [/^sw-(triage|decompose|strategic|pm)\b/, "planning"],
  [
    /^sw-(code-review|adversarial|security-audit|testgen|quality|oversight|evidence|architecture|review-rerun|regression|developer-simulation|e2e-orchestrator)\b/,
    "quality",
  ],
  [/^sw-(memory|discovery|guild|self-optimize|adaptive|feedback|retro)\b/, "learning"],
  [/^sw-(intelligence|predictive|model-router|cost|decide)\b/, "intelligence"],
  [/^sw-(github|tracker|jira|linear|webhook|ci|pr-lifecycle|connect|auth|deps)\b/, "integrations"],
  [/^sw-(session|team-stages|swarm|recruit|tmux|reaper|templates|standup)\b/, "teams"],
];

/** Bounded context for a bash script (spec §3.1). Anything unmatched is platform tooling. */
export function contextFor(script: string): Context {
  return RULES.find(([re]) => re.test(script))?.[1] ?? "platform";
}
