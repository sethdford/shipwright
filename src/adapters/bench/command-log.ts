import { constants } from "node:fs";
import { access, chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** The most of a command log the audit reads: a runaway agent cannot make grading slow. */
const MAX_LOG_BYTES = 4 * 1024 * 1024;
/** Paths are pasted into a shell script, so only plain characters are allowed in them. */
const PLAIN = /^[A-Za-z0-9/._+-]+$/;
const SHIMMED = ["git", "gh"] as const;

/**
 * `git` and `gh` wrappers put first on an arm's PATH. Each call is appended to a log the integrity
 * audit reads, then the real tool (found on PATH when the wrappers are made) runs by absolute path,
 * so a wrapper never finds itself again however the agent reorders PATH. This sees every arm's
 * history and network calls, including Shipwright's own agents, whose transcripts the harness does
 * not get. The log lives in its own temp dir, not next to the workspace. An agent that calls a
 * tool by absolute path bypasses it; the transcript scan and the history-free workspace still apply.
 */
export interface CommandLog {
  /** PATH for the arm: the wrappers first, then `basePath`. Unchanged when logging is off. */
  readonly path: string;
  /** False when the wrappers could not be made; the run is then audited from transcripts only. */
  readonly active: boolean;
  read(): Promise<readonly string[]>;
  remove(): Promise<void>;
}

const shim = (tool: string, real: string, log: string) =>
  [
    "#!/bin/sh",
    `printf '%s\\n' "${tool} $*" >> '${log}' 2>/dev/null`,
    `exec '${real}' "$@"`,
    "",
  ].join("\n");

const off = (basePath: string): CommandLog => ({
  path: basePath,
  active: false,
  read: async () => [],
  remove: async () => {},
});

/** The first executable `tool` on `path`, or null. */
async function findTool(tool: string, path: string): Promise<string | null> {
  for (const dir of path.split(":")) {
    if (dir === "") continue;
    const file = join(dir, tool);
    if (
      await access(file, constants.X_OK).then(
        () => true,
        () => false,
      )
    )
      return file;
  }
  return null;
}

async function install(binDir: string, log: string, basePath: string): Promise<boolean> {
  await writeFile(log, "", "utf8");
  for (const tool of SHIMMED) {
    const real = await findTool(tool, basePath);
    if (real === null) continue;
    if (!PLAIN.test(real)) return false;
    const file = join(binDir, tool);
    await writeFile(file, shim(tool, real, log), "utf8");
    await chmod(file, 0o755);
  }
  return true;
}

/** Makes the wrappers and the log in a fresh temp dir. Logging is off if that fails. */
export async function startCommandLog(basePath: string): Promise<CommandLog> {
  let dir: string;
  try {
    dir = await mkdtemp(join(tmpdir(), "sw-bench-log-"));
  } catch {
    return off(basePath);
  }
  const remove = () => rm(dir, { recursive: true, force: true }).catch(() => {});
  const log = join(dir, "commands.log");
  if (!PLAIN.test(dir) || !(await install(dir, log, basePath).catch(() => false))) {
    await remove();
    return off(basePath);
  }
  return {
    path: basePath === "" ? dir : `${dir}:${basePath}`,
    active: true,
    read: async () => {
      const text = await readFile(log, "utf8").catch(() => "");
      return text
        .slice(0, MAX_LOG_BYTES)
        .split("\n")
        .filter((l) => l.trim() !== "");
    },
    remove,
  };
}
