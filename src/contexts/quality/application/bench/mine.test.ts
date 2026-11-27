import { expect, test } from "bun:test";
import { err, ok } from "../../../../shared/kernel/result";
import type { DirectCommit, MergedPull } from "../../domain/bench";
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

const commit = (sha: string, files: string[]): DirectCommit => ({
  sha: sha.repeat(40),
  parentSha: "a".repeat(40),
  message: "fix(x): handle the empty case\n\nlong body",
  author: "dev",
  committedAtMs: Date.parse("2026-10-01T00:00:00Z"),
  files,
});

function source(pulls: MergedPull[], commits: DirectCommit[] = []): HoldoutSource {
  return {
    mergedSince: async () => ok(pulls),
    commitsSince: async () => ok(commits),
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
  expect(r.value.rejected.map((x) => x.ref)).toEqual(["#2", "#3"]);
});

test("a source failure is returned, not swallowed", async () => {
  const failing: HoldoutSource = {
    ...source([]),
    mergedSince: async () => err({ kind: "auth", message: "login" }),
  };
  const req = { repo: "/r", sinceMs: 0, maxPulls: 1, setup: [] };
  expect((await mineHoldout(req, failing)).ok).toBe(false);
});

const STATEMENT = "Running x on an empty list crashes instead of returning nothing.";

test("a PR with no linked issue is mined when its problem is curated", async () => {
  const req = { repo: "/r", sinceMs: 0, maxPulls: 5, setup: [], problems: { "pr-4": STATEMENT } };
  const pulls = [
    pull(4, ["src/x.ts", "src/x.test.ts"], "no link"),
    pull(5, ["src/x.ts", "src/x.test.ts"], "no link"),
  ];
  const r = await mineHoldout(req, source(pulls));
  if (!r.ok) throw new Error("mining failed");
  expect(r.value.tasks.map((t) => [t.id, t.problem])).toEqual([["pr-4", STATEMENT]]);
  expect(r.value.rejected).toEqual([{ ref: "#5", reason: "closes no issue" }]);
});

test("commits become tasks only with a curated problem; the rest are listed to curate", async () => {
  const commits = [
    commit("c", ["src/x.ts", "src/x.test.ts"]),
    commit("d", ["src/x.ts", "src/x.test.ts"]),
  ];
  const req = {
    repo: "/r",
    sinceMs: 0,
    maxPulls: 5,
    setup: [],
    from: "commits" as const,
    problems: { "c-cccccccccc": STATEMENT },
  };
  const r = await mineHoldout(req, source([], commits));
  if (!r.ok) throw new Error("mining failed");
  expect(r.value.tasks).toHaveLength(1);
  expect(r.value.tasks[0]).toMatchObject({
    id: "c-cccccccccc",
    problem: STATEMENT,
    baseCommit: "a".repeat(40),
    goldCommit: "c".repeat(40),
    testPatch: "diff --git a/src/x.test.ts b/src/x.test.ts\n+test\n",
    createdAt: "2026-10-01T00:00:00.000Z",
  });
  expect(r.value.rejected).toEqual([
    { ref: "ddddddd", reason: "needs a curated problem: fix(x): handle the empty case" },
  ]);
});
