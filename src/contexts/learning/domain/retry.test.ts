import { describe, expect, test } from "bun:test";
import {
  type Attempt,
  DEFAULT_RETRY_POLICY,
  decideRetry,
  parseAttempts,
  type RetryPolicy,
} from "./retry";

const policy: RetryPolicy = {
  maxAttempts: 4,
  maxTransient: 3,
  baseDelayMs: 1000,
  maxDelayMs: 60_000,
};
const att = (cls: Attempt["cls"], fingerprint = `${cls}:x`): Attempt => ({ cls, fingerprint });

describe("decideRetry", () => {
  test("auth is never retried; it escalates on the first attempt", () => {
    expect(decideRetry([att("auth")], policy).action).toBe("escalate");
  });

  test("invalid input is never retried", () => {
    expect(decideRetry([att("invalid_input")], policy).action).toBe("escalate");
  });

  test("the same non-transient failure twice escalates", () => {
    const same = att("execution", "execution:abc");
    const d = decideRetry([same, same], policy);
    expect(d.action).toBe("escalate");
    if (d.action === "escalate") expect(d.reason).toContain("same failure twice");
  });

  test("an environment failure is retried once, then escalates", () => {
    expect(decideRetry([att("environment", "e:1")], policy).action).toBe("retry");
    expect(decideRetry([att("environment", "e:1"), att("environment", "e:2")], policy).action).toBe(
      "escalate",
    );
  });

  test("contamination escalates on the first attempt: a retry would repeat real side effects", () => {
    const d = decideRetry([att("contamination", "c:1")], policy);
    expect(d.action).toBe("escalate");
  });

  test("two distinct budget failures are retried within caps", () => {
    expect(decideRetry([att("budget", "b:1"), att("budget", "b:2")], policy).action).toBe("retry");
  });

  test("transient failures back off exponentially", () => {
    const d = decideRetry([att("transient", "t:1"), att("transient", "t:1")], policy);
    expect(d).toMatchObject({ action: "retry", delayMs: 2000 });
  });

  test("transient failures escalate once they exceed maxTransient", () => {
    const many = Array.from({ length: 4 }, () => att("transient", "t:1"));
    expect(decideRetry(many, { ...policy, maxAttempts: 10 }).action).toBe("escalate");
  });

  test("the attempt cap cannot be exceeded", () => {
    const four = [att("budget", "1"), att("budget", "2"), att("budget", "3"), att("budget", "4")];
    expect(decideRetry(four, policy).action).toBe("escalate");
  });

  test("no history means no decision to act on: escalate", () => {
    expect(decideRetry([], policy).action).toBe("escalate");
  });

  test("the default policy never allows more than four runs", () => {
    const four = [1, 2, 3, 4].map((n) => att("budget", `b:${n}`));
    expect(decideRetry(four, DEFAULT_RETRY_POLICY).action).toBe("escalate");
  });
});

describe("parseAttempts", () => {
  test("accepts a well-formed array", () => {
    const r = parseAttempts([{ cls: "transient", fingerprint: "transient:1" }]);
    expect(r.ok).toBe(true);
  });

  test("refuses an unknown class rather than guessing", () => {
    const r = parseAttempts([{ cls: "weather", fingerprint: "x" }]);
    expect(r).toEqual({ ok: false, reason: "attempt 0: unknown class" });
  });

  test("refuses a non-array document", () => {
    expect(parseAttempts({})).toEqual({ ok: false, reason: "attempts must be a JSON array" });
  });
});
