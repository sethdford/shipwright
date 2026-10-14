import { expect, test } from "bun:test";
import { FakeProcessRunner } from "./fake-process-runner";

test("returns the scripted response for a matching argv prefix and records calls", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["git", "rev-parse"], result: { exitCode: 0, stdout: "abc123\n", stderr: "" } },
  ]);
  const result = await runner.run({ argv: ["git", "rev-parse", "HEAD"], cwd: "/repo" });
  expect(result.stdout).toBe("abc123\n");
  expect(runner.calls[0]?.argv).toEqual(["git", "rev-parse", "HEAD"]);
});

test("throws on an unscripted command so tests never hit the real system", async () => {
  const runner = new FakeProcessRunner([]);
  await expect(runner.run({ argv: ["rm", "-rf", "/"] })).rejects.toThrow(/unscripted command/);
});

test("rejects a scripted call with an empty prefix at construction", () => {
  expect(
    () => new FakeProcessRunner([{ prefix: [], result: { exitCode: 0, stdout: "", stderr: "" } }]),
  ).toThrow(/empty prefix/);
});

test("exposes calls as a read-only view", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["git"], result: { exitCode: 0, stdout: "", stderr: "" } },
  ]);
  await runner.run({ argv: ["git", "status"] });
  const calls: readonly unknown[] = runner.calls;
  expect(calls).toHaveLength(1);
  // @ts-expect-error calls must not expose mutators
  runner.calls.push({ argv: ["x"] });
});
