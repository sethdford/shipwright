import { describe, expect, test } from "bun:test";
import { idempotencyKey } from "./durability";

describe("idempotencyKey", () => {
  test("joins plain parts with ':'", () => {
    expect(idempotencyKey("run-42", "pr", "open") as string).toBe("run-42:pr:open");
  });

  test("is injective: a ':' inside a part never collides with a part boundary", () => {
    expect(idempotencyKey("a:b", "c")).not.toBe(idempotencyKey("a", "b:c"));
    expect(idempotencyKey("a\\", ":b")).not.toBe(idempotencyKey("a\\:", "b"));
    expect(idempotencyKey("a", "")).not.toBe(idempotencyKey("a:"));
  });
});
