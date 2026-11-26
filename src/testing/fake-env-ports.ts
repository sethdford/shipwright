import type { CacheEntry, EnvPorts } from "../contexts/platform";
import type { AgentRunner, ProcessResult, TaskSpec } from "../shared/kernel/ports";
import { err, ok } from "../shared/kernel/result";

/** One scripted command result, matched on argv[0..] joined by spaces. */
export type Script = Record<
  string,
  Partial<ProcessResult> | ((cwd: string) => Partial<ProcessResult>)
>;

/**
 * In-memory `EnvPorts` for application and CLI tests: checkouts are maps of files, the cache is a
 * map of snapshots, commands are scripted (an unscripted command exits 127), and the agent writes
 * whatever `agentWrites` returns for each attempt.
 */
export class FakeEnv {
  readonly trees = new Map<string, Map<string, string>>();
  readonly committed = new Map<string, string>();
  readonly cache = new Map<string, { entry: CacheEntry; files: Map<string, string> }>();
  readonly ran: { argv: string[]; cwd: string }[] = [];
  readonly tasks: TaskSpec[] = [];
  script: Script = {};
  agentWrites: (attempt: number) => Record<string, string> = () => ({});
  clock = 0;
  private clones = 0;

  tree(dir: string): Map<string, string> {
    let t = this.trees.get(dir);
    if (!t) {
      t = new Map();
      this.trees.set(dir, t);
    }
    return t;
  }

  private exec(argv: readonly string[], cwd: string): ProcessResult {
    this.ran.push({ argv: [...argv], cwd });
    const s = this.script[argv.join(" ")];
    const r = typeof s === "function" ? s(cwd) : s;
    if (!r)
      return {
        exitCode: 127,
        stdout: "",
        stderr: `not scripted: ${argv.join(" ")}`,
        timedOut: false,
      };
    return { exitCode: 0, stdout: "", stderr: "", timedOut: false, ...r };
  }

  private agent(): AgentRunner {
    return {
      decide: async () => {
        throw new Error("not used");
      },
      runTask: async (spec) => {
        this.tasks.push(spec);
        for (const [p, t] of Object.entries(this.agentWrites(this.tasks.length)))
          this.tree(spec.cwd).set(p, t);
        const usage = { costUsd: 0.25, inputTokens: 1, outputTokens: 1, durationMs: 1 };
        return ok({ summary: "done", usage, turns: 1, sessionId: "s" });
      },
    };
  }

  private sourcePort(): EnvPorts["source"] {
    return {
      fileAt: async (_root, _ref, path) => ok(this.committed.get(path) ?? null),
      readFile: async (root, path) => ok(this.tree(root).get(path) ?? null),
      digests: async (root, paths) =>
        ok(
          Object.fromEntries(
            paths.map((p) => [p, this.tree(root).has(p) ? `d:${this.tree(root).get(p)}` : null]),
          ),
        ),
      rootEntries: async (root) =>
        ok([...new Set([...this.tree(root).keys()].map((p) => p.split("/")[0] ?? p))]),
      repoId: async () => ok("repo-1"),
    };
  }

  private cachePort(): EnvPorts["cache"] {
    return {
      dirFor: (repo, key) => `/cache/${repo}/${key}`,
      get: async (repo, key) => ok(this.cache.get(`${repo}/${key}`)?.entry ?? null),
      restore: async (entry, dir) => {
        const snap = this.cache.get(`${entry.repoId}/${entry.key}`);
        if (!snap) return err({ kind: "not_found", message: "gone" });
        for (const [p, t] of snap.files) this.tree(dir).set(p, t);
        return ok(undefined);
      },
      save: async (repo, key, dir, paths) => {
        if (this.cache.has(`${repo}/${key}`)) return ok("exists" as const);
        const files = new Map(
          [...this.tree(dir)].filter(([p]) => paths.some((c) => p === c || p.startsWith(`${c}/`))),
        );
        const entry = {
          repoId: repo,
          key,
          createdAt: "t",
          usedAt: "t",
          bytes: files.size,
          paths: [...paths],
        };
        this.cache.set(`${repo}/${key}`, { entry, files });
        return ok("saved" as const);
      },
      list: async (repo) =>
        ok([...this.cache.values()].map((v) => v.entry).filter((e) => e.repoId === repo)),
      remove: async (repo, key) => {
        this.cache.delete(`${repo}/${key}`);
        return ok(undefined);
      },
    };
  }

  private scratchPort(): EnvPorts["scratch"] {
    return {
      clone: async (root) => {
        const dir = `/scratch/${++this.clones}`;
        const t = this.tree(dir);
        for (const [p, v] of this.tree(root))
          if (!p.startsWith(".shipwright/") && !p.startsWith("node_modules")) t.set(p, v);
        return ok(dir);
      },
      write: async (root, path, text) => {
        this.tree(root).set(path, text);
        return ok(undefined);
      },
      remove: async (dir) => {
        this.trees.delete(dir);
        return ok(undefined);
      },
    };
  }

  ports(): EnvPorts {
    return {
      source: this.sourcePort(),
      cache: this.cachePort(),
      exec: { run: async (argv, cwd) => this.exec(argv, cwd) },
      scratch: this.scratchPort(),
      agent: () => this.agent(),
      digest: (text) => Bun.hash(text).toString(16).padStart(32, "0").repeat(2).slice(0, 64),
      platform: { os: "darwin", arch: "arm64" },
      sleep: async (ms) => {
        this.clock += ms;
      },
      now: () => this.clock,
    };
  }
}
