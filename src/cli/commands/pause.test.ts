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

test("pause sanitizes the reason it stores and echoes", async () => {
  const pauseFlag = new MemoryPauseFlag();
  const io = captureIO();
  await pauseCommand.run(
    ["bad\u001b[2Jreason"],
    commandContext(io, fakeSafetyPorts({ pauseFlag })),
  );
  expect(pauseFlag.flag?.reason).toBe("bad[2Jreason");
  expect(io.outLines[0]).toBe("✓ paused: bad[2Jreason");
});

test("pause rejects option-like reasons with exit 2", async () => {
  const pauseFlag = new MemoryPauseFlag();
  const ctx = commandContext(captureIO(), fakeSafetyPorts({ pauseFlag }));
  expect(await pauseCommand.run(["--force"], ctx)).toBe(2);
  expect(pauseFlag.flag).toBeNull();
});

test("resume says so when no local flag was set", async () => {
  const io = captureIO();
  expect(await resumeCommand.run([], commandContext(io, fakeSafetyPorts()))).toBe(0);
  expect(io.outLines[0]).toBe("✓ no local pause flag was set");
});

const throwingLabel = fakeSafetyPorts({
  pauseLabel: {
    labelled: async () => {
      throw new Error("boom");
    },
  },
});

test("paused fails closed on bad arguments and thrown errors (exit 0)", async () => {
  expect(await pausedCommand.run(["--bogus"], commandContext(captureIO()))).toBe(0);
  const io = captureIO();
  expect(await pausedCommand.run([], commandContext(io, throwingLabel))).toBe(0);
  expect(io.errLines[0]).toContain("boom");
});

test("paused --gate: exit 0 only when not paused; every other outcome is non-zero", async () => {
  const clear = commandContext(captureIO(), fakeSafetyPorts());
  expect(await pausedCommand.run(["--gate"], clear)).toBe(0);
  const labelled = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([5])) });
  expect(await pausedCommand.run(["--gate"], commandContext(captureIO(), labelled))).toBe(1);
  const bad = fakeSafetyPorts({ pauseLabel: fixedLabel(err({ kind: "auth", message: "x" })) });
  expect(await pausedCommand.run(["--gate"], commandContext(captureIO(), bad))).toBe(1);
  expect(await pausedCommand.run(["--gate", "--bogus"], clear)).toBe(2);
  expect(await pausedCommand.run(["--gate"], commandContext(captureIO(), throwingLabel))).toBe(1);
});

test.each([[["-h", "--gate"]], [["--help", "--gate", "--no-github"]]])(
  "paused gate form with help mixed in %p is a usage error (non-zero)",
  async (args) => {
    expect(await pausedCommand.run(args, commandContext(captureIO()))).toBe(2);
  },
);

test("paused --help alone exits 0", async () => {
  expect(await pausedCommand.run(["--help"], commandContext(captureIO()))).toBe(0);
});

test.each([["true"], ["TRUE"], ["1"], ["yes"]])(
  "paused --gate --no-github is refused when GITHUB_ACTIONS=%p",
  async (value) => {
    const io = captureIO();
    const ctx = commandContext(io, fakeSafetyPorts(), { GITHUB_ACTIONS: value });
    expect(await pausedCommand.run(["--gate", "--no-github"], ctx)).toBe(2);
    expect(io.errLines[0]).toBe("✗ no-GitHub mode is not allowed on GitHub Actions");
  },
);

test("paused --no-github (human form) on Actions fails closed as paused", async () => {
  const ctx = commandContext(captureIO(), fakeSafetyPorts(), { GITHUB_ACTIONS: "true" });
  expect(await pausedCommand.run(["--no-github"], ctx)).toBe(0);
});

test.each([[{}], [{ GITHUB_ACTIONS: "" }], [{ GITHUB_ACTIONS: "false" }]])(
  "paused --gate --no-github off Actions (%p) skips the label and warns",
  async (env) => {
    const io = captureIO();
    const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([3])) });
    expect(await pausedCommand.run(["--gate", "--no-github"], commandContext(io, ports, env))).toBe(
      0,
    );
    expect(io.errLines).toEqual(["⚠ no-GitHub mode: not checked: shipwright:pause label"]);
  },
);
