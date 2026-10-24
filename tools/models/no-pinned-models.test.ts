import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Scans every git-tracked text file. A full or old-format model ID is allowed only where config/models.json's
// allowlist names it: the models file, the pricing table, test fixtures, the one workflow fallback pin, and the
// historical records (plans, specs, ADRs, research). Everything else names models through the aliases.
const ROOT = process.cwd();
const config = JSON.parse(readFileSync(join(ROOT, "config/models.json"), "utf8")) as {
  aliases: Record<string, string>;
  efforts: string[];
  allowlist: { files: string[] };
};
// Full IDs (claude-opus-5-5) and old-format IDs (claude-3-5-sonnet-20241022, claude-2.1, claude-instant-1.2).
const ID = /claude-(?:opus|sonnet|haiku|instant|\d)[a-z0-9.-]*/g;

/** `*` matches within a path segment; `**` matches any depth. Dots are literal. */
function globToRegex(glob: string): RegExp {
  const escaped = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  return new RegExp(
    `^${escaped
      .replace(/\*\*/g, "<<GLOBSTAR>>")
      .replace(/\*/g, "[^/]*")
      .replace(/<<GLOBSTAR>>/g, ".*")}$`,
  );
}

const allowed = config.allowlist.files.map(globToRegex);
const isAllowlisted = (rel: string) => allowed.some((re) => re.test(rel));

function trackedFiles(): string[] {
  return execFileSync("git", ["ls-files", "-z"], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 })
    .toString("utf8")
    .split("\0")
    .filter(
      (f) => f !== "" && statSync(join(ROOT, f), { throwIfNoEntry: false })?.isFile() === true,
    );
}

function isText(buf: Buffer): boolean {
  return !buf.subarray(0, 8000).includes(0);
}

describe("model IDs", () => {
  test("no tracked file outside the allowlist names a full or old-format model ID", () => {
    const violations: string[] = [];
    for (const rel of trackedFiles()) {
      if (isAllowlisted(rel)) continue;
      const buf = readFileSync(join(ROOT, rel));
      if (!isText(buf)) continue;
      for (const id of buf.toString("utf8").match(ID) ?? []) {
        violations.push(`${rel}: ${id}`);
      }
    }
    expect(violations, "name models through the config/models.json aliases").toEqual([]);
  });

  test("the aliases name the Claude 5.5 family", () => {
    expect(config.aliases).toEqual({
      opus: "claude-opus-5-5",
      sonnet: "claude-sonnet-5-5",
      haiku: "claude-haiku-5-5",
    });
  });

  test("the efforts list names low, medium, high and xhigh", () => {
    expect(config.efforts).toEqual(["low", "medium", "high", "xhigh"]);
  });

  test("every exact allowlist entry is a tracked file (no stale entries)", () => {
    const tracked = new Set(trackedFiles());
    for (const glob of config.allowlist.files) {
      if (glob.includes("*")) continue;
      expect(tracked.has(glob), `allowlist entry is not a tracked file: ${glob}`).toBe(true);
    }
  });
});
