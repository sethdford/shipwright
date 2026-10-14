import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import {
  fakeSafetyPorts,
  fixedCosts,
  fixedLabel,
  fixedPulls,
  fixedRuns,
  NOW,
  RecordingGithubWriter,
} from "../../../testing/fake-safety-ports";
import type { RunRecord } from "../domain/breaker";
import type { SafetyPorts } from "../ports";
import { checkDispatchGates } from "./gates";

const open = { github: true, retry: 0 };
const failures: RunRecord[] = [0, 1, 2, 3, 4].map((i) => ({
  id: `r${i}`,
  startedAt: NOW - 600_000,
  finished: { at: NOW - 60_000 * (5 - i), outcome: "failure" },
}));
const running = (id: string): RunRecord => ({ id, startedAt: NOW - 1000, finished: null });
const succeeded = (id: string): RunRecord => ({
  id,
  startedAt: NOW - 600_000,
  finished: { at: NOW - 60_000, outcome: "success" },
});

test("all gates open: every gate is reported, in order", async () => {
  const r = await checkDispatchGates(fakeSafetyPorts(), open);
  expect(r.allowed).toBe(true);
  expect(r.results).toEqual([
    { gate: "pause", verdict: "allowed", detail: "not paused" },
    { gate: "breaker", verdict: "allowed", detail: "closed (0 of the last 0 runs failed)" },
    {
      gate: "budget",
      verdict: "allowed",
      detail: "no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
    },
    {
      gate: "review_wip",
      verdict: "allowed",
      detail: "0 agent PRs awaiting review + 0 runs in flight (limit 5)",
    },
    { gate: "fix_loop", verdict: "allowed", detail: "first dispatch (retry 0 of 3)" },
  ]);
});

test("stops at the first closed gate; a paused system writes no incident", async () => {
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({
    github,
    pauseLabel: fixedLabel(ok([3])),
    runs: fixedRuns(ok(failures)),
  });
  const r = await checkDispatchGates(ports, open);
  expect(r).toEqual({
    allowed: false,
    results: [{ gate: "pause", verdict: "blocked", detail: "label shipwright:pause on #3" }],
  });
  expect(github.calls).toHaveLength(0);
});

test("an open breaker blocks and ensures the incident", async () => {
  const github = new RecordingGithubWriter();
  const r = await checkDispatchGates(
    fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) }),
    open,
  );
  expect(r.allowed).toBe(false);
  expect(r.results.map((g) => [g.gate, g.verdict])).toEqual([
    ["pause", "allowed"],
    ["breaker", "blocked"],
  ]);
  expect(github.calls).toHaveLength(1);
});

test("an open breaker whose incident write failed says so", async () => {
  const github = new RecordingGithubWriter(err({ kind: "failed", message: "boom" }));
  const r = await checkDispatchGates(
    fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) }),
    open,
  );
  expect(r.results.at(-1)?.verdict).toBe("blocked");
  expect(r.results.at(-1)?.detail).toEndWith("; incident not recorded: boom");
});

test("an indeterminate breaker is an error, not a pass", async () => {
  const unfinished = Array.from({ length: 50 }, (_, i) => running(`q${i}`));
  const r = await checkDispatchGates(fakeSafetyPorts({ runs: fixedRuns(ok(unfinished)) }), open);
  expect(r.allowed).toBe(false);
  expect(r.results.at(-1)).toMatchObject({ gate: "breaker", verdict: "error" });
  expect(r.results.at(-1)?.detail).toContain("breaker indeterminate");
});

test("budget, review WIP and the fix-loop cap each block", async () => {
  const today = Math.floor(NOW / 1000);
  const broke = fakeSafetyPorts({
    costs: fixedCosts({ limitUsd: 1 }, [{ costUsd: 1, atEpochS: today }]),
  });
  expect((await checkDispatchGates(broke, open)).results.at(-1)).toMatchObject({
    gate: "budget",
    verdict: "blocked",
  });
  const pr = { author: "app/github-actions", labels: [], draft: false, approved: false };
  const busy = fakeSafetyPorts({
    pulls: fixedPulls(ok([1, 2, 3, 4, 5].map((number) => ({ number, ...pr })))),
  });
  expect((await checkDispatchGates(busy, open)).results.at(-1)).toMatchObject({
    gate: "review_wip",
    verdict: "blocked",
  });
  const fourth = await checkDispatchGates(fakeSafetyPorts(), { github: true, retry: 4 });
  expect(fourth.allowed).toBe(false);
  expect(fourth.results.at(-1)).toEqual({
    gate: "fix_loop",
    verdict: "blocked",
    detail: "retry 4 exceeds the cap of 3",
  });
  const third = await checkDispatchGates(fakeSafetyPorts(), { github: true, retry: 3 });
  expect(third.allowed).toBe(true);
  expect(third.results.at(-1)?.detail).toBe("retry 3 of 3");
});

