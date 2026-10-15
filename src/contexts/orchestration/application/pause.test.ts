import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import {
  fakeSafetyPorts,
  fixedLabel,
  MemoryPauseFlag,
  NOW,
} from "../../../testing/fake-safety-ports";
import { pause, readPause, resume } from "./pause";

test("pause writes the flag with the current time; resume clears it", async () => {
  const pauseFlag = new MemoryPauseFlag();
  const ports = fakeSafetyPorts({ pauseFlag });
  await pause(ports, "investigating #8524");
  expect(pauseFlag.flag).toEqual({
    reason: "investigating #8524",
    since: new Date(NOW).toISOString(),
    resumeAfter: null,
  });
  expect((await readPause(ports, { github: true })).ok).toBe(true);
  await resume(ports);
  expect(pauseFlag.flag).toBeNull();
});

test("the label pauses; without GitHub it is not checked", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([7])) });
  expect(await readPause(ports, { github: true })).toEqual({
    ok: true,
    value: { paused: true, reasons: ["label shipwright:pause on #7"] },
  });
  expect(await readPause(ports, { github: false })).toEqual({
    ok: true,
    value: { paused: false, reasons: [] },
  });
});

test("an unreadable label is an error (callers fail closed)", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(err({ kind: "auth", message: "x" })) });
  expect((await readPause(ports, { github: true })).ok).toBe(false);
});

const authErr = { kind: "auth", message: "x" } as const;

test("an unreadable pause flag is an error", async () => {
  const pauseFlag = new MemoryPauseFlag();
  pauseFlag.read = async () => err(authErr);
  expect((await readPause(fakeSafetyPorts({ pauseFlag }), { github: false })).ok).toBe(false);
});

test("pause and resume surface write errors", async () => {
  const pauseFlag = new MemoryPauseFlag();
  pauseFlag.write = async () => err(authErr);
  pauseFlag.clear = async () => err(authErr);
  const ports = fakeSafetyPorts({ pauseFlag });
  expect((await pause(ports, "r")).ok).toBe(false);
  expect((await resume(ports)).ok).toBe(false);
});
