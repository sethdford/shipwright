import { expect, test } from "bun:test";
import { fakeCritic, fakeVerifierPorts } from "../../../testing/fake-verifier";
import type { FileChange } from "../domain/change-features";
import type { PullRecord } from "../domain/scorecard";
import { type ScoreRequest, scoreCandidate, scoreChange } from "./verifier-score";
import { trainVerifier } from "./verifier-train";

const T = Date.UTC(2026, 9, 1);
const f = (path: string, additions = 20, deletions = 2): FileChange => ({
  path,
  additions,
  deletions,
});

const pull = (number: number, merged: boolean, title: string, body = ""): PullRecord => ({
  number,
  title,
  body,
  headRef: `fix/${number}`,
  labels: [],
  createdAtMs: T,
  mergedAtMs: merged ? T + 1 : null,
  closedAtMs: T + 1,
  commits: [],
});

const FACTORY = "via `shipwright pipeline`";
const pulls = [
  pull(1, false, "Invalid API key · Fix external API key", FACTORY),
  pull(2, false, "The implementation is already complete", FACTORY),
  pull(3, true, "fix(loop): reuse the session", FACTORY),
  pull(4, true, "feat(cli): add --json"),
];
const prFiles = {
  1: [f(".claude/loop-logs/a.log", 20_000), f("scripts/x.sh")],
  2: [f("docs/plans/2026-01-01-plan.md", 80)],
  3: [f("scripts/sw-loop.sh"), f("scripts/sw-loop-test.sh")],
  4: [f("src/cli/status.ts"), f("src/cli/status.test.ts")],
};

test("training labels history, fits, measures leave-one-out, and saves", async () => {
  const ports = fakeVerifierPorts({ pulls, prFiles });
  const r = await trainVerifier(ports, { days: 365, labels: {}, dryRun: false });
  if (!r.ok) throw new Error(r.error.message);
  // The gate is judged on the factory PRs only (#1-#3); #4 is a human PR that only helps the fit.
  expect(r.value.evidence).toMatchObject({ examples: 3, merged: 1, unmerged: 2 });
  expect(r.value.model.source).toBe("trained");
  expect(r.value.examples.map((e) => [e.number, e.agent])).toEqual([
    [1, true],
    [2, true],
    [3, true],
    [4, false],
  ]);
  expect(r.value.loo.n).toBe(4);
  expect(r.value.priorAgent.n).toBe(3);
  expect(r.value.looAgent.n).toBe(3);
  expect(r.value.untrusted).toContain("only 3 labelled PRs");
  expect(ports.saved).toHaveLength(1);
});

test("a dry run saves nothing; a failing file read is an error", async () => {
  const ports = fakeVerifierPorts({ pulls, prFiles });
  const r = await trainVerifier(ports, { days: 365, labels: {}, dryRun: true });
  expect(r.ok && r.value.saved).toBe(false);
  expect(ports.saved).toHaveLength(0);
  const missing = fakeVerifierPorts({ pulls, prFiles: { 1: [] } });
  expect((await trainVerifier(missing, { days: 365, labels: {}, dryRun: true })).ok).toBe(false);
});

const req = (over: Partial<ScoreRequest> = {}): ScoreRequest => ({
  baseRef: "origin/main",
  title: "fix(loop): reuse the session (#12)",
  body: "",
  mode: "enforce",
  signals: { ownTestsPass: true, crossPassRate: null, rubricScore: null },
  critic: null,
  ...over,
});

test("scores a clean change with the prior when nothing was trained", async () => {
  const local = { files: [f("scripts/sw-loop.sh"), f("scripts/sw-loop-test.sh")], patch: "diff" };
  const r = await scoreChange(fakeVerifierPorts({ local }), req());
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.model).toBe("prior");
  expect(r.value.probability).toBeGreaterThan(0.6);
  expect(r.value.decision.verdict).toBe("pass");
  expect(r.value.costUsd).toBe(0);
});

test("blocks a run-output diff in enforce mode, and names the drivers", async () => {
  const local = { files: [f(".claude/loop-state.md", 400)], patch: "" };
  const r = await scoreChange(fakeVerifierPorts({ local }), req());
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.decision.verdict).toBe("block");
  expect(r.value.drivers.map((d) => d.feature)).toContain("noChange");
});

test("the critic is one feature: its probability and concerns are reported and it is paid for", async () => {
  const agent = fakeCritic({
    checks: [{ id: "tests", verdict: "concern", note: "no test covers the new flag" }],
    mergeProbability: 0.1,
  });
  const local = { files: [f("src/a.ts")], patch: "+a" };
  const ports = fakeVerifierPorts({ local, agent });
  const r = await scoreChange(ports, req({ critic: { model: "sonnet", budgetUsd: 0.5 } }));
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.critic).toEqual({
    probability: 0.1,
    concerns: ["tests: no test covers the new flag"],
  });
  expect(r.value.features.critic).toBeLessThan(0);
  expect(r.value.costUsd).toBeCloseTo(0.04);
  expect(agent.requests[0]?.data).toContain("+a");
  expect(agent.requests[0]?.instructions).not.toContain("+a");
});

test("the critic gets the repository model's impact section as data, before the diff", async () => {
  const agent = fakeCritic({ checks: [], mergeProbability: 0.6 });
  const ports = fakeVerifierPorts({ local: { files: [f("src/a.ts")], patch: "+a" }, agent });
  const impact = "## Change impact (repository model)\n- src/a.ts\n    imported by: src/b.ts";
  await scoreChange(ports, req({ critic: { model: "sonnet", budgetUsd: 0.5, impact } }));
  const data = agent.requests[0]?.data ?? "";
  expect(data).toContain("imported by: src/b.ts");
  expect(data.indexOf("Change impact")).toBeLessThan(data.indexOf("## Diff"));
});

test("a failing critic is a note, not an error", async () => {
  const r = await scoreChange(
    fakeVerifierPorts(),
    req({ critic: { model: "sonnet", budgetUsd: 0.5 } }),
  );
  expect(r.ok && r.value.notes).toEqual(["critic: timeout"]);
});

test("scoreCandidate scores a change in hand (the tournament's path) with no git", async () => {
  const r = await scoreCandidate(fakeVerifierPorts(), {
    ...req({ signals: { ownTestsPass: true, crossPassRate: 1, rubricScore: 0.9 } }),
    files: [f("src/a.ts"), f("src/a.test.ts")],
    patch: "",
  });
  expect(r.features.cross).toBe(0.5);
  expect(r.probability).toBeGreaterThan(0.8);
});
