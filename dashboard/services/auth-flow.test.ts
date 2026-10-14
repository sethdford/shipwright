// @vitest-environment node
import { describe, expect, it } from "vitest";
import { OAuthStateStore, oauthStateFromCookie, redeemJoinToken } from "./auth-flow";

describe("OAuthStateStore", () => {
  it("issues random states that verify once against the matching cookie", () => {
    const store = new OAuthStateStore();
    const a = store.issue(1000);
    const b = store.issue(1000);
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(a).not.toBe(b);
    expect(store.consume(a, a, 2000)).toBe(true);
    expect(store.consume(a, a, 2000)).toBe(false); // single use
  });
  it("rejects a missing, mismatched, unknown or expired state", () => {
    const store = new OAuthStateStore(600_000);
    const s = store.issue(0);
    expect(store.consume(null, s, 1)).toBe(false);
    expect(store.consume(s, null, 1)).toBe(false);
    expect(store.consume(s, `${s.slice(0, -1)}0`, 1)).toBe(false);
    expect(store.consume("f".repeat(64), "f".repeat(64), 1)).toBe(false);
    const late = store.issue(0);
    expect(store.consume(late, late, 600_001)).toBe(false);
  });
  it("a failed attempt with the right cookie still burns the state", () => {
    const store = new OAuthStateStore();
    const s = store.issue(0);
    expect(store.consume(s, "wrong", 1)).toBe(false);
    expect(store.consume(s, s, 1)).toBe(false);
  });
  it("reads the state cookie", () => {
    expect(oauthStateFromCookie("a=b; oauth_state=abc123; c=d")).toBe("abc123");
    expect(oauthStateFromCookie("a=b")).toBeNull();
    expect(oauthStateFromCookie(null)).toBeNull();
  });
});

describe("redeemJoinToken", () => {
  const tokens = () => [
    { token: "t1", used: false, max_workers: 2 },
    { token: "t2", used: true, used_at: "2026-01-01T00:00:00.000Z" },
  ];
  it("redeems an unused token once and marks it used", () => {
    const list = tokens();
    const r = redeemJoinToken(list, "t1", "2026-10-14T00:00:00.000Z");
    expect(r.ok).toBe(true);
    expect(list[0]).toMatchObject({ used: true, used_at: "2026-10-14T00:00:00.000Z" });
    expect(redeemJoinToken(list, "t1", "2026-10-14T00:00:01.000Z")).toEqual({
      ok: false,
      reason: "used",
    });
  });
  it("refuses a used or unknown token", () => {
    expect(redeemJoinToken(tokens(), "t2", "x")).toEqual({ ok: false, reason: "used" });
    expect(redeemJoinToken(tokens(), "nope", "x")).toEqual({ ok: false, reason: "unknown" });
    expect(redeemJoinToken(tokens(), "", "x")).toEqual({ ok: false, reason: "unknown" });
  });
});
