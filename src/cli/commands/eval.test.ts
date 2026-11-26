import { describe, expect, test } from "bun:test";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { evalCommand } from "./eval";

const runs = (cases: number, passes: (c: number) => boolean) =>
  Array.from({ length: cases }, (_, c) =>
    Array.from({ length: 3 }, () => ({ case: `c${c}`, pass: passes(c), costUsd: 1 })),
  ).flat();

const files = new FakeFileReader({
  "/inc.json": JSON.stringify({ policy: "routing-v1", runs: runs(16, () => false) }),
  "/better.json": JSON.stringify({ policy: "routing-v2", runs: runs(16, (c) => c < 6) }),
  "/same.json": JSON.stringify({ policy: "routing-v2", runs: runs(16, () => false) }),
  "/short.json": JSON.stringify({ policy: "x", runs: [{ case: "c0", pass: true, costUsd: 1 }] }),
  "/bad.json": "{not json",
});

async function run(args: string[]) {
  const io = captureIO();
  const code = await evalCommand.run(args, commandContext(io, undefined, {}, files));
  return { code, io };
}

describe("eval score", () => {
  test("prints mean pass^3, cases, runs and spend", async () => {
    const { code, io } = await run(["score", "--results", "/better.json"]);
    expect(code).toBe(0);
    expect(io.outLines[0]).toBe("routing-v2: pass^3 37.5% over 16 case(s), 48 run(s), $48.00");
  });

  test("json output carries per-case scores", async () => {
    const { io } = await run(["score", "--results", "/better.json", "--json", "--k", "1"]);
    expect(JSON.parse(io.outLines.join("\n"))).toMatchObject({ k: 1, meanPassK: 0.375 });
  });

  test("too few runs per case or unreadable files exit 1", async () => {
    expect((await run(["score", "--results", "/short.json"])).code).toBe(1);
    expect((await run(["score", "--results", "/bad.json"])).code).toBe(1);
    expect((await run(["score", "--results", "/missing.json"])).code).toBe(1);
  });
});

describe("eval ratchet", () => {
  test("a superior candidate is accepted with exit 0", async () => {
    const { code, io } = await run([
      "ratchet",
      "--incumbent",
      "/inc.json",
      "--candidate",
      "/better.json",
    ]);
    expect(code).toBe(0);
    expect(io.outLines[0]).toStartWith("✓ accept routing-v2 over routing-v1: superior");
  });

  test("a candidate that is no better is rejected with exit 3", async () => {
    const { code, io } = await run([
      "ratchet",
      "--incumbent",
      "/inc.json",
      "--candidate",
      "/same.json",
      "--json",
    ]);
    expect(code).toBe(3);
    expect(JSON.parse(io.outLines.join("\n")).verdict).toMatchObject({ accept: false, ties: 16 });
  });

  test("unpaired cases fail closed with exit 1", async () => {
    expect(
      (await run(["ratchet", "--incumbent", "/inc.json", "--candidate", "/short.json"])).code,
    ).toBe(1);
  });
});

describe("usage", () => {
  test("help exits 0 and bad arguments exit 2", async () => {
    expect((await run(["--help"])).code).toBe(0);
    expect((await run(["ratchet", "--help"])).code).toBe(0);
    expect((await run([])).code).toBe(2);
    expect((await run(["score"])).code).toBe(2);
    expect((await run(["ratchet", "--incumbent", "/inc.json"])).code).toBe(2);
    expect((await run(["score", "--results", "/a", "--k", "0"])).code).toBe(2);
    expect((await run(["score", "--results"])).code).toBe(2);
    expect((await run(["score", "--results", "/a", "--nope", "x"])).code).toBe(2);
  });
});
