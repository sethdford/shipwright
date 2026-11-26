import { expect, test } from "bun:test";
import { DEFAULT_LABELS, labelPulls } from "./outcome-labels";
import type { PullRecord } from "./scorecard";

const DAY = 86_400_000;
const T = Date.UTC(2026, 10, 1);

const pull = (number: number, over: Partial<PullRecord> = {}): PullRecord => ({
  number,
  title: `fix: thing ${number}`,
  body: "",
  headRef: `fix/${number}`,
  labels: [],
  createdAtMs: T - DAY,
  mergedAtMs: T,
  closedAtMs: T,
  commits: [],
  ...over,
});

test("merged is 1, closed unmerged is 0, reverted within the window is 0", () => {
  const pulls = [
    pull(1),
    pull(2, { mergedAtMs: null }),
    pull(3),
    pull(4, {
      title: 'Revert "fix: thing 3"',
      body: "Reverts o/r#3",
      mergedAtMs: T + 2 * DAY,
      closedAtMs: T + 2 * DAY,
    }),
  ];
  const l = labelPulls(pulls, DEFAULT_LABELS);
  expect(l.map((x) => [x.pull.number, x.y])).toEqual([
    [1, 1],
    [2, 0],
    [3, 0],
  ]);
});

test("a revert after the window keeps the label", () => {
  const late = pull(4, {
    title: 'Revert "x"',
    body: "Reverts #3",
    mergedAtMs: T + 30 * DAY,
    closedAtMs: T + 30 * DAY,
  });
  expect(labelPulls([pull(3), late], DEFAULT_LABELS)[0]?.y).toBe(1);
});

test("dependency bots and test runs are left out", () => {
  const pulls = [
    pull(1, { headRef: "dependabot/npm_and_yarn/x" }),
    pull(2, { labels: ["shipwright:test-run"] }),
    pull(3, { headRef: "test/e2e" }),
    pull(4),
  ];
  const l = labelPulls(pulls, { ...DEFAULT_LABELS, excludeNumbers: [4] });
  expect(l).toEqual([]);
});

test("factory PRs weigh 1, human PRs weigh humanWeight, and 0 drops them", () => {
  const pulls = [
    pull(1, { body: "8 commit(s) via `shipwright pipeline` (fast)" }),
    pull(2, { headRef: "ci/issue-4" }),
    pull(3),
    pull(4),
  ];
  const l = labelPulls(pulls, { ...DEFAULT_LABELS, agentNumbers: [4] });
  expect(l.map((x) => [x.pull.number, x.agent, x.weight])).toEqual([
    [1, true, 1],
    [2, true, 1],
    [3, false, 0.5],
    [4, true, 1],
  ]);
  expect(labelPulls(pulls, { ...DEFAULT_LABELS, humanWeight: 0 })).toHaveLength(2);
});
