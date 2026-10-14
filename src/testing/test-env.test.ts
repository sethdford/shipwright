import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { createTestEnv } from "./test-env";

describe("createTestEnv", () => {
  test("creates an isolated home and state dir, never the real home", () => {
    const env = createTestEnv();
    try {
      expect(env.home).not.toBe(homedir());
      expect(env.stateDir.startsWith(env.home)).toBe(true);
      expect(existsSync(env.stateDir)).toBe(true);
      expect(env.tmuxSocketName).toMatch(/^sw-test-/);
    } finally {
      env.cleanup();
    }
    expect(existsSync(env.root)).toBe(false);
  });

  test("two environments never share a tmux socket", () => {
    const a = createTestEnv();
    const b = createTestEnv();
    try {
      expect(a.tmuxSocketName).not.toBe(b.tmuxSocketName);
    } finally {
      a.cleanup();
      b.cleanup();
    }
  });
});
