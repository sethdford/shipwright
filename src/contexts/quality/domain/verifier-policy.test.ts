import { expect, test } from "bun:test";
import { FEATURES, type FeatureVector } from "./change-features";
import { decide, type Evidence, hardStops, NO_EVIDENCE, untrustedReason } from "./verifier-policy";

const zero = Object.fromEntries(FEATURES.map((f) => [f, 0])) as Record<string, number>;
const x = (over: Partial<FeatureVector> = {}) => ({ ...zero, ...over }) as FeatureVector;

const TRUSTED: Evidence = {
  examples: 40,
  merged: 25,
  unmerged: 15,
  looAuc: 0.82,
  looBrier: 0.15,
  baseBrier: 0.23,
};

test("an untrained model is not trusted, and says why", () => {
  expect(untrustedReason(NO_EVIDENCE)).toContain("only 0 labelled PRs");
  expect(untrustedReason({ ...TRUSTED, unmerged: 3 })).toContain("5 merged and 5 unmerged");
  expect(untrustedReason({ ...TRUSTED, looAuc: 0.6 })).toContain("AUC 0.60");
  expect(untrustedReason({ ...TRUSTED, looBrier: 0.3 })).toContain("base rate");
  expect(untrustedReason(TRUSTED)).toBeNull();
});

test("hard stops block in enforce mode even without training", () => {
  const d = decide("enforce", 0.9, x({ noChange: 1 }), NO_EVIDENCE);
  expect(d.verdict).toBe("block");
  expect(d.reasons).toEqual(["no change beyond plans or run output"]);
  expect(hardStops(x({ testsFailing: 1, runArtifacts: 1 }))).toHaveLength(2);
});

test("a low probability only warns until the model is trusted", () => {
  const d = decide("enforce", 0.1, x(), NO_EVIDENCE);
  expect(d.verdict).toBe("warn");
  expect(d.reasons[0]).toContain("not blocking: only 0 labelled PRs");
  expect(decide("enforce", 0.1, x(), TRUSTED).verdict).toBe("block");
  expect(decide("enforce", 0.3, x(), TRUSTED).verdict).toBe("warn");
  expect(decide("enforce", 0.6, x(), TRUSTED).verdict).toBe("pass");
});

test("advisory never blocks and reports what enforce would do; off always passes", () => {
  const a = decide("advisory", 0.1, x(), TRUSTED);
  expect(a.verdict).toBe("warn");
  expect(a.wouldBe).toBe("block");
  const o = decide("off", 0.1, x({ noChange: 1 }), TRUSTED);
  expect(o.verdict).toBe("pass");
  expect(o.wouldBe).toBe("block");
});
