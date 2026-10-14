import { expect, test } from "bun:test";
import { DEFAULT_FLOW_POLICY, fixLoopAllows, type PullSummary, reviewWip } from "./flow";

const pr = (number: number, over: Partial<PullSummary> = {}): PullSummary => ({
  number,
  author: "app/github-actions",
  labels: [],
  draft: false,
  approved: false,
  ...over,
});
const policy = { ...DEFAULT_FLOW_POLICY, reviewWipLimit: 3 };

test("counts agent PRs awaiting review plus runs that will open more", () => {
  const pulls = [
    pr(1),
    pr(2, { author: "sethdford", labels: ["shipwright"] }),
    pr(3, { author: "sethdford" }),
    pr(4, { author: "app/dependabot" }),
    pr(5, { draft: true }),
    pr(6, { approved: true }),
  ];
  expect(reviewWip(pulls, 0, policy)).toEqual({
    allowed: true,
    awaitingReview: [1, 2],
    inFlight: 0,
    limit: 3,
  });
  expect(reviewWip(pulls, 1, policy)).toMatchObject({ allowed: false, inFlight: 1 });
});

test("the default limit is 5", () => {
  const four = [pr(1), pr(2), pr(3), pr(4)];
  expect(reviewWip(four, 0, DEFAULT_FLOW_POLICY).allowed).toBe(true);
  expect(reviewWip([...four, pr(5)], 0, DEFAULT_FLOW_POLICY).allowed).toBe(false);
});

test("the fix loop allows attempts 1-3 and stops the 4th", () => {
  expect(fixLoopAllows(null, DEFAULT_FLOW_POLICY)).toBe(true);
  expect(fixLoopAllows(3, DEFAULT_FLOW_POLICY)).toBe(true);
  expect(fixLoopAllows(4, DEFAULT_FLOW_POLICY)).toBe(false);
});
