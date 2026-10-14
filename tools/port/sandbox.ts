import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
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

/**
 * Stubs for every ported command. A script is replaced wholesale, so a ported command that
 * shares its script with a command that is still in bash cannot be stubbed safely.
 */
export function planStubs(progress: readonly ProgressEntry[], repoRoot: string): StubPlan[] {
  const ported = progress.filter((e) => PORTED.has(e.status));
  for (const p of ported) {
    const other = progress.find((e) => e.script === p.script && !PORTED.has(e.status));
    if (other) {
      throw new Error(
        `cannot stub ${p.script}: ported command '${p.command}' shares it with unported command '${other.command}'`,
      );
    }
  }
  return ported.map((e) => ({ script: e.script, content: stubFor(e, repoRoot) }));
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
    GIT_CEILING_DIRECTORIES: sandbox,
  };
}

export function failClosedShim(name: string): string {
  return `#!/usr/bin/env bash\necho "parity sandbox: '${name}' is blocked (no real ${name} in parity runs)" >&2\nexit 97\n`;
}

/** Suites run from the sandbox copy, so `$SCRIPT_DIR` resolves to the stubbed scripts. */
export function suiteArgv(sandbox: string, entry: ProgressEntry): string[] {
  return ["bash", join(sandbox, "repo", entry.parity as string)];
}

function trackedFiles(repoRoot: string): string[] {
  const r = Bun.spawnSync(["git", "-C", repoRoot, "ls-files", "-z"], { stdout: "pipe" });
  if (r.exitCode !== 0) throw new Error(`git ls-files failed in ${repoRoot}`);
  return new TextDecoder().decode(r.stdout).split("\0").filter(Boolean);
}

/** Copies tracked files only (exec bits and symlinks kept) into `dest`. */
function copyTracked(repoRoot: string, dest: string): void {
  for (const rel of trackedFiles(repoRoot)) {
    const from = join(repoRoot, rel);
    const to = join(dest, rel);
    let st: ReturnType<typeof lstatSync>;
    try {
      st = lstatSync(from);
    } catch {
      continue; // deleted in the working tree
    }
    mkdirSync(dirname(to), { recursive: true });
    if (st.isSymbolicLink()) symlinkSync(readlinkSync(from), to);
    else if (st.isFile()) {
      copyFileSync(from, to);
      chmodSync(to, st.mode & 0o777);
    }
  }
}

/**
 * Lays out `<sandbox>/repo`: a real copy of the tracked files (no .git, no untracked files)
 * with ported scripts replaced by stubs that point back into the copy. Only node_modules is
 * symlinked (read-only use). Also creates bin (fail-closed shims), home and tmp.
 */
export function buildSandbox(
  sandbox: string,
  repoRoot: string,
  progress: readonly ProgressEntry[],
): string {
  const repo = join(sandbox, "repo");
  mkdirSync(repo, { recursive: true });
  copyTracked(repoRoot, repo);
  if (existsSync(join(repoRoot, "node_modules"))) {
    symlinkSync(join(repoRoot, "node_modules"), join(repo, "node_modules"));
  }
  for (const { script, content } of planStubs(progress, repo)) {
    const path = join(repo, "scripts", script);
    writeFileSync(path, content);
    chmodSync(path, 0o755);
  }
  mkdirSync(join(sandbox, "bin"), { recursive: true });
  for (const name of ["claude", "gh"]) {
    writeFileSync(join(sandbox, "bin", name), failClosedShim(name), { mode: 0o755 });
  }
  mkdirSync(join(sandbox, "home"), { recursive: true });
  mkdirSync(join(sandbox, "tmp"), { recursive: true });
  return repo;
}

function walkSockets(dir: string, root: string, out: string[]): void {
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return; // unreadable or vanished
  }
  for (const name of names) {
    const p = join(dir, name);
    try {
      const st = lstatSync(p); // never follow symlinks
      if (st.isSocket()) {
        // realpath() cannot open a socket on macOS: resolve its (symlink-free) parent instead.
        if (st.nlink === 1 && join(realpathSync(dir), name).startsWith(`${root}/`)) out.push(p);
      } else if (st.isDirectory()) walkSockets(p, root, out);
    } catch {
      // vanished or unreadable: skip
    }
  }
}

/** Unix sockets that really live inside the sandbox (symlinks are never followed). */
export function socketsIn(sandbox: string): string[] {
  const out: string[] = [];
  walkSockets(sandbox, realpathSync(sandbox), out);
  return out;
}

export function tmuxKillArgv(socket: string): string[] {
  return ["tmux", "-S", socket, "kill-server"];
}

function defaultKill(argv: string[]): void {
  Bun.spawnSync(argv, { stdout: "ignore", stderr: "ignore" });
}

/** Stops tmux servers that live in the sandbox; never touches a socket outside it. */
export function killSandboxTmux(
  sandbox: string,
  kill: (argv: string[]) => void = defaultKill,
): void {
  if (kill === defaultKill && !Bun.which("tmux")) return;
  for (const sock of socketsIn(sandbox)) {
    try {
      kill(tmuxKillArgv(sock));
    } catch {
      // best effort
    }
  }
}

const SANDBOX_NAME = /\/sw-parity-[A-Za-z0-9]{6}$/;

/** SIGKILL anything whose command line mentions a path inside the (unique) sandbox. */
export function sweepStragglers(sandbox: string): void {
  if (!SANDBOX_NAME.test(sandbox)) throw new Error(`refusing to sweep unexpected path: ${sandbox}`);
  const escapeRe = (p: string) => p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const real = existsSync(sandbox) ? realpathSync(sandbox) : sandbox;
  const pattern = `(${escapeRe(sandbox)}|${escapeRe(real)})/`;
  const out = Bun.spawnSync(["pgrep", "-f", pattern], { stdout: "pipe", stderr: "ignore" });
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

/** Everything a suite could disturb in the real repo: status, ignored files, stashes, worktrees. */
export function gitSnapshot(repoRoot: string): string {
  const run = (...args: string[]) =>
    new TextDecoder().decode(
      Bun.spawnSync(["git", "-C", repoRoot, ...args], { stdout: "pipe", stderr: "ignore" }).stdout,
    );
  return [
    run("status", "--porcelain=v2", "--branch", "--ignored=matching"),
    run("stash", "list"),
    run("worktree", "list"),
  ].join("\n--\n");
}

/** rm -rf that first restores owner access, so a mode-000 directory cannot block removal. */
export function forceRemove(path: string): void {
  const open = (p: string): void => {
    try {
      const st = lstatSync(p);
      if (!st.isDirectory()) return;
      chmodSync(p, 0o700);
      for (const name of readdirSync(p)) open(join(p, name));
    } catch {
      // vanished: nothing to open
    }
  };
  open(path);
  rmSync(path, { recursive: true, force: true });
}

export interface CleanupSteps {
  readonly tmux: () => void;
  readonly sweep: () => void;
  readonly remove: () => void;
}

/** Runs every cleanup step even if an earlier one throws; failures are logged, not raised. */
export function cleanupSandbox(
  sandbox: string,
  steps: CleanupSteps = {
    tmux: () => killSandboxTmux(sandbox),
    sweep: () => sweepStragglers(sandbox),
    remove: () => forceRemove(sandbox),
  },
  log: (message: string) => void = console.error,
): void {
  for (const [name, step] of Object.entries(steps)) {
    try {
      step();
    } catch (err) {
      log(`parity cleanup (${name}) failed for ${sandbox}: ${String(err)}`);
    }
  }
}
