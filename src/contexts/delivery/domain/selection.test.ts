import { expect, test } from "bun:test";
import {
  blindLabels,
  type CandidateScore,
  compositeScore,
  finalists,
  groupIdentical,
  rankCandidates,
  select,
} from "./selection";

const cand = (id: string, over: Partial<CandidateScore> = {}): CandidateScore => ({
  id,
  built: true,
  ownTestsPass: true,
  cross: null,
  rubric: null,
  votes: 1,
  ...over,
});

test("the composite score averages the signals it has", () => {
  expect(compositeScore(cand("a", { cross: 1, rubric: 0.5 }))).toBe(0.75);
  expect(compositeScore(cand("a", { rubric: 0.4 }))).toBe(0.4);
  expect(compositeScore(cand("a"))).toBe(0.5);
});

test("candidates that failed the gate are never ranked", () => {
  const ranked = rankCandidates([
    cand("a", { ownTestsPass: false, rubric: 1 }),
    cand("b", { built: false, rubric: 1 }),
    cand("c", { rubric: 0.2 }),
  ]);
  expect(ranked.map((c) => c.id)).toEqual(["c"]);
});

test("ties break on votes, then id", () => {
  const ranked = rankCandidates([cand("b"), cand("c", { votes: 2 }), cand("a")]);
  expect(ranked.map((c) => c.id)).toEqual(["c", "a", "b"]);
});

test("finalists are the candidates within the margin of the leader", () => {
  const cs = [cand("a", { rubric: 0.9 }), cand("b", { rubric: 0.8 }), cand("c", { rubric: 0.5 })];
  expect(finalists(cs).map((c) => c.id)).toEqual(["a", "b"]);
});

test("no eligible candidate, or a judge that rejects all, means no winner", () => {
  expect(select([cand("a", { ownTestsPass: false })], null).winner).toBeNull();
  const none = select([cand("a"), cand("b")], "none");
  expect(none).toMatchObject({ winner: null, reason: "the judge rejected every finalist" });
});

test("a lone candidate wins with medium confidence, high when attempts agreed on it", () => {
  expect(select([cand("a")], null)).toMatchObject({
    winner: "a",
    confidence: "medium",
    margin: null,
  });
  expect(select([cand("a", { votes: 2 })], null).confidence).toBe("high");
});

test("a clear lead confirmed by the judge is high confidence", () => {
  const cs = [cand("a", { rubric: 0.9 }), cand("b", { rubric: 0.7 })];
  const s = select(cs, "a");
  expect(s).toMatchObject({
    winner: "a",
    confidence: "high",
    reason: "the judge agreed with the scores",
  });
  expect(s.margin).toBeCloseTo(0.2);
});

test("a judge that overrules the scores wins, with low confidence", () => {
  const s = select([cand("a", { rubric: 0.9 }), cand("b", { rubric: 0.8 })], "b");
  expect(s).toMatchObject({
    winner: "b",
    confidence: "low",
    reason: "the judge overruled the scores",
  });
  expect(s.margin).toBeCloseTo(-0.1);
});

test("an unknown judge answer falls back to the score leader", () => {
  expect(select([cand("a", { rubric: 0.9 }), cand("b", { rubric: 0.85 })], "zzz").winner).toBe("a");
});

test("identical patches collapse into one candidate with votes", () => {
  const groups = groupIdentical([
    { id: "a1", patch: "x" },
    { id: "a2", patch: "y" },
    { id: "a3", patch: "x" },
  ]);
  expect(groups.map((g) => [g.lead.id, g.votes, g.members])).toEqual([
    ["a1", 2, ["a1", "a3"]],
    ["a2", 1, ["a2"]],
  ]);
});

test("blind labels are a permutation drawn from the random source", () => {
  const first = blindLabels(["a1", "a2", "a3"], () => 0);
  expect([...first.keys()]).toEqual(["A", "B", "C"]);
  expect([...first.values()].sort()).toEqual(["a1", "a2", "a3"]);
  const other = blindLabels(["a1", "a2", "a3"], () => 0.99);
  expect([...other.values()]).toEqual(["a1", "a2", "a3"]);
  expect([...first.values()]).not.toEqual([...other.values()]);
});
