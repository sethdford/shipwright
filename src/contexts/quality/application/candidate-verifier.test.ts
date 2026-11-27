import { expect, test } from "bun:test";
import { fakeVerifierPorts } from "../../../testing/fake-verifier";
import { PRIOR_MODEL } from "../domain/verifier-model";
import { candidateVerifier } from "./candidate-verifier";

const patch = (path: string, n: number) =>
  [
    `diff --git a/${path} b/${path}`,
    `--- a/${path}`,
    `+++ b/${path}`,
    "@@ -0,0 +1 @@",
    ...Array.from({ length: n }, (_, i) => `+line ${i}`),
  ].join("\n");
const input = (p: string) => ({
  goal: "I have a bug",
  patch: p,
  ownTestsPass: true,
  cross: null,
  rubric: null,
});

test("scores a candidate from its patch: run output in the diff scores far lower", async () => {
  const v = candidateVerifier(fakeVerifierPorts());
  const clean = await v.score(input(`${patch("src/a.ts", 20)}\n${patch("src/a.test.ts", 20)}`));
  const logs = await v.score(input(patch(".claude/loop-logs/run.log", 2000)));
  expect(clean).toBeGreaterThan(0.6);
  expect(logs as number).toBeLessThan((clean as number) - 0.3);
});

test("readiness: never trained, untrusted, trusted", async () => {
  expect(await candidateVerifier(fakeVerifierPorts()).readiness()).toContain("never trained");
  const weak = { examples: 5, merged: 2, unmerged: 3, looAuc: 0.6, looBrier: 0.2, baseBrier: 0.25 };
  const strong = {
    examples: 40,
    merged: 15,
    unmerged: 25,
    looAuc: 0.8,
    looBrier: 0.15,
    baseBrier: 0.24,
  };
  const at = (evidence: typeof weak) =>
    candidateVerifier(fakeVerifierPorts({ stored: { model: PRIOR_MODEL, evidence } })).readiness();
  expect(await at(weak)).toContain("only 5 labelled PRs");
  expect(await at(strong)).toBeNull();
});
