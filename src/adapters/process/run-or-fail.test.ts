import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { runOrFail } from "./run-or-fail";

test("passes through a normal result", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["x"], result: { exitCode: 0, stdout: "o", stderr: "" } },
  ]);
  expect(await runOrFail(runner, { argv: ["x"] })).toEqual({
    exitCode: 0,
    stdout: "o",
    stderr: "",
    timedOut: false,
  });
});

test("converts a rejection into exit 127 with the program name and message", async () => {
  const r = await runOrFail(new FakeProcessRunner([]), { argv: ["nope", "a"] });
  expect(r).toEqual({
    exitCode: 127,
    stdout: "",
    stderr: "nope: unscripted command: nope a",
    timedOut: false,
  });
});
