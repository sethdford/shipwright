import { expect, test } from "bun:test";
import { evaluateIntake, type IssueSummary, titleFingerprint } from "./intake";

const issue = (number: number, title: string, labels: string[] = []): IssueSummary => ({
  number,
  title,
  labels,
});
const policy = { autoLabel: "auto-patrol", maxOpenAuto: 2 };

test("fingerprints ignore case, numbers and punctuation", () => {
  expect(titleFingerprint("Security: lodash 4.17.20 in package-lock")).toBe(
    titleFingerprint("security — LODASH 4.17.21 in package_lock"),
  );
  expect(titleFingerprint("Decompose `sw-memory.sh`")).not.toBe(
    titleFingerprint("Decompose `sw-loop.sh`"),
  );
});

test("fingerprints normalise unicode forms and drop control characters", () => {
  expect(titleFingerprint("Ｆｉｘ the bug")).toBe(titleFingerprint("fix the bug"));
  expect(titleFingerprint("fix\u001b the\u0000 bug‮")).toBe(titleFingerprint("fix the bug"));
  expect(titleFingerprint("修复 错误 12")).not.toBe(titleFingerprint("修复 其他 12"));
});

test("allows filing under the cap with no duplicate", () => {
  const open = [issue(1, "Flaky test in sw-loop", ["auto-patrol"])];
  expect(evaluateIntake(open, "Stale docs in README", policy)).toEqual({
    allowed: true,
    openAuto: 1,
    cap: 2,
    duplicateOf: null,
  });
});

test("blocks a near-duplicate of any open issue", () => {
  const open = [issue(8524, "Classify and cap duplicate build-loop errors (3 seen)")];
  expect(
    evaluateIntake(open, "classify and cap duplicate build loop errors (5 seen)", policy),
  ).toEqual({
    allowed: false,
    openAuto: 0,
    cap: 2,
    duplicateOf: 8524,
  });
});

test("blocks at the cap of open auto-filed issues, with or without a title", () => {
  const open = [issue(1, "a", ["auto-patrol"]), issue(2, "b", ["auto-patrol"]), issue(3, "c")];
  expect(evaluateIntake(open, null, policy)).toMatchObject({ allowed: false, openAuto: 2 });
  expect(evaluateIntake(open.slice(1), null, policy).allowed).toBe(true);
});
