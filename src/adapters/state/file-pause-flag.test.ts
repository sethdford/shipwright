import { afterEach, expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createTestEnv, type TestEnv } from "../../testing/test-env";
import { FilePauseFlag, parsePauseFlag } from "./file-pause-flag";

let env: TestEnv | undefined;
afterEach(() => env?.cleanup());
const flagIn = (e: TestEnv) => join(e.stateDir, "daemon-pause.flag");

test("no file means no flag", async () => {
  env = createTestEnv();
  expect(await new FilePauseFlag(flagIn(env)).read()).toEqual({ ok: true, value: null });
});

test("write, read and clear round-trip in the bash daemon's format", async () => {
  env = createTestEnv();
  const flag = new FilePauseFlag(join(env.stateDir, "nested", "daemon-pause.flag"));
  expect(await flag.write("maintenance", "2026-10-14T10:00:00.000Z")).toEqual({
    ok: true,
    value: undefined,
  });
  expect(await flag.read()).toEqual({
    ok: true,
    value: { reason: "maintenance", since: "2026-10-14T10:00:00.000Z", resumeAfter: null },
  });
  expect(await flag.clear()).toEqual({ ok: true, value: undefined });
  expect(await flag.clear()).toEqual({ ok: true, value: undefined });
  expect(await flag.read()).toEqual({ ok: true, value: null });
});

test("written JSON has the keys the daemon reads", async () => {
  env = createTestEnv();
  await new FilePauseFlag(flagIn(env)).write("x", "2026-10-14T10:00:00.000Z");
  expect(JSON.parse(readFileSync(flagIn(env), "utf8"))).toEqual({
    reason: "x",
    timestamp: "2026-10-14T10:00:00.000Z",
    source: "shipwright pause",
  });
  expect(existsSync(`${flagIn(env)}.tmp`)).toBe(false);
});

test("reads flags written by the bash daemon", async () => {
  env = createTestEnv();
  writeFileSync(
    flagIn(env),
    '{"reason":"consecutive_failures","timestamp":"t","resume_after":"2026-10-14T11:00:00Z"}',
  );
  expect(await new FilePauseFlag(flagIn(env)).read()).toEqual({
    ok: true,
    value: {
      reason: "consecutive_failures",
      since: "t",
      resumeAfter: Date.parse("2026-10-14T11:00:00Z"),
    },
  });
});

test.each([
  ['{"paused":true,"reason":"disk_low"}', "disk_low"],
  ["not json", "pause flag present"],
  ["", "pause flag present"],
])("any existing flag file pauses, even %p", (text, reason) => {
  expect(parsePauseFlag(text)).toEqual({ reason, since: "", resumeAfter: null });
});
