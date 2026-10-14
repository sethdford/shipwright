import { cpSync, mkdirSync, readdirSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ProgressEntry } from "./progress";

const PORTED = new Set(["porting", "parity-green", "bash-deleted"]);

export interface StubPlan {
  readonly script: string;
  readonly content: string;
}

/** Replacement for a bash script once its command has moved to TypeScript. */
export function stubFor(entry: ProgressEntry, repoRoot: string): string {
  return `#!/usr/bin/env bash\nexec bun "${repoRoot}/src/cli.ts" ${entry.command} "$@"\n`;
}

export function planStubs(progress: readonly ProgressEntry[], repoRoot: string): StubPlan[] {
  return progress
    .filter((e) => PORTED.has(e.status))
    .map((e) => ({ script: e.script, content: stubFor(e, repoRoot) }));
}

/** Hermetic env: private HOME/tmux/tmp, fail-closed claude/gh shims first on PATH. */
export function parityEnv(sandbox: string, base: Record<string, string | undefined>) {
  return {
    PATH: `${join(sandbox, "bin")}:${base.PATH ?? ""}`,
    HOME: join(sandbox, "home"),
    TMUX_TMPDIR: sandbox,
    TMPDIR: join(sandbox, "tmp"),
    TERM: "dumb",
    LC_ALL: "C",
    TZ: "UTC",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_TERMINAL_PROMPT: "0",
    NO_GITHUB: "1",
  };
}

export function failClosedShim(name: string): string {
  return `#!/usr/bin/env bash\necho "parity sandbox: '${name}' is blocked (no real ${name} in parity runs)" >&2\nexit 97\n`;
}

/** Suites run from the sandbox copy, so `$SCRIPT_DIR` resolves to the stubbed scripts. */
export function suiteArgv(sandbox: string, entry: ProgressEntry): string[] {
  return ["bash", join(sandbox, "repo", entry.parity as string)];
}

/**
 * Lays out `<sandbox>/repo`: a real copy of scripts/ (exec bits kept) with ported scripts
 * replaced by stubs, other top-level entries symlinked (never .git), plus bin/home/tmp.
 */
export function buildSandbox(
  sandbox: string,
  repoRoot: string,
  progress: readonly ProgressEntry[],
): string {
  const repo = join(sandbox, "repo");
  mkdirSync(repo, { recursive: true });
  for (const name of readdirSync(repoRoot)) {
    if (name === "scripts" || name === ".git") continue;
    symlinkSync(join(repoRoot, name), join(repo, name));
  }
  cpSync(join(repoRoot, "scripts"), join(repo, "scripts"), {
    recursive: true,
    verbatimSymlinks: true,
  });
  for (const { script, content } of planStubs(progress, repoRoot)) {
    writeFileSync(join(repo, "scripts", script), content, { mode: 0o755 });
  }
  mkdirSync(join(sandbox, "bin"), { recursive: true });
  for (const name of ["claude", "gh"]) {
    writeFileSync(join(sandbox, "bin", name), failClosedShim(name), { mode: 0o755 });
  }
  mkdirSync(join(sandbox, "home"), { recursive: true });
  mkdirSync(join(sandbox, "tmp"), { recursive: true });
  return repo;
}

/** tmux sockets inside the sandbox's own `tmux-*` dirs (real directories only). */
export function socketsIn(sandbox: string): string[] {
  return readdirSync(sandbox, { withFileTypes: true })
    .filter((d) => d.isDirectory() && d.name.startsWith("tmux-"))
    .flatMap((d) => readdirSync(join(sandbox, d.name)).map((f) => join(sandbox, d.name, f)))
    .filter((p) => !statSync(p).isDirectory());
}

export function tmuxKillArgv(socket: string): string[] {
  return ["tmux", "-S", socket, "kill-server"];
}

/** Stops tmux servers that live in the sandbox; never touches a socket outside it. */
export function killSandboxTmux(sandbox: string): void {
  if (!Bun.which("tmux")) return;
  for (const sock of socketsIn(sandbox)) {
    try {
      Bun.spawnSync(tmuxKillArgv(sock), { stdout: "ignore", stderr: "ignore" });
    } catch {
      // best effort
    }
  }
}

/** SIGKILL anything whose command line mentions the (unique) sandbox path. */
export function sweepStragglers(sandbox: string): void {
  const out = Bun.spawnSync(["pgrep", "-f", sandbox], { stdout: "pipe", stderr: "ignore" });
  const pids = new TextDecoder()
    .decode(out.stdout)
    .split("\n")
    .map(Number)
    .filter((pid) => pid > 0 && pid !== process.pid);
  for (const pid of pids) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // already gone
    }
  }
}
