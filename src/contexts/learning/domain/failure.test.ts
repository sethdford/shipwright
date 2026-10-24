import { describe, expect, test } from "bun:test";
import { classifyFailure, failureFingerprint, lastErrorLine } from "./failure";

describe("classifyFailure", () => {
  test("a typed kind wins over text", () => {
    expect(classifyFailure({ kind: "auth", text: "rate limit exceeded" })).toBe("auth");
  });

  test("the pre-flight auth text from ci.yml is an auth failure", () => {
    const text =
      "::error::Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret";
    expect(classifyFailure({ text })).toBe("auth");
  });

  test("auth outranks transient when a log has both", () => {
    expect(classifyFailure({ text: "429 rate limit\nAPI Error: 401 unauthorized" })).toBe("auth");
  });

  test("a mention of the token variable alone is not an auth failure", () => {
    expect(classifyFailure({ text: "CLAUDE_CODE_OAUTH_TOKEN is documented in README" })).toBe(
      "unknown",
    );
  });

  test("bun install logs with a healthy lockfile are not environment failures", () => {
    const text = "bun install v1.2.19\nLockfile: bun.lock\nInstalled 812 packages";
    expect(classifyFailure({ text })).toBe("unknown");
  });

  test("a missing binary on an error line is an environment failure", () => {
    expect(classifyFailure({ text: "setup step\nbun: command not found" })).toBe("environment");
  });

  test("a permission error outside node_modules is not an environment failure", () => {
    expect(classifyFailure({ text: "EACCES: permission denied, open '/etc/hosts'" })).toBe(
      "unknown",
    );
  });

  test("text with no known pattern is unknown, not a guess", () => {
    expect(classifyFailure({ text: "TypeError: cannot read properties of undefined" })).toBe(
      "unknown",
    );
  });
});

describe("contamination signals (one test per signal)", () => {
  test("the test-gate refusal from sw-e2e-integration-test.sh is contamination", () => {
    const text = "⚠ Skipping integration tests: refusing to run inside a build-loop test gate";
    expect(classifyFailure({ text })).toBe("contamination");
  });

  test("a loop-recorded missing .claude/pipeline-state.md is contamination", () => {
    expect(
      classifyFailure({ text: "iteration 4 done\nCONTAMINATION: pipeline-state-missing\n" }),
    ).toBe("contamination");
  });

  test("a loop-recorded branch switch is contamination", () => {
    expect(classifyFailure({ text: "CONTAMINATION: branch-switched wave2/plan -> main" })).toBe(
      "contamination",
    );
  });
});

describe("failureFingerprint", () => {
  test("is stable across digits and paths in the last error line", () => {
    const a = failureFingerprint("execution", "build failed at /tmp/x/42 line 7");
    const b = failureFingerprint("execution", "build failed at /tmp/y/9 line 3");
    expect(a).toBe(b);
  });

  test("ignores a different preamble when the last error line is the same", () => {
    const a = failureFingerprint("execution", "step 1 ok\nbuild failed: tsc exit 2");
    const b = failureFingerprint(
      "execution",
      "compiling 900 files\nstep 9\nbuild failed: tsc exit 2",
    );
    expect(a).toBe(b);
  });

  test("differs when the class differs", () => {
    expect(failureFingerprint("auth", "x fail")).not.toBe(
      failureFingerprint("transient", "x fail"),
    );
  });

  test("lastErrorLine prefers the last error-looking line", () => {
    expect(lastErrorLine("ok\nerror: first\nmore output\nfatal: last\ntrailer")).toBe(
      "fatal: last",
    );
  });
});
