import { expect, test } from "bun:test";
import { NO_SIGNALS } from "./change-features";
import type { PullRecord } from "./scorecard";
import { JOIN_LEAD_MS, type ScoreRecord, signalsFor } from "./score-log";

const T = Date.UTC(2026, 10, 1);
const pull: PullRecord = {
  number: 5,
  title: "fix: x",
  body: "",
  headRef: "ci/issue-5",
  labels: [],
  createdAtMs: T,
  mergedAtMs: null,
  closedAtMs: T + 1000,
  commits: [],
};
const rec = (atMs: number, critic: number, branch = "ci/issue-5"): ScoreRecord => ({
  atMs,
  branch,
  headSha: "abc1234",
  probability: 0.5,
  signals: { ...NO_SIGNALS, criticProbability: critic },
});

test("joins the latest score on the PR's branch taken around when it opened", () => {
  const records = [
    rec(T - JOIN_LEAD_MS - 1, 0.1), // an earlier run on the same branch name
    rec(T - 60_000, 0.7),
    rec(T + 500, 0.9),
    rec(T + 500, 0.2, "other"),
    rec(T + 2000, 0.3), // after it closed
  ];
  expect(signalsFor(pull, records)?.criticProbability).toBe(0.9);
});

test("a PR never scored has no signals", () => {
  expect(signalsFor(pull, [rec(T, 0.5, "other")])).toBeNull();
});
