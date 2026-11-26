import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { BashCommandRunner, testEnv } from "./bash-command-runner";

test("the command runs with bash in the workspace, with the given environment", async () => {
  const fake = new FakeProcessRunner([
    { prefix: ["bash", "-c"], result: { exitCode: 0, stdout: "12 pass\n", stderr: "" } },
  ]);
  const r = await new BashCommandRunner(fake, { PATH: "/bin" }).run("bun test", "/wt/a1", 5000);
  expect(r).toEqual({ ok: true, value: { passed: true, timedOut: false, tail: "12 pass" } });
  expect(fake.calls[0]).toMatchObject({
    argv: ["bash", "-c", "bun test"],
    cwd: "/wt/a1",
    env: { PATH: "/bin" },
    timeoutMs: 5000,
  });
});

test("a failing or timed-out command did not pass, and only the tail is kept", async () => {
  const long = Array.from({ length: 100 }, (_, i) => `line ${i}`).join("\n");
  const fail = new FakeProcessRunner([
    { prefix: ["bash"], result: { exitCode: 1, stdout: long, stderr: "boom" } },
  ]);
  const r = await new BashCommandRunner(fail, {}).run("x", "/", 1);
  expect(r.ok && r.value.passed).toBe(false);
  expect(r.ok && r.value.tail.split("\n")).toHaveLength(40);
  expect(r.ok && r.value.tail.endsWith("boom")).toBe(true);
  const slow = new FakeProcessRunner([
    { prefix: ["bash"], result: { exitCode: 0, stdout: "", stderr: "", timedOut: true } },
  ]);
  const t = await new BashCommandRunner(slow, {}).run("x", "/", 1);
  expect(t.ok && t.value).toMatchObject({ passed: false, timedOut: true });
});

test("agent-written code under test never sees GitHub credentials", () => {
  const env = testEnv({
    PATH: "/bin",
    HOME: "/h",
    GH_TOKEN: "x",
    GITHUB_TOKEN: "x",
    GH_ENTERPRISE_TOKEN: "x",
    MY_GITHUB_TOKEN: "x",
    ANTHROPIC_API_KEY: undefined,
  });
  expect(env).toEqual({ PATH: "/bin", HOME: "/h" });
});
