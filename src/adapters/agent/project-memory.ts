import { execFile } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/** At most 64 KiB of project memory is passed to the agent (#8673). Longer memory is cut, with a marker. */
export const PROJECT_MEMORY_CAP_BYTES = 64 * 1024;
const TRUNCATED_MARKER =
  "\n\n[project memory truncated at 64 KiB by the agent runner (#8673); the rest was not passed]";
const FIXED_FILES = ["CLAUDE.md", "AGENTS.md", ".claude/CLAUDE.md"] as const;

/**
 * The project memory the CLI would have loaded from the project scope: CLAUDE.md, AGENTS.md,
 * .claude/CLAUDE.md and .claude/rules/*.md. The runner does not load project settings (agent-writable), so
 * this text goes in as systemPrompt.append, the same as the bash path's --append-system-prompt (#8614).
 *
 * Source: the working tree (the build stage), or, when `memoryRef` is set, the files at that git ref (a review or
 * audit stage reads the base branch, so a builder cannot steer it, #8673). A missing file is skipped; any other read
 * error is thrown, and a ref that names no commit is thrown, so a broken repo never runs silently without memory.
 */
export async function readProjectMemory(
  cwd: string | undefined,
  memoryRef?: string,
): Promise<string> {
  if (cwd === undefined) return "";
  const text = memoryRef === undefined ? await fromWorkingTree(cwd) : await fromRef(cwd, memoryRef);
  return capMemory(text);
}

/** Cuts memory to the cap in bytes, appending the marker, so one argument never nears the kernel limit. */
export function capMemory(text: string): string {
  if (Buffer.byteLength(text) <= PROJECT_MEMORY_CAP_BYTES) return text;
  const keep = PROJECT_MEMORY_CAP_BYTES - Buffer.byteLength(TRUNCATED_MARKER);
  let body = Buffer.from(text).subarray(0, keep).toString("utf8");
  // A cut inside a multi-byte character decodes to U+FFFD (3 bytes): drop trailing characters until the body fits.
  while (Buffer.byteLength(body) > keep) body = body.slice(0, -1);
  return `${body}${TRUNCATED_MARKER}`;
}

function section(rel: string, body: string): string {
  return `# ${rel}\n\n${body}`;
}

async function fromWorkingTree(cwd: string): Promise<string> {
  const parts: string[] = [];
  for (const rel of FIXED_FILES) {
    const body = await readOrNull(join(cwd, rel));
    if (body !== null) parts.push(section(rel, body));
  }
  let rules: string[] = [];
  try {
    rules = (await readdir(join(cwd, ".claude/rules"))).filter((f) => f.endsWith(".md")).sort();
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  for (const f of rules) {
    const body = await readOrNull(join(cwd, ".claude/rules", f));
    if (body !== null) parts.push(section(`.claude/rules/${f}`, body));
  }
  return parts.join("\n\n");
}

async function readOrNull(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw e;
  }
}

async function fromRef(cwd: string, ref: string): Promise<string> {
  // argv only, with a timeout on every call (adapter rule). The ref is resolved to a SHA once, so a later
  // move of the ref cannot change what is read. A ref that is not a commit is an error, not a fallback.
  let commit: string;
  try {
    const { stdout } = await run("git", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], {
      cwd,
      timeout: 30_000,
    });
    commit = stdout.trim();
  } catch {
    throw new Error(`project memory: memoryRef "${ref}" does not name a commit`);
  }
  const { stdout } = await run("git", ["ls-tree", "-r", "--name-only", commit], {
    cwd,
    timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024,
  });
  const names = new Set(stdout.split("\n").filter((f) => f !== ""));
  // Top level only, like the working-tree read and the bash path: nested rule files are not loaded.
  const rules = [...names].filter((f) => /^\.claude\/rules\/[^/]*\.md$/.test(f)).sort();
  const parts: string[] = [];
  for (const rel of [...FIXED_FILES.filter((f) => names.has(f)), ...rules]) {
    const { stdout: body } = await run("git", ["show", `${commit}:${rel}`], {
      cwd,
      timeout: 30_000,
      maxBuffer: 64 * 1024 * 1024,
    });
    parts.push(section(rel, body));
  }
  return parts.join("\n\n");
}
