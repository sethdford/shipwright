import { expect, test } from "bun:test";
import type { RunRecord } from "../../contexts/orchestration";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import {
  fakeSafetyPorts,
  fixedRuns,
  NOW,
  RecordingGithubWriter,
} from "../../testing/fake-safety-ports";
import { breakerCommand } from "./breaker";

const failures: RunRecord[] = [0, 1, 2, 3, 4].map((i) => ({
  id: `r${i}`,
  startedAt: NOW - 600_000,
  finished: { at: NOW - 60_000 * (5 - i), outcome: "failure" },
}));

test("check exits 0 when closed", async () => {
  const io = captureIO();
  expect(await breakerCommand.run(["check"], commandContext(io, fakeSafetyPorts()))).toBe(0);
  expect(io.outLines).toEqual(["✓ breaker: closed (0 of the last 0 runs failed)"]);
});

test("check exits 1 when open and reports the incident", async () => {
  const io = captureIO();
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) });
  expect(await breakerCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual([
    "✗ breaker: open since 2026-10-14T11:59:00.000Z; probe allowed after 2026-10-14T12:29:00.000Z",
    "  incident #900 (created)",
  ]);
  expect(github.calls).toHaveLength(1);
});

test("status reports an open breaker, exits 0 and never writes", async () => {
  const io = captureIO();
  const github = new RecordingGithubWriter();
  const ports = fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) });
  expect(await breakerCommand.run(["status"], commandContext(io, ports))).toBe(0);
  expect(io.outLines[0]).toStartWith("✗ breaker: open since");
  expect(github.calls).toHaveLength(0);
});

test("an unreadable run history blocks (exit 1)", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ runs: fixedRuns(err({ kind: "auth", message: "HTTP 401" })) });
  expect(await breakerCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.errLines).toEqual(["✗ breaker: cannot verify (auth): HTTP 401"]);
});

test.each([[[]], [["nope"]], [["check", "extra"]]])("bad arguments %p exit 2", async (args) => {
  const io = captureIO();
  expect(await breakerCommand.run(args, commandContext(io))).toBe(2);
  expect(io.outLines.join("\n")).toContain("USAGE\n  shipwright breaker <status|check>");
});

test("--help prints usage and exits 0", async () => {
  const io = captureIO();
  expect(await breakerCommand.run(["--help"], commandContext(io))).toBe(0);
});

test("an open breaker with a failing incident writer reports it on stderr and exits 1", async () => {
  const io = captureIO();
  const github = new RecordingGithubWriter(err({ kind: "failed", message: "HTTP 500" }));
  const ports = fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) });
  expect(await breakerCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toHaveLength(1);
  expect(io.errLines).toEqual(["  ✗ incident not recorded: HTTP 500"]);
});

test("--json prints one object and keeps the exit codes", async () => {
  const open = fakeSafetyPorts({ runs: fixedRuns(ok(failures)) });
  const io = captureIO();
  expect(await breakerCommand.run(["check", "--json"], commandContext(io, open))).toBe(1);
  expect(io.outLines).toHaveLength(1);
  expect(JSON.parse(io.outLines[0] as string)).toEqual({
    state: "open",
    allowed: false,
    since: NOW - 60_000,
    probeAfter: NOW - 60_000 + 30 * 60_000,
    incident: { issue: 900, action: "created" },
  });

  const io2 = captureIO();
  expect(await breakerCommand.run(["--json", "status"], commandContext(io2, open))).toBe(0);
  expect(JSON.parse(io2.outLines[0] as string).state).toBe("open");

  const io3 = captureIO();
  const bad = fakeSafetyPorts({ runs: fixedRuns(err({ kind: "auth", message: "HTTP 401" })) });
  expect(await breakerCommand.run(["status", "--json"], commandContext(io3, bad))).toBe(1);
  expect(JSON.parse(io3.outLines[0] as string)).toMatchObject({
    allowed: false,
    error: "HTTP 401",
  });
});

test("--json reports incidentError", async () => {
  const io = captureIO();
  const github = new RecordingGithubWriter(err({ kind: "failed", message: "HTTP 500" }));
  const ports = fakeSafetyPorts({ github, runs: fixedRuns(ok(failures)) });
  expect(await breakerCommand.run(["check", "--json"], commandContext(io, ports))).toBe(1);
  expect(JSON.parse(io.outLines[0] as string).incidentError).toBe("HTTP 500");
});

test("help after a subcommand prints usage", async () => {
  const io = captureIO();
  expect(await breakerCommand.run(["check", "-h"], commandContext(io))).toBe(0);
  expect(io.outLines.join("\n")).toContain("USAGE");
});

test.each([[["check", "-h", "extra"]], [["status", "--json", "--help"]], [["-h", "check"]]])(
  "help mixed with other arguments %p is a usage error",
  async (args) => {
    expect(await breakerCommand.run(args, commandContext(captureIO()))).toBe(2);
  },
);
