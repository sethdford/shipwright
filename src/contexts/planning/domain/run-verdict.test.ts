import { describe, expect, test } from "bun:test";
import { greenVerdict, redVerdict } from "./run-verdict";

const P = "tests/login.test.ts";
const AC = ["AC-1"];
const run = (exitCode: number, output: string, timedOut = false) => ({
  exitCode,
  output,
  timedOut,
});

describe("redVerdict: fails for the right reason", () => {
  test.each([
    [
      "bun assertion",
      run(
        1,
        `${P}:\n(fail) AC-1: rejects expired\nexpect(received).toBe(expected)\n 0 pass\n 1 fail`,
      ),
      "assertion",
    ],
    [
      "missing module",
      run(1, `error: Cannot find module './login' from '${P}'`),
      "missing_feature",
    ],
    [
      "missing export (bun)",
      run(1, `SyntaxError: Export named 'login' not found in module '/r/src/auth.ts'.\n${P}`),
      "missing_feature",
    ],
    [
      "python import",
      run(
        1,
        "tests/test_login.py:3: ImportError: cannot import name 'login'\nFAILED tests/test_login.py::test_AC_1",
      ),
      "missing_feature",
    ],
    [
      "go undefined",
      run(2, "# pkg/auth [pkg/auth.test]\n./token_test.go:9:2: undefined: Verify (AC-1)"),
      "missing_feature",
    ],
  ])("%s", (_name, r, reason) => {
    expect(redVerdict(r, P, AC)).toMatchObject({ ok: true, reason });
  });
});

describe("redVerdict: rejects the wrong reasons", () => {
  test.each([
    ["already passes", run(0, `${P}: 1 pass`), "passed"],
    ["timeout", run(124, "", true), "timeout"],
    ["no tests", run(1, `${P}:\n 0 pass\n 0 fail`), "no_tests"],
    ["pytest collected nothing", run(5, "collected 0 items"), "no_tests"],
    [
      "syntax error in the test",
      run(1, `${P}:4:7 SyntaxError: Unexpected token '}'`),
      "test_broken",
    ],
    [
      "bun parse error",
      run(
        1,
        `${P}:\n# Unhandled error between tests\nerror: Expected ")" but found ";"\n 0 pass\n 1 fail\n 1 error`,
      ),
      "test_broken",
    ],
    ["missing framework", run(1, "Error: Cannot find module 'vitest'"), "environment"],
    ["runner missing", run(127, "bash: pytest: command not found"), "environment"],
    [
      "failure names another file",
      run(1, "tests/other.test.ts: expect(received).toBe(expected)\n 1 fail"),
      "not_this_test",
    ],
    ["unexplained", run(1, "something went wrong"), "unexplained"],
  ])("%s", (_name, r, reason) => {
    expect(redVerdict(r, P, AC)).toMatchObject({ ok: false, reason });
  });
});

describe("greenVerdict", () => {
  test("passes only when the run passed and ran something", () => {
    expect(greenVerdict(run(0, " 1 pass\n 0 fail\n 1 expect() calls")).ok).toBe(true);
    expect(greenVerdict(run(1, `${P}: expect(a).toBe(b)`)).ok).toBe(false);
    expect(greenVerdict(run(0, `${P}\n 0 pass\n 0 fail`))).toMatchObject({ reason: "no_tests" });
    expect(greenVerdict(run(0, " 0 pass\n 2 skip\n 0 fail"))).toMatchObject({
      ok: false,
      reason: "no_tests",
    });
    expect(greenVerdict(run(0, "", true))).toMatchObject({ reason: "timeout" });
  });
});
