import { expect, test } from "bun:test";
import { err, ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { fakeSafetyPorts, fixedIssues } from "../../testing/fake-safety-ports";
import { intakeCommand } from "./intake";

const auto = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    number: i + 1,
    title: `t${i}x`,
    labels: ["auto-patrol"],
  }));

test("check exits 0 under the cap with no duplicate", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(auto(3))) });
  expect(
    await intakeCommand.run(["check", "--title", "New finding"], commandContext(io, ports)),
  ).toBe(0);
  expect(io.outLines).toEqual(["✓ intake: 3 of 25 open auto-patrol issues"]);
});

test("check exits 1 at the cap", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(auto(25))) });
  expect(await intakeCommand.run(["check"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual(["✗ intake: 25 of 25 open auto-patrol issues (cap reached)"]);
});

test("check exits 1 for a duplicate title", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(auto(1))) });
  expect(await intakeCommand.run(["check", "--title", "T0X"], commandContext(io, ports))).toBe(1);
  expect(io.outLines).toEqual(["✗ intake: 1 of 25 open auto-patrol issues; duplicate of #1"]);
});

test("an unreadable issue list blocks (exit 1)", async () => {
  const io = captureIO();
  const ports = fakeSafetyPorts({ issues: fixedIssues(err({ kind: "auth", message: "x" })) });
  expect(await intakeCommand.run(["check"], commandContext(io, ports))).toBe(1);
});

test("an issue list that cannot be trusted never prints its titles", async () => {
  const io = captureIO();
  const rows = [{ number: 7, title: "evil\u001b]0;pwned\u0007", labels: ["auto-patrol"] }];
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(rows)) });
  await intakeCommand.run(["check", "--title", "evil"], commandContext(io, ports));
  // biome-ignore lint/suspicious/noControlCharactersInRegex: asserting none are printed
  expect(io.outLines.join("\n")).not.toMatch(/[\u0000-\u0008\u000b-\u001f\u007f]/);
});

test.each([
  [[]],
  [["check", "--title"]],
  [["check", "--title", ""]],
  [["check", "--title", "   "]],
  [["check", "--bogus", "x"]],
])("bad arguments %p exit 2", async (args) => {
  expect(await intakeCommand.run(args, commandContext(captureIO()))).toBe(2);
});
