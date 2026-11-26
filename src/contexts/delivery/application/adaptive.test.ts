import { expect, test } from "bun:test";
import { FakeDelivery, type FakeScript } from "../../../testing/fake-delivery";
import type { CandidateVerifier, VerifierInput } from "../ports";
import type { TournamentRequest } from "./attempts";
import { runTournament } from "./tournament";

const ALL = {
  "fixes-bug": true,
  "adds-test": true,
  small: true,
  "integrity-tests": true,
  "integrity-harness": true,
};

// a1 and a3 write the same correct fix; a2 writes a weaker one.
const SCRIPT: FakeScript = {
  patches: {
    a1: { patch: "GOOD", files: ["src/parse.ts", "src/parse.test.ts"] },
    a2: { patch: "WEAK", files: ["src/parse.ts", "test/weak.test.ts"] },
    a3: { patch: "GOOD", files: ["src/parse.ts", "src/parse.test.ts"] },
  },
  tests: (patch, from) => !(patch === "WEAK" && from === "GOOD"),
  grades: { GOOD: ALL, WEAK: { ...ALL, "adds-test": false } },
};

const REQ: TournamentRequest = {
  goal: "Fix the parser.",
  attempts: 3,
  budgetUsd: 15,
  model: "opus",
  judgeModel: "sonnet",
  testCommand: "bun test",
  setupCommand: null,
  maxTurns: 40,
  buildTimeoutMs: 60_000,
  testTimeoutMs: 60_000,
  adopt: false,
  adaptive: "shadow",
  stopAt: 0.8,
};

/** Scores GOOD high and anything else low; records what each call saw. */
function verifier(readiness?: () => Promise<string | null>) {
  const seen: VerifierInput[] = [];
  const v: CandidateVerifier = {
    score: async (input) => {
      seen.push(input);
      return input.patch === "GOOD" ? 0.86 : 0.3;
    },
    ...(readiness ? { readiness } : {}),
  };
  return { v, seen };
}

async function run(req: TournamentRequest, v?: CandidateVerifier) {
  const fake = new FakeDelivery(SCRIPT);
  const ports = v ? { ...fake.ports(), verifier: v } : fake.ports();
  const r = await runTournament(ports, req);
  if (!r.ok) throw new Error(r.error.message);
  return { rep: r.value, fake };
}

test("shadow runs every attempt and reports where it would have stopped", async () => {
  const { v, seen } = verifier();
  const { rep, fake } = await run(REQ, v);
  expect(fake.tasks).toHaveLength(3);
  expect(rep.attempts).toHaveLength(3);
  expect(rep.selection.winner).toBe("a1");
  expect(rep.earlyStop).toEqual({
    mode: "shadow",
    requested: "shadow",
    threshold: 0.8,
    of: 3,
    ran: 3,
    wouldStopAt: 1,
    triggeredBy: "a1",
    savedUsd: 2,
    savedBasis: "spend-after-stop",
    sameWinner: true,
    probes: [
      { id: "a1", p: 0.86 },
      { id: "a2", p: 0.3 },
      { id: "a3", p: 0.86 },
    ],
    notes: [],
  });
  // Probes never see signals that depend on other attempts.
  const probes = seen.filter((s) => s.cross === null && s.rubric === null);
  expect(probes).toHaveLength(3);
  expect(probes.every((s) => s.ownTestsPass)).toBe(true);
});

test("shadow with a higher threshold would not stop, and saves nothing", async () => {
  const { v } = verifier();
  const { rep } = await run({ ...REQ, stopAt: 0.9 }, v);
  expect(rep.earlyStop).toMatchObject({ wouldStopAt: null, triggeredBy: null, savedUsd: 0 });
  expect(rep.earlyStop?.sameWinner).toBeNull();
});

test("enforce with a trusted verifier stops after the first good attempt", async () => {
  const { v } = verifier(async () => null);
  const { rep, fake } = await run({ ...REQ, adaptive: "enforce" }, v);
  expect(fake.tasks).toHaveLength(1);
  expect(fake.tasks[0]?.maxBudgetUsd).toBe(4);
  expect(rep.attempts.map((a) => a.id)).toEqual(["a1"]);
  expect(rep.selection.winner).toBe("a1");
  expect(fake.removed).toEqual(["a1"]);
  expect(rep.earlyStop).toMatchObject({
    mode: "enforce",
    requested: "enforce",
    of: 3,
    ran: 1,
    wouldStopAt: 1,
    triggeredBy: "a1",
    savedUsd: 8,
    savedBasis: "unspent-budget",
    sameWinner: true,
    probes: [{ id: "a1", p: 0.86 }],
  });
});

test("enforce keeps adding attempts until one is good enough", async () => {
  const { v } = verifier(async () => null);
  const fake = new FakeDelivery({ ...SCRIPT, patches: { a2: { patch: "GOOD", files: ["x.ts"] } } });
  const r = await runTournament({ ...fake.ports(), verifier: v }, { ...REQ, adaptive: "enforce" });
  if (!r.ok) throw new Error(r.error.message);
  expect(fake.tasks).toHaveLength(2);
  expect(r.value.earlyStop).toMatchObject({ ran: 2, wouldStopAt: 2, triggeredBy: "a2" });
  expect(r.value.earlyStop?.probes).toEqual([
    { id: "a1", p: null },
    { id: "a2", p: 0.86 },
  ]);
});

test("enforce with an untrusted verifier falls back to shadow and says why", async () => {
  const { v } = verifier(async () => "only 12 labelled PRs");
  const { rep, fake } = await run({ ...REQ, adaptive: "enforce" }, v);
  expect(fake.tasks).toHaveLength(3);
  expect(rep.earlyStop).toMatchObject({ mode: "shadow", requested: "enforce", wouldStopAt: 1 });
  expect(rep.earlyStop?.notes[0]).toContain("only 12 labelled PRs");
});

test("enforce without a readiness check falls back to shadow", async () => {
  const { v } = verifier();
  const { rep, fake } = await run({ ...REQ, adaptive: "enforce" }, v);
  expect(fake.tasks).toHaveLength(3);
  expect(rep.earlyStop?.mode).toBe("shadow");
  expect(rep.earlyStop?.notes[0]).toContain("no readiness check");
});

test("without a verifier, shadow behaves as off and notes it", async () => {
  const { rep, fake } = await run({ ...REQ, adaptive: "enforce" });
  expect(fake.tasks).toHaveLength(3);
  expect(rep.earlyStop).toMatchObject({ mode: "off", requested: "enforce", ran: 3, probes: [] });
  expect(rep.earlyStop?.notes[0]).toContain("no merge verifier is wired");
});

test("off reports nothing and never probes", async () => {
  const { v, seen } = verifier(async () => null);
  const { rep, fake } = await run({ ...REQ, adaptive: "off" }, v);
  expect(rep.earlyStop).toBeNull();
  expect(fake.tasks).toHaveLength(3);
  expect(seen.every((s) => s.cross !== null || s.rubric !== null)).toBe(true);
});
