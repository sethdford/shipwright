import { describe, expect, test } from "bun:test";
import { type Attempt, classifyAndDecide } from "../index";
import {
  boundEvidence,
  dropTestTitles,
  MAX_EVIDENCE_LINE_CHARS,
  MAX_EVIDENCE_LINES,
} from "./evidence";

describe("bounded evidence (review finding 1)", () => {
  test("a 1 MB single line classifies in under 100 ms", () => {
    const text = `issue ${"x".repeat(1_000_000)} does not exist`;
    const start = performance.now();
    const result = classifyAndDecide({ text, attempts: [] });
    expect(performance.now() - start).toBeLessThan(100);
    expect(result.class).toBe("unknown");
  });

  test("a 2.4 MB single line also finishes quickly", () => {
    const text = "enoent ".repeat(300_000);
    const start = performance.now();
    classifyAndDecide({ text, attempts: [] });
    expect(performance.now() - start).toBeLessThan(100);
  });

  test("only the last MAX_EVIDENCE_LINES lines are kept, like bash tail -200", () => {
    const lines = Array.from({ length: 500 }, (_, i) => `line ${i}`);
    const bounded = boundEvidence(lines.join("\n")).split("\n");
    expect(bounded).toHaveLength(MAX_EVIDENCE_LINES);
    expect(bounded.at(-1)).toBe("line 499");
  });

  test("each line is cut to MAX_EVIDENCE_LINE_CHARS", () => {
    const [line] = boundEvidence("y".repeat(10_000)).split("\n");
    expect(line?.length).toBe(MAX_EVIDENCE_LINE_CHARS);
  });

  test("a failure only in lines before the tail window is not seen", () => {
    const old = "Error: 401 authentication_error: OAuth token has expired";
    const tail = Array.from({ length: MAX_EVIDENCE_LINES }, () => "progress");
    const result = classifyAndDecide({ text: [old, ...tail].join("\n"), attempts: [] });
    expect(result.class).toBe("unknown");
  });
});

describe("model prose cannot change the class or the stop (review finding 3)", () => {
  test("a deterministic failure plus model text saying 'rate limit' stops on the second identical fingerprint", () => {
    const text =
      "build failed: tsc exit 2\nFailure analyzed: rate limit on retries, accurate limits";
    const first = classifyAndDecide({ text, attempts: [] });
    expect(first.decision.action).toBe("retry");
    const attempts: Attempt[] = [{ cls: first.class, fingerprint: first.fingerprint }];
    const second = classifyAndDecide({ text, attempts });
    expect(second.class).not.toBe("transient");
    expect(second.decision.action).toBe("escalate");
    if (second.decision.action === "escalate") {
      expect(second.decision.reason).toContain("same failure twice");
    }
  });

  test("a model diagnosis that mentions 401 unauthorized is not auth", () => {
    const text = "build failed: tsc exit 2\n✓ Failure analyzed: 401 unauthorized in the mock";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("unknown");
  });

  test("progress markers are not evidence", () => {
    const text = "▸ Iteration 2/10 — rate limit warning\nbuild failed: tsc exit 2";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("unknown");
  });
});

// #8696: colour codes and the gh log prefix are removed before any rule runs, so the anchored forms still match.
describe("normalization before the rules (#8696)", () => {
  test("the coloured structured refusal is contamination", () => {
    const text =
      "\u001b[33m⚠ Skipping integration tests: refusing to run inside a build-loop test gate\u001b[0m";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("contamination");
  });

  test("the gh-prefixed structured refusal is contamination", () => {
    const text =
      "build\tTest\t2026-10-24T13:51:24.7812544Z ⚠ Skipping integration tests: refusing to run inside a build-loop test gate";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("contamination");
  });

  test("a coloured CONTAMINATION line is contamination", () => {
    expect(
      classifyAndDecide({
        text: "\u001b[31mCONTAMINATION: branch-switched a -> b\u001b[0m",
        attempts: [],
      }).class,
    ).toBe("contamination");
  });
});

test("a coloured auth line is auth (normalized before the anchored rule)", () => {
  expect(
    classifyAndDecide({
      text: "\u001b[31mNot logged in · Please run /login\u001b[0m",
      attempts: [],
    }).class,
  ).toBe("auth");
});

describe("test-runner title lines never reach the rules (#8696)", () => {
  test("bun, jest, vitest, node:test and mocha title lines are dropped; other lines are kept", () => {
    const text = [
      "(fail) not logged in [1ms]",
      "(pass) ok",
      "  ✕ API Error: 401 when token missing (3 ms)",
      "  ✓ passes",
      "  ● not logged in",
      "   × authentication_error maps to auth",
      "√ ok",
      "✔ ok",
      "✖ failed to authenticate when password wrong",
      "  1) issue not found: shows empty state",
      "✗ Not logged in · Please run /login",
      "error: expect(received).toBe(expected)",
    ].join("\n");
    expect(dropTestTitles(text)).toBe(
      "✗ Not logged in · Please run /login\nerror: expect(received).toBe(expected)",
    );
  });

  test("a failing test titled with an auth phrase is not auth", () => {
    const text =
      "  ✕ API Error: 401 when token missing (3 ms)\nerror: expect(received).toBe(expected)";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("unknown");
  });

  test("the fingerprint still sees the title, so two different failing tests group apart", () => {
    // bun prints the assertion first and the `(fail)` title last, so the title is the last error line.
    const a = classifyAndDecide({ text: "error: expected\n(fail) a > one", attempts: [] });
    const b = classifyAndDecide({ text: "error: expected\n(fail) b > two", attempts: [] });
    expect(a.class).toBe(b.class);
    expect(a.fingerprint).not.toBe(b.fingerprint);
  });
});
