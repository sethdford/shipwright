import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Commander's variadic flags (`<tools...>`) take every following non-option argument, so a flag written
// with a space and followed by the positional prompt swallows the prompt (#8660 review: plan, design,
// spec-review and review all came back empty). Use the `--flag=value` form, or put `--` before the prompt.
const SCRIPTS = join(import.meta.dir, "../../../scripts");
// claude CLI variadic flags (`claude --help`). sw-loop's own --agents is not one.
const VARIADIC = [
  "allowedTools",
  "allowed-tools",
  "disallowedTools",
  "disallowed-tools",
  "tools",
  "add-dir",
];

function shellFiles(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, name.name);
    if (name.isDirectory()) out.push(...shellFiles(p));
    else if (name.name.endsWith(".sh")) out.push(p);
  }
  return out;
}

describe("variadic CLI flags are never followed by the positional prompt", () => {
  test("no script writes a variadic flag with a space before a non-option argument", () => {
    const offenders: string[] = [];
    const pattern = new RegExp(`--(${VARIADIC.join("|")})\\s+[^-\\s|)"'\\\\]`);
    for (const file of shellFiles(SCRIPTS)) {
      readFileSync(file, "utf8")
        .split("\n")
        .forEach((line, i) => {
          if (pattern.test(line) && !line.trimStart().startsWith("#"))
            offenders.push(`${file}:${i + 1}: ${line.trim()}`);
        });
    }
    expect(offenders).toEqual([]);
  });

  test("the stage call sites that pass --disallowedTools use the = form", () => {
    for (const file of [
      "lib/pipeline-stages-intake.sh",
      "lib/pipeline-stages-review.sh",
      "sw-loop.sh",
    ]) {
      const src = readFileSync(join(SCRIPTS, file), "utf8");
      expect(src).toContain("--disallowedTools=Edit,Write,NotebookEdit");
    }
  });
});
