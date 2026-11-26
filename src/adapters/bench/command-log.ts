import { chmod, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** The most of a command log the audit reads: a runaway agent cannot make grading slow. */
const MAX_LOG_BYTES = 4 * 1024 * 1024;
/** Paths are pasted into a shell script, so only plain characters are allowed in them. */
const PLAIN = /^[A-Za-z0-9/._+-]+$/;
const SHIMMED = ["git", "gh"] as const;

/**
 * `git` and `gh` wrappers put first on an arm's PATH. Each call is appended to a log the integrity
 * audit reads, then the real tool runs. This sees every arm's history and network calls, including
 * Shipwright's own agents, whose transcripts the harness does not get. An agent that calls a tool
 * by absolute path bypasses it; the transcript scan and the history-free workspace still apply.
 */
export interface CommandLog {
  /** PATH for the arm: the wrappers first, then `basePath`. Unchanged when logging is off. */
  readonly path: string;
  read(): Promise<readonly string[]>;
  remove(): Promise<void>;
}

function shim(tool: string, binDir: string, log: string): string {
  return [
    "#!/bin/sh",
    `printf '%s\\n' "${tool} $*" >> '${log}' 2>/dev/null`,
    `PATH=\${PATH#'${binDir}:'}`,
    `exec ${tool} "$@"`,
    "",
  ].join("\n");
}

const off = (basePath: string): CommandLog => ({
  path: basePath,
  read: async () => [],
  remove: async () => {},
});

async function install(binDir: string, log: string): Promise<boolean> {
  try {
    await mkdir(binDir, { recursive: true });
    for (const tool of SHIMMED) {
      const file = join(binDir, tool);
      await writeFile(file, shim(tool, binDir, log), "utf8");
      await chmod(file, 0o755);
    }
    await writeFile(log, "", "utf8");
    return true;
  } catch {
    return false;
  }
}

/**
 * Creates the wrappers in `<dir>/bin` and the log at `<dir>/commands.log`. Logging is off (the
 * arm still runs, unlogged) when `dir` has unusual characters or cannot be written.
 */
export async function startCommandLog(dir: string, basePath: string): Promise<CommandLog> {
  const binDir = join(dir, "bin");
  const log = join(dir, "commands.log");
  if (!PLAIN.test(dir)) return off(basePath);
  if (!(await install(binDir, log))) {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
    return off(basePath);
  }
  return {
    path: basePath === "" ? binDir : `${binDir}:${basePath}`,
    read: async () => {
      const text = await readFile(log, "utf8").catch(() => "");
      return text
        .slice(-MAX_LOG_BYTES)
        .split("\n")
        .filter((l) => l.trim() !== "");
    },
    remove: () => rm(dir, { recursive: true, force: true }).catch(() => {}),
  };
}
