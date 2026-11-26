import { expect, test } from "bun:test";
import { fakeCritic, fakeVerifierPorts } from "../../../testing/fake-verifier";
import { NO_SIGNALS } from "../domain/change-features";
import type { PullRecord } from "../domain/scorecard";
import { scoreChange } from "./verifier-score";
import { trainVerifier } from "./verifier-train";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 10, 26);
const OLD = NOW - 60 * DAY;
const FACTORY = "via `shipwright pipeline`";

const pull = (
  number: number,
  mergedAtMs: number | null,
  sha: string | null = null,
): PullRecord => ({
  number,
  title: `fix(x): change ${number}`,
  body: FACTORY,
  headRef: `ci/issue-${number}`,
  labels: [],
  createdAtMs: (mergedAtMs ?? OLD) - DAY,
  mergedAtMs,
  closedAtMs: mergedAtMs ?? OLD,
  commits: [],
  mergeSha: sha,
});

const lines = (n: number, tag: string) =>
  Array.from({ length: n }, (_, i) => `const ${tag}${i} = ${i};`);
const survival = (kept: number) => ({
  added: new Map([["src/a.ts", lines(10, "v")]]),
  later: new Map([["src/a.ts", lines(kept, "v").join("\n")]]),
});
const files = { path: "src/a.ts", additions: 10, deletions: 0 };

test("training labels merged PRs by what survives, and reports how labels were decided", async () => {
  const ports = fakeVerifierPorts({
    now: NOW,
    pulls: [
      pull(1, OLD, "aaaaaaa1"), // 9 of 10 lines kept
      pull(2, OLD, "aaaaaaa2"), // 2 of 10 kept: rewritten
      pull(3, OLD, "aaaaaaa3"), // not in local history
      pull(4, NOW - 3 * DAY, "aaaaaaa4"), // too recent
      pull(5, null),
    ],
    prFiles: { 1: [files], 2: [files], 3: [files], 4: [files], 5: [files] },
    survival: { aaaaaaa1: survival(9), aaaaaaa2: survival(2) },
  });
  const r = await trainVerifier(ports, { days: 365, labels: {}, dryRun: true });
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.examples.map((e) => [e.number, e.merged, e.basis])).toEqual([
    [1, 1, "survival"],
    [2, 0, "survival"],
    [3, 1, "merge"],
    [4, 1, "merge"],
    [5, 0, "merge"],
  ]);
  expect(r.value.examples[1]?.survival).toBeCloseTo(0.2);
  expect(r.value.labels).toMatchObject({
    outcome: "survival",
    bySurvival: 2,
    rewritten: 1,
    tooRecent: 1,
    unmeasured: 1,
  });
});

test("logged run signals reach training, so the critic feature is no longer always 0", async () => {
  const ports = fakeVerifierPorts({
    now: NOW,
    pulls: [pull(1, OLD), pull(2, null)],
    prFiles: { 1: [files], 2: [files] },
    scores: [
      {
        atMs: OLD - DAY + 1000,
        branch: "ci/issue-1",
        headSha: "abc1234",
        probability: 0.8,
        signals: { ...NO_SIGNALS, ownTestsPass: true, criticProbability: 0.9 },
      },
    ],
  });
  const r = await trainVerifier(ports, { days: 365, labels: { outcome: "merge" }, dryRun: true });
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.labels.withSignals).toBe(1);
  expect(r.value.model.weights.critic).not.toBeCloseTo(1, 6); // moved off the prior
});

test("verify score logs its signals and the critic's chance under the current branch", async () => {
  const critic = fakeCritic({ checks: [], mergeProbability: 0.7 });
  const ports = fakeVerifierPorts({ now: NOW, agent: critic, branch: "ci/issue-9" });
  const r = await scoreChange(ports, {
    baseRef: "origin/main",
    title: "fix: x",
    body: "",
    mode: "advisory",
    signals: { ownTestsPass: true, crossPassRate: null, rubricScore: null },
    critic: { model: "sonnet", budgetUsd: 0.5 },
  });
  if (!r.ok) throw new Error(r.error.message);
  expect(ports.logged).toHaveLength(1);
  expect(ports.logged[0]).toMatchObject({
    atMs: NOW,
    branch: "ci/issue-9",
    signals: { ownTestsPass: true, criticProbability: 0.7 },
  });
});
