import { expect, test } from "bun:test";
import type { SafetyPorts } from "../../contexts/orchestration";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedLabel, fixedRuns } from "../../testing/fake-safety-ports";
import { gatesCommand, parseGateArgs } from "./gates";

const run = (args: string[], ports: SafetyPorts = fakeSafetyPorts(), env = {}) => {
  const io = captureIO();
  return { io, code: gatesCommand.run(args, commandContext(io, ports, env)) };
};

test("check prints every gate and exits 0 when all are open", async () => {
  const { io, code } = run(["check", "--retry", "0"]);
  expect(await code).toBe(0);
  expect(io.outLines).toEqual([
    "✓ pause: not paused",
    "✓ breaker: closed (0 of the last 0 runs failed)",
    "✓ budget: no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
    "✓ review_wip: 0 agent PRs awaiting review + 0 runs in flight (limit 5)",
    "✓ fix_loop: first dispatch (retry 0 of 3)",
  ]);
});

test("check exits 1 at the first closed gate", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([3])) });
  const { io, code } = run(["check", "--retry", "0"], ports);
  expect(await code).toBe(1);
  expect(io.outLines).toEqual(["✗ pause: label shipwright:pause on #3"]);
});

test("check exits 1 when a source cannot be read", async () => {
  const ports = fakeSafetyPorts({ runs: fixedRuns(err({ kind: "auth", message: "HTTP 401" })) });
  const { io, code } = run(["check", "--retry", "1"], ports);
  expect(await code).toBe(1);
  expect(io.outLines.at(-1)).toBe("✗ breaker: cannot verify (auth): HTTP 401");
});

test("check exits 1 past the fix-loop cap", async () => {
  expect(await run(["check", "--retry", "4"]).code).toBe(1);
  expect(await run(["check", "--retry", "3"]).code).toBe(0);
});

test("check exits 1 when safety ports cannot be built", async () => {
  const io = captureIO();
  expect(await gatesCommand.run(["check", "--retry", "0"], commandContext(io))).toBe(1);
  expect(io.errLines[0]).toStartWith("✗ gates: cannot verify:");
});

test("--no-github and NO_GITHUB=true skip the GitHub gates", async () => {
  const ports = fakeSafetyPorts({ runs: fixedRuns(err({ kind: "auth", message: "no gh" })) });
  const flag = run(["check", "--retry", "0", "--no-github"], ports);
  expect(await flag.code).toBe(0);
  expect(flag.io.outLines[1]).toBe("- breaker: skipped (no GitHub)");
  const env = run(["check", "--retry", "0"], ports, { NO_GITHUB: "true" });
  expect(await env.code).toBe(0);
  expect(env.io.outLines[3]).toBe("- review_wip: skipped (no GitHub)");
  expect(await run(["check", "--retry", "0"], ports, { NO_GITHUB: "false" }).code).toBe(1);
});

test("no cost data is a warning, not a block", async () => {
  const costs = { read: async () => ok({ budget: null, entries: [], present: false }) };
  const { io, code } = run(["check", "--retry", "0"], fakeSafetyPorts({ costs }));
  expect(await code).toBe(0);
  expect(io.outLines[2]).toStartWith("⚠ budget: no cost data");
});

test("--json prints every gate's verdict, including those not reached", async () => {
  const ports = fakeSafetyPorts({ pauseLabel: fixedLabel(ok([3])) });
  const { io, code } = run(["check", "--retry", "0", "--json"], ports);
  expect(await code).toBe(1);
  expect(io.outLines).toHaveLength(1);
  expect(JSON.parse(io.outLines[0] ?? "")).toEqual({
    allowed: false,
    retry: 0,
    github: true,
    gates: [
      { gate: "pause", verdict: "blocked", detail: "label shipwright:pause on #3" },
      { gate: "breaker", verdict: "not_checked" },
      { gate: "budget", verdict: "not_checked" },
      { gate: "review_wip", verdict: "not_checked" },
      { gate: "fix_loop", verdict: "not_checked" },
    ],
  });
});

test("--json reports a failure to build ports as an error", async () => {
  const io = captureIO();
  expect(await gatesCommand.run(["check", "--retry", "0", "--json"], commandContext(io))).toBe(1);
  const out = JSON.parse(io.outLines[0] ?? "");
  expect(out.allowed).toBe(false);
  expect(out.error).toContain("not given safety ports");
});

test("parses --retry, --no-github and --json", () => {
  expect(parseGateArgs(["--retry", "2", "--no-github"])).toEqual({
    github: false,
    retry: 2,
    json: false,
  });
  expect(parseGateArgs(["--json", "--retry", "0"])).toEqual({ github: true, retry: 0, json: true });
});

test.each([
  [[]],
  [["--retry"]],
  [["--retry", "-1"]],
  [["--retry", "two"]],
  [["--retry", "1.5"]],
  [["--retry", "01"]],
  [["--retry", ""]],
  [["--retry", "99999999999999999999"]],
  [["--retry", "1", "--retry", "2"]],
  [["--retry", "1", "--force"]],
  [["--retry", "1", "extra"]],
])("rejects %p", (args) => {
  expect(parseGateArgs(args)).toBeNull();
});

test.each([
  [[]],
  [["status"]],
  [["check"]],
  [["check", "--json"]],
  [["check", "--retry", "x"]],
  [["check", "--retry", "0", "--bogus"]],
])("bad arguments %p exit 2", async (args) => {
  const { io, code } = run(args);
  expect(await code).toBe(2);
  expect(io.errLines[0]).toStartWith("✗ ");
});

test("--help exits 0 and documents the retry source", async () => {
  const { io, code } = run(["check", "--help"]);
  expect(await code).toBe(0);
  expect(io.outLines.join("\n")).toContain("--retry N");
});
