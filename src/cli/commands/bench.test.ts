import { describe, expect, test } from "bun:test";
import type { BenchFactory, BenchPorts, BenchRow } from "../../contexts/quality";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { benchCommand } from "./bench";

const SHA = "a".repeat(40);
const manifest = {
  name: "m",
  tasks: ["t1", "t2"].map((id) => ({
    id,
    suite: "holdout",
    repo: "https://github.com/o/r",
    baseCommit: SHA,
    problem: "p",
    testPatch: "diff",
    testCommands: [["bash", "t.sh"]],
  })),
};
const arms = {
  baseline: "cc",
  arms: [
    { id: "cc", kind: "claude-code", model: "opus", estimateUsd: 2 },
    { id: "sw", kind: "shipwright", model: "opus", attempts: 3, estimateUsd: 6 },
  ],
};

function fakeBench(rows: BenchRow[] = []) {
  const written: Record<string, string> = {};
  const ports: BenchPorts = {
    now: () => 0,
    workspaces: {
      prepare: async () => ok("/w"),
      diff: async () => ok("diff --git a/x b/x\n"),
      checkout: async () => ok(undefined),
      dispose: async () => {},
    },
    arms: { run: async () => ({ status: "ok", costUsd: 1, durationMs: 60_000, note: "" }) },
    grader: { grade: async (task) => ok({ resolved: task.id === "t1", detail: "" }) },
    store: {
      rows: async () => ok(rows),
      append: async (r) => {
        rows.push(r);
        return ok(undefined);
      },
      savePatch: async () => ok(undefined),
      readPatch: async () => ok("diff"),
      write: async (name, text) => {
        written[name] = text;
        return ok(`/out/${name}`);
      },
    },
  };
  const factory: BenchFactory = {
    ports: () => ports,
    holdout: () => ({
      mergedSince: async () => err({ kind: "auth", message: "gh auth login" }),
      issue: async () => err({ kind: "failed", message: "x" }),
      diff: async () => err({ kind: "failed", message: "x" }),
    }),
  };
  return { factory, rows, written };
}

const files = new FakeFileReader({
  "/tasks.json": JSON.stringify(manifest),
  "/arms.json": JSON.stringify(arms),
  "/bad.json": "{",
});

async function run(args: string[], bench = fakeBench()) {
  const io = captureIO();
  const ctx = commandContext(io, undefined, {}, files, { bench: bench.factory });
  return { code: await benchCommand.run(args, ctx), io, bench };
}

const base = ["--tasks", "/tasks.json", "--arms", "/arms.json"];

describe("bench", () => {
  test("plan counts runs and estimated spend", async () => {
    const { code, io } = await run(["plan", ...base, "--trials", "2"]);
    expect(code).toBe(0);
    expect(io.outLines[0]).toContain("2 task(s) × 2 arm(s) × 2 trial(s) = 8 run(s)");
    expect(io.outLines.at(-1)).toContain("estimated $32.00");
  });

  test("run requires a budget and stops at it (exit 3)", async () => {
    expect((await run(["run", ...base, "--out", "/o"])).code).toBe(2);
    const { code, io, bench } = await run(["run", ...base, "--out", "/o", "--budget", "2.5"]);
    expect(code).toBe(3);
    expect(bench.rows).toHaveLength(1);
    expect(io.errLines.join("\n")).toContain("budget");
  });

  test("report writes markdown, html and json", async () => {
    const b = fakeBench();
    await run(["run", ...base, "--out", "/o", "--budget", "100"], b);
    const { code, io } = await run(["report", ...base, "--out", "/o"], b);
    expect(code).toBe(0);
    expect(Object.keys(b.written).sort()).toEqual(["report.html", "report.json", "report.md"]);
    expect(io.outLines.join("\n")).toContain("| cc (opus) | 1/2 | 50.0%");
    expect(b.written["report.html"]).toContain("<!doctype html>");
  });

  test("export-eval writes the eval results format", async () => {
    const b = fakeBench();
    await run(["run", ...base, "--out", "/o", "--budget", "100"], b);
    const { code } = await run(["export-eval", "--out", "/o", "--arm", "sw"], b);
    expect(code).toBe(0);
    expect(JSON.parse(b.written["eval-sw.json"] ?? "{}").runs).toHaveLength(2);
  });

  test("bad input fails with a message, not a stack", async () => {
    const r1 = await run(["plan", "--tasks", "/bad.json", "--arms", "/arms.json"]);
    expect(r1.code).toBe(1);
    expect(r1.io.errLines[0]).toContain("/bad.json is not JSON");
    const r2 = await run(["mine-holdout", "--repo", "o/r", "--since", "2026-01-01"]);
    expect(r2.code).toBe(1);
    expect(r2.io.errLines[0]).toContain("gh auth login");
    expect((await run(["nope"])).code).toBe(2);
    expect((await run(["plan", ...base, "--trials", "11"])).code).toBe(2);
  });
});
