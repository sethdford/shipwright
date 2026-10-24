import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

/**
 * The project memory the CLI would have loaded from the project scope: CLAUDE.md, AGENTS.md,
 * .claude/CLAUDE.md and .claude/rules/*.md. The runner does not load project settings (agent-writable), so
 * this text goes in as systemPrompt.append, the same as the bash path's --append-system-prompt (#8614).
 * A missing file is skipped; any other read error is thrown, so a broken repo never runs silently without it.
 */
export async function readProjectMemory(cwd: string | undefined): Promise<string> {
  if (cwd === undefined) return "";
  const parts: string[] = [];
  const read = async (rel: string): Promise<void> => {
    try {
      const body = await readFile(join(cwd, rel), "utf8");
      parts.push(`# ${rel}\n\n${body}`);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    }
  };
  for (const rel of ["CLAUDE.md", "AGENTS.md", ".claude/CLAUDE.md"]) await read(rel);
  let rules: string[] = [];
  try {
    rules = (await readdir(join(cwd, ".claude/rules"))).filter((f) => f.endsWith(".md")).sort();
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  for (const f of rules) await read(`.claude/rules/${f}`);
  return parts.join("\n\n");
}
