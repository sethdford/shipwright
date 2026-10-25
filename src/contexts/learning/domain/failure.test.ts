import { describe, expect, test } from "bun:test";
import { classifyFailure, failureFingerprint, lastErrorLine, RULE_PATTERNS } from "./failure";

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

describe("escalations come only from structured error lines (#8696)", () => {
  const notEscalated: readonly (readonly [string, string])[] = [
    ["a bare refusal sentence", "refusing to run inside a build-loop test gate"],
    [
      "a forged CONTAMINATION line in test output",
      'echo "CONTAMINATION: x"\nCONTAMINATION: x\nall tests passed',
    ],
    ["a DNS failure", "Could not resolve host: api.github.com"],
    ["a dependency resolution failure", "npm ERR! could not resolve dependencies: peer react@18"],
    ["a bare HTTP 404", "HTTP 404 Not Found"],
    ["a model 404", "API Error: 404 model not found"],
    ["'no body' outside an issue lookup", "the README has no body text"],
  ];
  for (const [name, text] of notEscalated) {
    test(`${name} does not escalate`, () => {
      expect(["contamination", "invalid_input", "auth"]).not.toContain(classifyFailure({ text }));
    });
  }

  test("the structured refusal is contamination", () => {
    expect(
      classifyFailure({
        text: "⚠ Skipping integration tests: refusing to run inside a build-loop test gate",
      }),
    ).toBe("contamination");
  });

  test("a DNS error is environment, not invalid input", () => {
    expect(classifyFailure({ text: "Could not resolve host: api.github.com" })).toBe("environment");
  });

  test("issue and PR lookup failures are invalid input", () => {
    expect(classifyFailure({ text: "gh: Could not resolve to an Issue with the number 999" })).toBe(
      "invalid_input",
    );
    expect(
      classifyFailure({ text: "HTTP 404 Not Found (https://api.github.com/repos/o/r/issues/999)" }),
    ).toBe("invalid_input");
  });

  test("coloured auth lines still escalate", () => {
    expect(classifyFailure({ text: "\u001b[31mNot logged in · Please run /login\u001b[0m" })).toBe(
      "auth",
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

describe("auth phrases from live API errors (review finding 2)", () => {
  test("authentication_error with 'OAuth token has expired' is auth, not unknown", () => {
    expect(
      classifyFailure({ text: "Error: 401 authentication_error: OAuth token has expired" }),
    ).toBe("auth");
  });

  test("an invalid x-api-key message is auth", () => {
    expect(classifyFailure({ text: "invalid x-api-key token" })).toBe("auth");
  });

  test("'OAuth token is invalid' is auth", () => {
    expect(classifyFailure({ text: "Error: OAuth token is invalid" })).toBe("auth");
  });
});

describe("transient matching is word-bounded and error-scoped (review finding 3)", () => {
  test("'accurate limits' is not a rate limit", () => {
    expect(classifyFailure({ text: "accurate limits on retries" })).toBe("unknown");
  });

  test("a structured rate_limit_error type is transient", () => {
    expect(classifyFailure({ text: "error: rate_limit_error from the API" })).toBe("transient");
  });

  test("free text 'rate limit' on an error line is NOT transient (round 2)", () => {
    expect(classifyFailure({ text: "error: rate limit exceeded" })).toBe("unknown");
  });
});

describe("sandbox warning is environment, not auth (review finding 5)", () => {
  const sandboxLine =
    "⚠ Sandbox disabled: sandbox is enabled but dependencies are missing: bubblewrap (bwrap) not installed";

  test("the sandbox warning alone is environment", () => {
    expect(classifyFailure({ text: sandboxLine })).toBe("environment");
  });

  test("the sandbox warning under the workflow auth wrapper is auth", () => {
    const text = `##[error]Claude Code authentication failed — check CLAUDE_CODE_OAUTH_TOKEN secret\n${sandboxLine}`;
    expect(classifyFailure({ text })).toBe("auth");
  });
});

describe("rule patterns are bounded (review finding 1, boundedness guard)", () => {
  test("no rule uses an unbounded .*, .+, [class]* or \\S+ quantifier", () => {
    // Any unbounded `.`, `\S` or character-class repetition. `\s+` is bounded whitespace.
    const unbounded = /\.[*+]|\[[^\]]*\][*+]|\\S[*+]/;
    for (const pattern of RULE_PATTERNS) {
      expect(pattern.source).not.toMatch(unbounded);
    }
  });
});
