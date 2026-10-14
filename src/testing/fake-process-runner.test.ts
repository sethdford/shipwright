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
