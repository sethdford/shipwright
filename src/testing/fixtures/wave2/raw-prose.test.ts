import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { classifyAndDecide, classifyFailure } from "../../../contexts/learning";

// Round 2: free text that says "rate limit" must never make a deterministic failure transient.
// These are raw captures (colour codes, gh's tab prefix, a loop commit subject, an agent test name).
const RAW_CASES = [
  "color-analysis.log",
  "gh-prefixed-analysis.log",
  "branch-name.log",
  "agent-test-name.log",
  "unicode-analysis.log",
] as const;

// Lines that start with "# " are fixture metadata, not log content.
function loadRaw(name: string): string {
  return readFileSync(new URL(`raw/${name}`, import.meta.url), "utf8")
    .split("\n")
    .filter((line) => !line.startsWith("# "))
    .join("\n");
}

describe("free-text 'rate limit' is never transient, and a repeat stops", () => {
  for (const name of RAW_CASES) {
    test(`${name}: not transient, and the second identical failure escalates`, () => {
      const text = loadRaw(name);
      const first = classifyAndDecide({ text, attempts: [] });
      expect(first.class).not.toBe("transient");
      const second = classifyAndDecide({
        text,
        attempts: [{ cls: first.class, fingerprint: first.fingerprint }],
      });
      expect(second.decision.action).toBe("escalate");
    });
  }
});

describe("structured transient signals stay transient", () => {
  const STRUCTURED = [
    "HTTP 429 Too Many Requests",
    "HTTP/1.1 503 Service Unavailable",
    "status: 429",
    '{"status":429,"error":"busy"}',
    "503 Service Unavailable",
    "502 Bad Gateway",
    "API Error: 429",
    "error type rate_limit_error",
    "overloaded_error from upstream",
    "api_error from upstream",
    "read ECONNRESET",
    "connect ETIMEDOUT 1.2.3.4:443",
    "getaddrinfo EAI_AGAIN api.anthropic.com",
    "Retry-After: 30",
  ];

  for (const line of STRUCTURED) {
    test(`"${line}" is transient`, () => {
      expect(classifyFailure({ text: line })).toBe("transient");
    });
  }

  test("a structured signal under colour codes is still transient", () => {
    const text = "\x1b[31mHTTP 429\x1b[0m too many requests";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("transient");
  });

  test("a structured signal behind the gh --log-failed prefix is still transient", () => {
    const text =
      "pipeline\tRun Shipwright pipeline\t2026-10-15T13:39:00Z HTTP 503 Service Unavailable";
    expect(classifyAndDecide({ text, attempts: [] }).class).toBe("transient");
  });

  test("three identical transient failures in a row escalate, whatever the class", () => {
    const text = "HTTP 429 Too Many Requests";
    const first = classifyAndDecide({ text, attempts: [] });
    const attempts = [{ cls: first.class, fingerprint: first.fingerprint }];
    const second = classifyAndDecide({ text, attempts });
    attempts.push({ cls: second.class, fingerprint: second.fingerprint });
    const third = classifyAndDecide({ text, attempts });
    expect(third.decision.action).toBe("escalate");
    if (third.decision.action === "escalate") {
      expect(third.decision.reason).toContain("same transient failure 3×");
    }
  });
});