test.each([[-1], [1.5], [Number.NaN]])("an invalid retry count %p is an error", async (retry) => {
  const r = await checkDispatchGates(fakeSafetyPorts(), { github: true, retry });
  expect(r.allowed).toBe(false);
  expect(r.results.at(-1)).toMatchObject({ gate: "fix_loop", verdict: "error" });
});

test("runs in flight count toward review WIP", async () => {
  const pr = { author: "app/github-actions", labels: [], draft: false, approved: false };
  const ports = fakeSafetyPorts({
    pulls: fixedPulls(ok([1, 2, 3].map((number) => ({ number, ...pr })))),
    runs: fixedRuns(ok([running("a"), running("b"), succeeded("c")])),
  });
  const r = await checkDispatchGates(ports, open);
  expect(r.results.at(-1)).toEqual({
    gate: "review_wip",
    verdict: "blocked",
    detail: "3 agent PRs awaiting review + 2 runs in flight (limit 5)",
  });
});

test("review WIP cannot verify when every fetched run is unfinished", async () => {
  const ports = fakeSafetyPorts({ runs: fixedRuns(ok([running("a"), running("b")])) });
  const r = await checkDispatchGates(ports, open);
  expect(r.allowed).toBe(false);
  expect(r.results.at(-1)).toEqual({
    gate: "review_wip",
    verdict: "error",
    detail: "cannot verify: all 2 fetched runs are unfinished, so the in-flight count is unknown",
  });
});

test("a source that cannot be read closes its gate", async () => {
  const runs = fixedRuns(err({ kind: "auth", message: "HTTP 401" }));
  const r = await checkDispatchGates(fakeSafetyPorts({ runs }), open);
  expect(r.results.at(-1)).toEqual({
    gate: "breaker",
    verdict: "error",
    detail: "cannot verify (auth): HTTP 401",
  });
  const pulls = fixedPulls(err({ kind: "failed", message: "more than 200 open PRs" }));
  const p = await checkDispatchGates(fakeSafetyPorts({ pulls }), open);
  expect(p.results.at(-1)).toEqual({
    gate: "review_wip",
    verdict: "error",
    detail: "cannot verify (failed): more than 200 open PRs",
  });
});

test("a port that throws closes its gate and stops", async () => {
  const ports: SafetyPorts = {
    ...fakeSafetyPorts(),
    costs: {
      read: () => {
        throw new Error("disk on fire");
      },
    },
  };
  const r = await checkDispatchGates(ports, open);
  expect(r.allowed).toBe(false);
  expect(r.results.at(-1)).toEqual({
    gate: "budget",
    verdict: "error",
    detail: "cannot verify: disk on fire",
  });
});

test("no cost data passes with a warning", async () => {
  const costs = { read: async () => ok({ budget: null, entries: [], present: false }) };
  const r = await checkDispatchGates(fakeSafetyPorts({ costs }), open);
  expect(r.allowed).toBe(true);
  expect(r.results[2]).toEqual({
    gate: "budget",
    verdict: "allowed",
    warning: true,
    detail: "no cost data (no budget.json or costs.json found); budget not enforced",
  });
});

test("without GitHub only the local gates run", async () => {
  const fail = err({ kind: "auth" as const, message: "no gh" });
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({
    github,
    runs: fixedRuns(fail),
    pulls: fixedPulls(fail),
    pauseLabel: fixedLabel(fail),
  });
  const r = await checkDispatchGates(ports, { github: false, retry: 2 });
  expect(r.allowed).toBe(true);
  expect(r.results.map((g) => [g.gate, g.verdict, g.detail])).toEqual([
    ["pause", "allowed", "not paused"],
    ["breaker", "skipped", "skipped (no GitHub)"],
    [
      "budget",
      "allowed",
      "no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
    ],
    ["review_wip", "skipped", "skipped (no GitHub)"],
    ["fix_loop", "allowed", "retry 2 of 3"],
  ]);
  expect(github.calls).toHaveLength(0);
});
