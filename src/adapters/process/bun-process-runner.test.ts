import { expect, test } from "bun:test";
import { realpathSync } from "node:fs";
import { createTestEnv } from "../../testing/test-env";
import { BunProcessRunner } from "./bun-process-runner";

const runner = new BunProcessRunner();
const fast = new BunProcessRunner({ killGraceMs: 300, drainMs: 300 });

async function timed<T>(p: Promise<T>): Promise<{ value: T; ms: number }> {
  const t = Date.now();
  const value = await p;
  return { value, ms: Date.now() - t };
}

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

test("child ignoring SIGTERM is killed after the grace period", async () => {
  const { value: r, ms } = await timed(
    fast.run({ argv: ["sh", "-c", "trap '' TERM; sleep 3"], timeoutMs: 200 }),
  );
  expect(ms).toBeLessThan(1500);
  expect(r.timedOut).toBe(true);
  expect(r.exitCode).not.toBe(0);
});

test("grandchild holding the pipe cannot outlive the timeout", async () => {
  const { value: r, ms } = await timed(
    fast.run({ argv: ["sh", "-c", "sleep 3 & wait"], timeoutMs: 200 }),
  );
  expect(ms).toBeLessThan(1500);
  expect(r.timedOut).toBe(true);
});

test("background grandchild cannot hold run() hostage without a timeout", async () => {
  const { value: r, ms } = await timed(fast.run({ argv: ["sh", "-c", "(sleep 3 &); echo done"] }));
  expect(ms).toBeLessThan(1500);
  expect(r.stdout).toBe("done\n");
  expect(r.timedOut).toBe(false);
});

test("env replaces the child environment when given", async () => {
  const r = await runner.run({
    argv: ["sh", "-c", "echo $FOO"],
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", FOO: "bar" },
  });
  expect(r.stdout).toBe("bar\n");
});

test("cwd is honoured", async () => {
  const env = createTestEnv();
  try {
    const r = await runner.run({ argv: ["pwd"], cwd: env.root });
    expect(realpathSync(r.stdout.trim())).toBe(realpathSync(env.root));
  } finally {
    env.cleanup();
  }
});

test("rejects when the program cannot be started", async () => {
  await expect(runner.run({ argv: ["definitely-not-a-real-binary-xyz"] })).rejects.toThrow();
});

test("killAll terminates an in-flight run", async () => {
  const pending = timed(fast.run({ argv: ["sleep", "5"] }));
  await new Promise((resolve) => setTimeout(resolve, 100));
  fast.killAll("SIGKILL");
  const { value: r, ms } = await pending;
  expect(ms).toBeLessThan(1500);
  expect(r.exitCode).not.toBe(0);
});

test("timed-out run leaves no surviving grandchild that ignores SIGTERM", async () => {
  // Grace must exceed drain, or the SIGKILL timer races run() returning and hides the leak.
  const slowGrace = new BunProcessRunner({ killGraceMs: 2000, drainMs: 300 });
  try {
    const r = await slowGrace.run({
      argv: ["sh", "-c", "(trap '' TERM; exec sleep 41) & sleep 42; wait"],
      timeoutMs: 200,
    });
    expect(r.timedOut).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(Bun.spawnSync(["pgrep", "-f", "sleep 41"]).exitCode).toBe(1);
  } finally {
    Bun.spawnSync(["pkill", "-f", "sleep 41"]);
  }
});
