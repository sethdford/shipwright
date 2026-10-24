import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = process.cwd();
const config = JSON.parse(readFileSync(join(ROOT, "config/models.json"), "utf8")) as {
  aliases: Record<string, string>;
  allowlist: { files: string[] };
};
const ID = /claude-(?:opus|sonnet|haiku)-[a-z0-9.-]+/g;
const TARGETS = [".github/workflows", "templates/pipelines", "scripts", "src", "tools"];
const EXTENSIONS = /\.(ya?ml|json|sh|ts)$/;

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : EXTENSIONS.test(name) ? [path] : [];
  });
}

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

describe("model IDs", () => {
  test("no file outside the allowlist names any full model ID", () => {
    const violations: string[] = [];
    for (const target of TARGETS) {
      for (const file of walk(join(ROOT, target))) {
        const rel = relative(ROOT, file);
        if (isAllowlisted(rel)) continue;
        for (const id of readFileSync(file, "utf8").match(ID) ?? []) {
          violations.push(`${rel}: ${id}`);
        }
      }
    }
    expect(violations, "name models through config/models.json aliases").toEqual([]);
  });

  test("the aliases name the Claude 5.5 family", () => {
    expect(config.aliases).toEqual({
      opus: "claude-opus-5-5",
      sonnet: "claude-sonnet-5-5",
      haiku: "claude-haiku-5-5",
    });
  });

  test("the allowlist names only test files and the pricing table", () => {
    for (const glob of config.allowlist.files) {
      const ok =
        glob.includes("test") || glob === "scripts/sw-cost.sh" || glob === "config/models.json";
      expect(ok, `unexpected allowlist entry: ${glob}`).toBe(true);
    }
  });
});
