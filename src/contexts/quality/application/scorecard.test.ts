import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import type { PullRecord } from "../domain/scorecard";
import type { QualityPorts } from "../ports";
import { buildScorecard } from "./scorecard";

const NOW = Date.UTC(2026, 10, 26);
const DAY = 86_400_000;

const merged: PullRecord = {
  number: 1,
  title: "fix",
  body: "",
  headRef: "ci/issue-1",
  labels: [],
  createdAtMs: NOW - 2 * DAY,
  mergedAtMs: NOW - DAY,
  closedAtMs: NOW - DAY,
  commits: [],
};

const human = [{ identities: ["sethdford"], atMs: NOW - 2 * DAY }];

function ports(
  over: Partial<QualityPorts> = {},
): QualityPorts & { since: number[]; asked: number[] } {
  const since: number[] = [];
  const asked: number[] = [];
  const abandoned = { ...merged, number: 2, mergedAtMs: null };
  return {
    since,
    asked,
    now: () => NOW,
    pulls: {
      closedSince: async (ms) => {
        since.push(ms);
        return ok({ pulls: [merged, abandoned], truncated: false });
      },
      commits: async (pr) => {
        asked.push(pr);
        return ok(human);
      },
    },
    spend: { between: async () => ok(3) },
    ...over,
  };
}

test("reads the window's PRs and spend and computes the card", async () => {
  const p = ports();
  const r = await buildScorecard(p, { windowDays: 7 });
  expect(p.since).toEqual([NOW - 7 * DAY]);
  expect(p.asked).toEqual([1]);
  expect(r.ok && r.value).toMatchObject({
    truncated: false,
    card: { windowDays: 7, merged: 1, reworked: 1, spendUsd: 3, costPerMergeUsd: 3 },
  });
});

test("passes truncation through", async () => {
  const pulls = {
    closedSince: async () => ok({ pulls: [], truncated: true }),
    commits: async () => ok([]),
  };
  const r = await buildScorecard(ports({ pulls }));
  expect(r.ok && r.value.truncated).toBe(true);
});

test("an unreadable source is an error, never an empty card", async () => {
  const failed = { kind: "failed" as const, message: "boom" };
  const pulls = { closedSince: async () => err(failed), commits: async () => ok([]) };
  expect((await buildScorecard(ports({ pulls }))).ok).toBe(false);
  const base = ports();
  const commits = { ...base.pulls, commits: async () => err(failed) };
  expect((await buildScorecard(ports({ pulls: commits }))).ok).toBe(false);
  const spend = { between: async () => err(failed) };
  expect((await buildScorecard(ports({ spend }))).ok).toBe(false);
});
