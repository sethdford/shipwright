import { expect, test } from "bun:test";
import type { TournamentReport } from "../../contexts/delivery";
import { renderTournamentMarkdown, renderTournamentText } from "./tournament-render";

const report: TournamentReport = {
  baseSha: "b".repeat(40),
  attempts: [
    {
      id: "a1",
      strategy: "s",
      snapshot: { sha: "1", patch: "p", files: ["x.ts"] },
      ownTests: { passed: true, timedOut: false, tail: "" },
      costUsd: 1.5,
      turns: 9,
      note: null,
    },
    {
      id: "a2",
      strategy: "s",
      snapshot: null,
      ownTests: null,
      costUsd: 0.25,
      turns: 0,
      note: "agent stopped: budget",
    },
  ],
  rubric: {
    criteria: [
      { id: "fix", text: "Fixes it <script>@maintainer</script>", weight: 3, axis: "correctness" },
    ],
  },
  matrix: { ids: ["a1"], cells: [["pass"]] },
  candidates: [
    {
      id: "a1",
      built: true,
      ownTestsPass: true,
      cross: null,
      rubric: 1,
      votes: 1,
      members: ["a1"],
      composite: 1,
    },
  ],
  judge: {
    choice: "a1",
    labels: { A: "a1" },
    judgement: {
      consensus: [{ claim: "Both ping @org/team", defect: true, note: "line\nbreak" }],
      choice: "A",
      reasons: "Pick A.\n<img src=x>",
    },
  },
  selection: { winner: "a1", confidence: "medium", margin: null, reason: "no judge was needed" },
  winnerSha: "1",
  adopted: true,
  costUsd: 1.75,
  notes: ["could not remove a2's worktree: busy"],
};

test("the PR-body section carries the verdict, table, matrix, rubric and judge", () => {
  const md = renderTournamentMarkdown(report);
  expect(md).toContain("Chosen: **a1** from 2 independent attempts. Confidence: **medium**");
  expect(md).toContain("| a1 | 100% | — | 100% | pass |");
  expect(md).toContain("patch \\ tests | a1");
  expect(md).toContain("Tournament cost: $1.75.");
});

test("model text in the PR body cannot mention people or inject HTML", () => {
  const md = renderTournamentMarkdown(report);
  expect(md).not.toContain("<script>");
  expect(md).not.toContain("<img");
  expect(md).not.toMatch(/@(maintainer|org)/);
  expect(md).toContain("- ⚠ Both ping @​org/team: line break");
});

test("the text report lists attempts, candidates and notes", () => {
  const text = renderTournamentText(report);
  expect(text.split("\n")[0]).toBe(
    "Winner: a1 (medium confidence; no judge was needed), applied to the current branch",
  );
  expect(text).toContain("a2: 0 file(s), tests not run, $0.25; agent stopped: budget");
  expect(text).toContain("could not remove a2's worktree");
});
