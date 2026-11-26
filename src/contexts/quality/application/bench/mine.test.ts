import { expect, test } from "bun:test";
import { err, ok } from "../../../../shared/kernel/result";
import type { MergedPull } from "../../domain/bench";
import type { HoldoutSource } from "../../ports";
import { mineHoldout } from "./mine";

const pull = (number: number, files: string[], body = `Fixes #${number + 100}`): MergedPull => ({
  number,
  title: "t",
  body,
  author: "dev",
  mergedAtMs: 0,
  baseSha: "a".repeat(40),
  mergeSha: "b".repeat(40),
  files,
});

const DIFF =
  "diff --git a/src/x.ts b/src/x.ts\n+fix\ndiff --git a/src/x.test.ts b/src/x.test.ts\n+test\n";

function source(pulls: MergedPull[]): HoldoutSource {
  return {
    mergedSince: async () => ok(pulls),
    issue: async (n) =>
      n === 103
        ? err({ kind: "not_found", message: "gone" })
        : ok({ title: `Issue ${n}`, body: "It breaks", createdAt: "2026-11-01" }),
    diff: async () => ok(DIFF),
  };
}

test("eligible PRs become holdout tasks with the test diff as the hidden oracle", async () => {
  const pulls = [
    pull(1, ["src/x.ts", "src/x.test.ts"]),
    pull(2, ["src/x.ts"]),
    pull(3, ["src/x.ts", "src/x.test.ts"]),
  ];
  const req = {
    repo: "https://github.com/o/r",
    sinceMs: 0,
    maxPulls: 10,
    setup: [["bun", "install"]],
  };
  const r = await mineHoldout(req, source(pulls));
  if (!r.ok) throw new Error("mining failed");
  expect(r.value.tasks).toHaveLength(1);
  expect(r.value.tasks[0]).toMatchObject({
    id: "pr-1",
    suite: "holdout",
    problem: "# Issue 101\n\nIt breaks",
    testPatch: "diff --git a/src/x.test.ts b/src/x.test.ts\n+test\n",
    testCommands: [["bun", "test", "./src/x.test.ts"]],
    goldCommit: "b".repeat(40),
    setup: [["bun", "install"]],
  });
  expect(r.value.rejected.map((x) => x.pull)).toEqual([2, 3]);
});

test("a source failure is returned, not swallowed", async () => {
  const failing: HoldoutSource = {
    ...source([]),
    mergedSince: async () => err({ kind: "auth", message: "login" }),
  };
  const req = { repo: "/r", sinceMs: 0, maxPulls: 1, setup: [] };
  expect((await mineHoldout(req, failing)).ok).toBe(false);
});
