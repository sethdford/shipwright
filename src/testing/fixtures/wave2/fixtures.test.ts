import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";

const dir = new URL("./", import.meta.url);
const SECRET =
  /ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|CLAUDE_CODE_OAUTH_TOKEN=\S+/;

describe("wave2 incident fixtures", () => {
  test("no fixture contains a credential-shaped string", () => {
    // Recurses into subdirectories (raw/) so raw captures are scanned too.
    const walk = (base: URL, prefix: string): void => {
      for (const entry of readdirSync(base, { withFileTypes: true })) {
        const rel = `${prefix}${entry.name}`;
        if (entry.isDirectory()) {
          walk(new URL(`${entry.name}/`, base), `${rel}/`);
          continue;
        }
        if (entry.name.endsWith(".test.ts")) continue;
        expect(readFileSync(new URL(entry.name, base), "utf8"), rel).not.toMatch(SECRET);
      }
    };
    walk(dir, "");
  });

  test("the pre-flight fixture carries the auth failure line", () => {
    const text = readFileSync(new URL("preflight-auth.log", dir), "utf8");
    expect(text).toContain("Claude Code authentication failed");
  });

  test("the stall fixture is four iterations of one repeated error", () => {
    const snapshots = JSON.parse(
      readFileSync(new URL("stall-snapshots.json", dir), "utf8"),
    ) as Array<{ errorFingerprint: string }>;
    expect(snapshots).toHaveLength(4);
    expect(new Set(snapshots.map((s) => s.errorFingerprint)).size).toBe(1);
  });
});
