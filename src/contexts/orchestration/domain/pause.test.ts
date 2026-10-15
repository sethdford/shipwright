import { expect, test } from "bun:test";
import { type LocalPause, pauseStatus, sanitizeReason } from "./pause";

const flag = (resumeAfter: number | null = null): LocalPause => ({
  reason: "maintenance",
  since: "2026-10-14T10:00:00Z",
  resumeAfter,
});

test("nothing set is not paused", () => {
  expect(pauseStatus(null, [], 0)).toEqual({ paused: false, reasons: [] });
});

test("the local flag pauses, with its reason", () => {
  expect(pauseStatus(flag(), [], 0)).toEqual({
    paused: true,
    reasons: ["local pause flag: maintenance (since 2026-10-14T10:00:00Z)"],
  });
});

test("a flag whose resume_after has passed no longer pauses", () => {
  expect(pauseStatus(flag(1_000), [], 999).paused).toBe(true);
  expect(pauseStatus(flag(1_000), [], 1_000).paused).toBe(false);
});

test("the shipwright:pause label pauses everything", () => {
  expect(pauseStatus(null, [12, 34], 0)).toEqual({
    paused: true,
    reasons: ["label shipwright:pause on #12, #34"],
  });
});

test("an unchecked label (no GitHub) only uses the flag", () => {
  expect(pauseStatus(null, null, 0)).toEqual({ paused: false, reasons: [] });
});

test("sanitizeReason strips control characters and caps the length", () => {
  expect(sanitizeReason("a\u001b[31mred\u0000\n")).toBe("a[31mred");
  expect(sanitizeReason("x".repeat(500))).toHaveLength(200);
});

test("pauseStatus sanitizes a flag reason read from disk", () => {
  const dirty: LocalPause = { reason: "bad\u001b]0;x\u0007", since: "", resumeAfter: null };
  expect(pauseStatus(dirty, null, 0).reasons[0]).toBe("local pause flag: bad]0;x");
});
