import { expect, test } from "bun:test";
import { BunProcessRunner } from "./bun-process-runner";

const runner = new BunProcessRunner();

test("captures stdout, stderr and exit code", async () => {
  const r = await runner.run({ argv: ["sh", "-c", "echo out; echo err >&2; exit 3"] });
  expect(r).toEqual({ exitCode: 3, stdout: "out\n", stderr: "err\n", timedOut: false });
});

test("passes argv literally — no shell expansion of arguments", async () => {
  const r = await runner.run({ argv: ["echo", "$(whoami)", "`id`"] });
  expect(r.stdout).toBe("$(whoami) `id`\n");
});

test("feeds stdin", async () => {
  const r = await runner.run({ argv: ["cat"], stdin: "hello" });
  expect(r.stdout).toBe("hello");
});

test("kills the process on timeout", async () => {
  const r = await runner.run({ argv: ["sleep", "5"], timeoutMs: 100 });
  expect(r.timedOut).toBe(true);
  expect(r.exitCode).not.toBe(0);
});
