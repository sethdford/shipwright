import { expect, test } from "bun:test";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedCosts, NOW } from "../../testing/fake-safety-ports";
import { budgetCommand } from "./budget";

const today = Math.floor(NOW / 1000);
const ports = (spentUsd: number) =>
  fakeSafetyPorts({
    costs: fixedCosts({ limitUsd: 10 }, [{ costUsd: spentUsd, atEpochS: today }]),
  });

test("check exits 0 under the cap", async () => {
  const io = captureIO();
  expect(await budgetCommand.run(["check"], commandContext(io, ports(3.2)))).toBe(0);
  expect(io.outLines).toEqual(["✓ budget: $3.20 of $10.00 spent today (UTC); $6.80 left"]);
});

test("check exits 1 at the cap, and when an estimate would cross it", async () => {
  expect(await budgetCommand.run(["check"], commandContext(captureIO(), ports(10)))).toBe(1);
  const io = captureIO();
  const args = ["check", "--estimate", "7"];
  expect(await budgetCommand.run(args, commandContext(io, ports(3.2)))).toBe(1);
  expect(io.outLines).toEqual(["✗ budget: $3.20 of $10.00 spent today (UTC); $6.80 left"]);
});

test("no cap is allowed and says how to set one", async () => {
  const io = captureIO();
  expect(await budgetCommand.run(["status"], commandContext(io, fakeSafetyPorts()))).toBe(0);
  expect(io.outLines).toEqual([
    "✓ budget: no daily cap ($0.00 spent today); set one with: shipwright cost budget set <usd>",
  ]);
});

test("no cost files passes visibly as not enforced", async () => {
  const costs = { read: async () => ok({ budget: null, entries: [], present: false }) };
  const io = captureIO();
  expect(await budgetCommand.run(["check"], commandContext(io, fakeSafetyPorts({ costs })))).toBe(
    0,
  );
  expect(io.outLines).toEqual([
    "⚠ budget: no cost data (no budget.json or costs.json found); budget not enforced",
  ]);
});

test("status exits 0 even when over the cap", async () => {
  expect(await budgetCommand.run(["status"], commandContext(captureIO(), ports(12)))).toBe(0);
});

test("an unreadable ledger blocks (exit 1)", async () => {
  const costs = { read: async () => err({ kind: "failed" as const, message: "bad json" }) };
  const io = captureIO();
  expect(await budgetCommand.run(["check"], commandContext(io, fakeSafetyPorts({ costs })))).toBe(
    1,
  );
  expect(io.errLines).toEqual(["✗ budget: cannot verify (failed): bad json"]);
});

test.each([[[]], [["check", "--estimate"]], [["check", "--estimate", "-1"]], [["spend"]]])(
  "bad arguments %p exit 2",
  async (args) => {
    expect(await budgetCommand.run(args, commandContext(captureIO()))).toBe(2);
  },
);

test("a partial or fail-open-shaped ledger blocks check (exit 1)", async () => {
  const costs = {
    read: async () => err({ kind: "failed" as const, message: "costs.json: entries missing" }),
  };
  expect(
    await budgetCommand.run(["check"], commandContext(captureIO(), fakeSafetyPorts({ costs }))),
  ).toBe(1);
});

test("status exits 1 when the files cannot be read", async () => {
  const costs = { read: async () => err({ kind: "failed" as const, message: "bad" }) };
  expect(
    await budgetCommand.run(["status"], commandContext(captureIO(), fakeSafetyPorts({ costs }))),
  ).toBe(1);
});

test("usage documents the >= rule and the mis-set HOME caveat", () => {
  expect(budgetCommand.usage).toContain("exactly the cap");
  expect(budgetCommand.usage).toContain("HOME");
  expect(budgetCommand.usage).toContain("unless the files cannot be read");
});

test.each([
  [["-h", "check"]],
  [["check", "--estimate", "-h"]],
  [["check", "--estimate", "1", "--help"]],
])("help mixed with other arguments %p is a usage error", async (args) => {
  expect(await budgetCommand.run(args, commandContext(captureIO()))).toBe(2);
});

test.each([[["--help"]], [["check", "-h"]]])("help alone %p exits 0", async (args) => {
  const io = captureIO();
  expect(await budgetCommand.run(args, commandContext(io))).toBe(0);
  expect(io.outLines.join("\n")).toContain("USAGE");
});
