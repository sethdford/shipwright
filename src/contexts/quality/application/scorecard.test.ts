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
  createdAtMs: NOW - 2 * DAY,
  mergedAtMs: NOW - DAY,
  closedAtMs: NOW - DAY,
  commits: [],
};

function ports(over: Partial<QualityPorts> = {}): QualityPorts & { since: number[] } {
  const since: number[] = [];
  return {
    since,
    now: () => NOW,
    pulls: {
      closedSince: async (ms) => {
        since.push(ms);
        return ok({ pulls: [merged], truncated: false });
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
  expect(r.ok && r.value).toMatchObject({
    truncated: false,
    card: { windowDays: 7, merged: 1, spendUsd: 3, costPerMergeUsd: 3, medianHoursToMerge: 24 },
  });
});

test("passes truncation through", async () => {
  const pulls = { closedSince: async () => ok({ pulls: [], truncated: true }) };
  const r = await buildScorecard(ports({ pulls }));
  expect(r.ok && r.value.truncated).toBe(true);
});

test("an unreadable source is an error, never an empty card", async () => {
  const failed = { kind: "failed" as const, message: "boom" };
  const pulls = { closedSince: async () => err(failed) };
  expect((await buildScorecard(ports({ pulls }))).ok).toBe(false);
  const spend = { between: async () => err(failed) };
  expect((await buildScorecard(ports({ spend }))).ok).toBe(false);
});
