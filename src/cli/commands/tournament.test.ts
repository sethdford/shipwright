import { describe, expect, test } from "bun:test";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeDelivery, type FakeScript } from "../../testing/fake-delivery";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { tournamentCommand } from "./tournament";
import { parseTournamentFlags } from "./tournament-flags";

const ALL = {
  "fixes-bug": true,
  "adds-test": true,
  small: true,
  "integrity-tests": true,
  "integrity-harness": true,
};
const WIN: FakeScript = {
  patches: { a1: { patch: "GOOD", files: ["x.ts"] }, a2: { patch: "GOOD", files: ["x.ts"] } },
  tests: () => true,
  grades: { GOOD: ALL },
};

async function run(args: string[], script: FakeScript = WIN, goal = "Fix @someone's <b>bug</b>") {
  const io = captureIO();
  const fake = new FakeDelivery(script);
  const files = new FakeFileReader({ "/goal.md": goal });
  const ctx = commandContext(io, undefined, {}, files, { delivery: fake.ports() });
  const code = await tournamentCommand.run(args, ctx);
  return { code, io, fake };
}

const BASE = ["--goal-file", "/goal.md", "--test-cmd", "bun test", "--attempts", "2"];

describe("tournament", () => {
  test("a winner exits 0 and the text report names it", async () => {
    const { code, io, fake } = await run(BASE);
    expect(code).toBe(0);
    expect(io.outLines.join("\n")).toContain("Winner: a1 (high confidence");
    expect(fake.adopted).toHaveLength(1);
  });

  test("markdown is a PR-body section with model text made inert", async () => {
    const { io } = await run([...BASE, "--format", "markdown", "--no-adopt"]);
    const md = io.outLines.join("\n");
    expect(md).toStartWith("## Tournament");
    expect(md).toContain("| a1, a2 | 100% |");
    expect(md).toContain("<details><summary>Rubric</summary>");
    // Shadow is the default, and with no verifier wired it says so instead of deciding.
    expect(md).toContain("Early stop (off): not evaluated no merge verifier is wired");
  });

  test("json is the full report", async () => {
    const { io } = await run([...BASE, "--format", "json"]);
    const rep = JSON.parse(io.outLines.join("\n"));
    expect(rep.selection.winner).toBe("a1");
    expect(rep.attempts).toHaveLength(2);
  });

  test("no winner exits 3", async () => {
    const { code } = await run(BASE, { patches: {}, tests: () => true });
    expect(code).toBe(3);
  });

  test("a missing or empty goal file fails before any agent runs", async () => {
    const missing = await run(["--goal-file", "/nope.md", "--test-cmd", "x"]);
    expect(missing.code).toBe(1);
    expect(missing.fake.tasks).toHaveLength(0);
    expect((await run(BASE, WIN, "  \n")).code).toBe(2);
  });

  test("bad arguments exit 2 and help exits 0", async () => {
    expect((await run(["--help"])).code).toBe(0);
    expect((await run(["--test-cmd", "x"])).code).toBe(2);
    expect((await run(["--goal-file", "/goal.md"])).code).toBe(2);
    expect((await run([...BASE, "--attempts", "9"])).code).toBe(2);
    expect((await run([...BASE, "--budget-usd", "0"])).code).toBe(2);
    expect((await run([...BASE, "--model", "a b"])).code).toBe(2);
    expect((await run([...BASE, "--test-cmd", " "])).code).toBe(2);
    expect((await run([...BASE, "--format", "html"])).code).toBe(2);
    expect((await run([...BASE, "--bogus"])).code).toBe(2);
    expect((await run([...BASE, "--max-turns"])).code).toBe(2);
  });
});

test("flags fill the request with defaults, and the judge defaults to the builder model", () => {
  const f = parseTournamentFlags([
    "--goal-file",
    "g",
    "--test-cmd",
    "make test",
    "--model",
    "sonnet",
  ]);
  if (typeof f === "string") throw new Error(f);
  expect(f.request).toEqual({
    attempts: 3,
    budgetUsd: 15,
    model: "sonnet",
    judgeModel: "sonnet",
    testCommand: "make test",
    setupCommand: null,
    maxTurns: 60,
    buildTimeoutMs: 45 * 60_000,
    testTimeoutMs: 15 * 60_000,
    adopt: true,
    adaptive: "shadow",
    stopAt: 0.8,
  });
});

test("--adaptive and --stop-at are parsed and bounded", () => {
  const base = ["--goal-file", "g", "--test-cmd", "t"];
  const f = parseTournamentFlags([...base, "--adaptive", "enforce", "--stop-at", "0.9"]);
  if (typeof f === "string") throw new Error(f);
  expect(f.request).toMatchObject({ adaptive: "enforce", stopAt: 0.9 });
  const g = parseTournamentFlags([...base, "--adaptive", "off", "--stop-at", ".5"]);
  expect(typeof g !== "string" && g.request).toMatchObject({ adaptive: "off", stopAt: 0.5 });
  expect(parseTournamentFlags([...base, "--adaptive", "auto"])).toBe(
    "--adaptive must be off, shadow or enforce",
  );
  for (const bad of ["0.4", "1", "0.999", "abc", "-0.8"]) {
    expect(parseTournamentFlags([...base, "--stop-at", bad])).toBe("--stop-at must be 0.5 to 0.99");
  }
});
