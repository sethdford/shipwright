import { extractFeatures, type IssueKind, type Tier } from "./features";
import type { RoutedRun, RoutingDecision } from "./records";
import { ROUTING_V1 } from "./routes";

let seq = 0;

/** A finished run in bucket kind/prior, for history tests. */
export function run(
  kind: IssueKind,
  prior: Tier,
  result: "success" | "failure",
  extra: { failureClass?: string; costUsd?: number; mode?: "shadow" | "apply"; tier?: Tier } = {},
): RoutedRun {
  const route = ROUTING_V1[extra.tier ?? prior];
  seq += 1;
  const id = `d-${seq}`;
  const decision: RoutingDecision = {
    kind: "decision",
    schema: 1,
    id,
    at: "2026-11-26T00:00:00.000Z",
    policy: "routing-v1",
    mode: extra.mode ?? "shadow",
    inputs: {
      features: { ...extractFeatures({ title: "", body: "", labels: [] }), kind },
      overrides: {},
    },
    difficulty: { score: 50, prior, tier: extra.tier ?? prior, reasons: [] },
    route,
    applied: { ...route },
    adjustments: [],
    action: "build",
  };
  return {
    decision,
    outcome: {
      kind: "outcome",
      schema: 1,
      decisionId: id,
      at: "2026-11-26T01:00:00.000Z",
      result,
      ...(extra.failureClass === undefined ? {} : { failureClass: extra.failureClass }),
      ...(extra.costUsd === undefined ? {} : { costUsd: extra.costUsd }),
    },
  };
}
