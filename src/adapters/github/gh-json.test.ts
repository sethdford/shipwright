import { expect, test } from "bun:test";
import { z } from "zod";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { runGhJson } from "./gh-json";

const Schema = z.array(z.object({ number: z.number() }));
const gh = (exitCode: number, stdout: string, stderr = "") =>
  new FakeProcessRunner([{ prefix: ["gh"], result: { exitCode, stdout, stderr } }]);

test("parses and validates gh JSON output", async () => {
  const runner = gh(0, '[{"number":1,"extra":true}]');
  expect(await runGhJson(runner, ["gh", "issue", "list"], Schema)).toEqual({
    ok: true,
    value: [{ number: 1 }],
  });
  expect(runner.calls[0]?.timeoutMs).toBe(30_000);
});

test("a gh failure is classified, not thrown", async () => {
  const r = await runGhJson(gh(1, "", "HTTP 502: Bad Gateway"), ["gh", "x"], Schema);
  expect(r).toEqual({ ok: false, error: { kind: "transient", message: "HTTP 502: Bad Gateway" } });
});

test("non-JSON or off-schema output is a failed error", async () => {
  const notJson = await runGhJson(gh(0, "nope"), ["gh", "x"], Schema);
  expect(!notJson.ok && notJson.error.kind).toBe("failed");
  const offSchema = await runGhJson(gh(0, '[{"number":"1"}]'), ["gh", "x"], Schema);
  expect(!offSchema.ok && offSchema.error.message).toMatch(/unexpected gh output/);
});

test("a missing gh binary is a failed error, not a rejection", async () => {
  const r = await runGhJson(new FakeProcessRunner([]), ["gh", "x"], Schema);
  expect(!r.ok && r.error.kind).toBe("failed");
});
