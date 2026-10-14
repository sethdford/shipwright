import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import { fakeSafetyPorts, fixedIssues } from "../../../testing/fake-safety-ports";
import { checkIntake } from "./intake";

test("evaluates the candidate title against open issues", async () => {
  const issues = fixedIssues(ok([{ number: 4, title: "Stale docs", labels: ["auto-patrol"] }]));
  expect(await checkIntake(fakeSafetyPorts({ issues }), "stale DOCS")).toEqual({
    ok: true,
    value: { allowed: false, openAuto: 1, cap: 25, duplicateOf: 4 },
  });
});

test("an unreadable issue list is an error (callers fail closed)", async () => {
  const issues = fixedIssues(err({ kind: "transient", message: "HTTP 502" }));
  expect((await checkIntake(fakeSafetyPorts({ issues }), null)).ok).toBe(false);
});

test("the label option selects which issues count toward the cap", async () => {
  const issues = fixedIssues(ok([{ number: 4, title: "x", labels: ["bot-filed"] }]));
  const ports = fakeSafetyPorts({ issues });
  expect(await checkIntake(ports, null, "bot-filed")).toMatchObject({ value: { openAuto: 1 } });
  expect(await checkIntake(ports, null)).toMatchObject({ value: { openAuto: 0 } });
});
