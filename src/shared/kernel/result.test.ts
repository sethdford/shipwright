import { describe, expect, test } from "bun:test";
import { err, ok, type Result } from "./result";

describe("Result", () => {
  test("ok carries a value", () => {
    const r: Result<number, string> = ok(42);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.value).toBe(42);
  });

  test("err carries an error", () => {
    const r: Result<number, string> = err("boom");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toBe("boom");
  });
});
