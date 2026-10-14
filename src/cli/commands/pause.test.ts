import { expect, test } from "bun:test";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedLabel, MemoryPauseFlag } from "../../testing/fake-safety-ports";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

test("pause sets the local flag with the given reason", async () => {
  const pauseFlag = new MemoryPauseFlag();
  const io = captureIO();
  const ctx = commandContext(io, fakeSafetyPorts({ pauseFlag }));
  expect(await pauseCommand.run(["investigating", "#8524"], ctx)).toBe(0);
  expect(pauseFlag.flag?.reason).toBe("investigating #8524");
  expect(io.outLines[0]).toBe("✓ paused: investigating #8524");
});

test("pause without a reason uses a default", async () => {
  const pauseFlag = new MemoryPauseFlag();
  await pauseCommand.run([], commandContext(captureIO(), fakeSafetyPorts({ pauseFlag })));
  expect(pauseFlag.flag?.reason).toBe("paused with shipwright pause");
});

test("resume clears the flag and reminds about the label", async () => {
  const pauseFlag = new MemoryPauseFlag({ reason: "x", since: "", resumeAfter: null });
  const io = captureIO();
  expect(await resumeCommand.run([], commandContext(io, fakeSafetyPorts({ pauseFlag })))).toBe(0);
  expect(pauseFlag.flag).toBeNull();
  expect(io.outLines).toEqual([
    "✓ local pause flag cleared",
    "  A shipwright:pause label on any open issue still pauses dispatch everywhere.",
  ]);
});

test("paused exits 0 with reasons when paused, 1 when not", async () => {
  const io = captureIO();
  const labelled = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([5])) });
  expect(await pausedCommand.run([], commandContext(io, labelled))).toBe(0);
  expect(io.outLines).toEqual(["paused: label shipwright:pause on #5"]);
  const clear = captureIO();
  expect(await pausedCommand.run([], commandContext(clear, fakeSafetyPorts()))).toBe(1);
  expect(clear.outLines).toEqual(["not paused"]);
});

test("paused --no-github ignores the label", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([5])) });
  expect(await pausedCommand.run(["--no-github"], commandContext(captureIO(), ports))).toBe(1);
});

test("paused fails closed: an unreadable source counts as paused (exit 0)", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(err({ kind: "auth", message: "x" })) });
  expect(await pausedCommand.run([], commandContext(io, ports))).toBe(0);
  expect(io.errLines).toEqual(["✗ pause: cannot verify (auth): x"]);
});

test.each([[resumeCommand, ["extra"]]])("bad arguments exit 2", async (command, args) => {
  expect(await command.run(args, commandContext(captureIO()))).toBe(2);
});
