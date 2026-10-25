import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Scans every git-tracked text file for a full or old-format model ID. The allowlist (tools/models/allowlist.json)
// names whole files (test fixtures, the pricing table, historical records) and lines (one workflow fallback pin).
// Agents cannot write it: the policy denies tools/models/**. The scan normalises quotes, backticks, plus signs and
// whitespace first, so `"claude-""opus-4-1"` is still one ID.
const ROOT = process.cwd();
const config = JSON.parse(readFileSync(join(ROOT, "config/models.json"), "utf8")) as {
  aliases: Record<string, string>;
  efforts: string[];
};
const allowlist = JSON.parse(readFileSync(join(ROOT, "tools/models/allowlist.json"), "utf8")) as {
  files: string[];
  lines: { file: string; contains: string }[];
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

const allowedFiles = allowlist.files.map(globToRegex);
const isAllowlistedFile = (rel: string) => allowedFiles.some((re) => re.test(rel));

/** Removes the characters that split an ID across tokens: quotes, backticks, plus signs and whitespace. */
function normalize(line: string): string {
  return line.replace(/["'`+\s]/g, "");
}

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

/** Model IDs on lines of `rel` that no allowlist entry covers. */
function violationsIn(rel: string, text: string): string[] {
  const lineEntries = allowlist.lines.filter((e) => e.file === rel);
  const out: string[] = [];
  for (const line of text.split("\n")) {
    const ids = normalize(line).match(ID) ?? [];
    if (ids.length === 0) continue;
    if (lineEntries.some((e) => line.includes(e.contains))) continue;
    for (const id of ids) out.push(`${rel}: ${id}`);
  }
  return out;
}

describe("model IDs", () => {
  test("no tracked file outside the allowlist names a full or old-format model ID", () => {
    const violations: string[] = [];
    for (const rel of trackedFiles()) {
      if (isAllowlistedFile(rel)) continue;
      const buf = readFileSync(join(ROOT, rel));
      if (!isText(buf)) continue;
      violations.push(...violationsIn(rel, buf.toString("utf8")));
    }
    expect(violations, "name models through the config/models.json aliases").toEqual([]);
  });

  test("the scan sees through quote and whitespace splitting", () => {
    expect(violationsIn("x.sh", 'MODEL="claude-""opus-4-1"')).toEqual(["x.sh: claude-opus-4-1"]);
    expect(violationsIn("x.sh", "m=claude- sonnet-4\n")).toEqual(["x.sh: claude-sonnet-4"]);
    expect(violationsIn("x.sh", 'a="claude" + "-haiku-4"')).toEqual(["x.sh: claude-haiku-4"]);
  });

  test("the aliases name the Claude 5.5 family and the default is an alias", () => {
    expect(config.aliases).toEqual({
      opus: "claude-opus-5-5",
      sonnet: "claude-sonnet-5-5",
      haiku: "claude-haiku-5-5",
    });
    expect(Object.keys(config.aliases)).toContain(
      (config as unknown as { default: string }).default,
    );
  });

  test("the efforts list names low, medium, high and xhigh", () => {
    expect(config.efforts).toEqual(["low", "medium", "high", "xhigh"]);
  });

  test("the allowlist cannot match everything: no catch-all, and every entry names a tracked file", () => {
    const tracked = trackedFiles();
    for (const glob of allowlist.files) {
      expect(["*", "**", "**/*"], `catch-all entry: ${glob}`).not.toContain(glob);
      expect(glob.startsWith("*"), `entry must not start with a wildcard: ${glob}`).toBe(false);
      const hits = tracked.filter((f) => globToRegex(glob).test(f));
      expect(hits.length, `allowlist entry matches no tracked file: ${glob}`).toBeGreaterThan(0);
    }
    for (const entry of allowlist.lines) {
      expect(entry.contains.length, `line entry too broad: ${entry.file}`).toBeGreaterThan(10);
      expect(tracked.includes(entry.file), `line entry names no tracked file: ${entry.file}`).toBe(
        true,
      );
    }
  });
});
