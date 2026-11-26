import { type BenchRow, latestRows } from "./row";

/**
 * One arm's graded runs in the `shipwright eval` results format (#8735), so `eval ratchet` can
 * compare two arms. Unknown cost becomes 0 there (the format needs a number); `unknownCost`
 * counts those runs so the caller can say so.
 */
export function toEvalResults(rows: readonly BenchRow[], armId: string) {
  const graded = latestRows(rows).filter(
    (r) => r.armId === armId && (r.resolved !== null || r.status !== "ok"),
  );
  return {
    results: {
      policy: armId,
      runs: graded.map((r) => ({
        case: r.taskId,
        pass: r.resolved === true,
        costUsd: r.costUsd ?? 0,
      })),
    },
    unknownCost: graded.filter((r) => r.costUsd === null).length,
  };
}
