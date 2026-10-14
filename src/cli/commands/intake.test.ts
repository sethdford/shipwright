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

test("titles are never printed, on success, block or error paths", async () => {
  const secret = "SECRETTITLE\u001b]0;pwned\u0007";
  const rows = [{ number: 7, title: secret, labels: ["auto-patrol"] }];
  const cases: [string[], ReturnType<typeof fakeSafetyPorts>][] = [
    [["check", "--title", "other"], fakeSafetyPorts({ issues: fixedIssues(ok(rows)) })],
    [["check", "--title", "secrettitle"], fakeSafetyPorts({ issues: fixedIssues(ok(rows)) })],
    [
      ["check", "--title", "x"],
      fakeSafetyPorts({ issues: fixedIssues(err({ kind: "failed", message: "boom" })) }),
    ],
  ];
  for (const [args, ports] of cases) {
    const io = captureIO();
    await intakeCommand.run(args, commandContext(io, ports));
    const all = [...io.outLines, ...io.errLines].join("\n");
    expect(all).not.toContain("SECRETTITLE");
    expect(all).not.toContain("pwned");
    // biome-ignore lint/suspicious/noControlCharactersInRegex: asserting none are printed
    expect(all).not.toMatch(/[\u0000-\u0008\u000b-\u001f\u007f]/);
  }
});

test("--label chooses the auto label", async () => {
  const io = captureIO();
  const rows = [{ number: 1, title: "a", labels: ["bot-filed"] }];
  const ports = fakeSafetyPorts({ issues: fixedIssues(ok(rows)) });
  const args = ["check", "--label", "bot-filed", "--title", "new"];
  expect(await intakeCommand.run(args, commandContext(io, ports))).toBe(0);
  expect(io.outLines).toEqual(["✓ intake: 1 of 25 open auto-patrol issues"]);
});

test.each([
  [["check", "--label", ""]],
  [["check", "--label"]],
  [["check", "--label", "a\u0007b"]],
  [["check", "--label", "x".repeat(51)]],
  [["check", "--label", "a", "--label", "b"]],
])("bad label arguments %p exit 2", async (args) => {
  expect(await intakeCommand.run(args, commandContext(captureIO()))).toBe(2);
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
