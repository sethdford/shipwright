import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { USER_AGENTS, USER_HOOKS } from "../../scripts/install-allowlist.mjs";

const ROOT = resolve(import.meta.dir, "../..");
const DEV_ONLY = ["reviewer.md", "verifier.md", "porter.md", "check-fast-on-stop.sh"];

test("dev-only agents and hooks are never installed into ~/.claude", () => {
  for (const name of DEV_ONLY) {
    expect(USER_AGENTS).not.toContain(name);
    expect(USER_HOOKS).not.toContain(name);
  }
});

test("every allowlisted file exists in the package", () => {
  for (const name of USER_AGENTS) expect(existsSync(join(ROOT, ".claude/agents", name))).toBe(true);
  for (const name of USER_HOOKS) expect(existsSync(join(ROOT, ".claude/hooks", name))).toBe(true);
});
