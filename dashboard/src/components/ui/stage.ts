// Human labels for pipeline stage ids (design/tokens.ts STAGES), for copy such as
// "The run is in the Compound quality stage."

import type { StageName } from "../../design/tokens";

const STAGE_LABELS: Record<StageName, string> = {
  intake: "Intake",
  plan: "Plan",
  design: "Design",
  build: "Build",
  test: "Test",
  review: "Review",
  compound_quality: "Compound quality",
  pr: "Pull request",
  merge: "Merge",
  deploy: "Deploy",
  monitor: "Monitor",
};

/** The label for a stage id; an unknown id is shown as given rather than guessed. */
export function stageLabel(id: string): string {
  return STAGE_LABELS[id as StageName] ?? id;
}
