import { parseAddedLines, type SurvivalInput, type SurvivalSource } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

const SHA = /^[0-9a-f]{7,64}$/;
/** Files per change read at the horizon; a larger change is measured on its first files. */
export const MAX_SURVIVAL_FILES = 300;
/** Refs tried, in order, for the base branch's history. */
export const BASE_REFS = ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "HEAD"] as const;

type Git = { code: number; out: string };

/**
 * Code survival from the local clone (read-only): the merge commit's diff against its first
 * parent, then each touched file at the last base-branch commit before merge + horizon. Returns
 * null, never an error, when the history is not there (a shallow clone, an unfetched merge, a
 * horizon commit that does not contain the merge), so the PR keeps its merge label.
 */
export class GitSurvivalSource implements SurvivalSource {
  private base: string | null | undefined;

  constructor(
    private readonly runner: ProcessRunner,
    private readonly cwd: string,
  ) {}

  async read(
    mergeSha: string,
    mergedAtMs: number,
    horizonMs: number,
  ): Promise<Result<SurvivalInput | null, AdapterError>> {
    if (!SHA.test(mergeSha)) return err({ kind: "failed", message: `not a commit: ${mergeSha}` });
    const base = await this.baseRef();
    if (base === null) return ok(null);
    if ((await this.git(["cat-file", "-e", `${mergeSha}^{commit}`])).code !== 0) return ok(null);
    const before = `@${Math.floor((mergedAtMs + horizonMs) / 1000)}`;
    const snap = await this.git(["rev-list", "-1", "--first-parent", `--before=${before}`, base]);
    const at = snap.out.trim();
    if (snap.code !== 0 || !SHA.test(at)) return ok(null);
    if ((await this.git(["merge-base", "--is-ancestor", mergeSha, at])).code !== 0) return ok(null);
    // A clone last fetched before the horizon would measure survival too early: require history past it.
    const past = await this.git(["rev-list", "-1", "--first-parent", `--since=${before}`, base]);
    if (past.code !== 0 || past.out.trim() === "") return ok(null);
    const diff = await this.git([
      "diff",
      "-U0",
      "--no-color",
      "--no-renames",
      `${mergeSha}^1`,
      mergeSha,
    ]);
    if (diff.code !== 0) return ok(null);
    const added = new Map([...parseAddedLines(diff.out)].slice(0, MAX_SURVIVAL_FILES));
    const later = new Map<string, string | null>();
    for (const path of added.keys()) {
      const show = await this.git(["show", `${at}:${path}`]);
      later.set(path, show.code === 0 ? show.out : null);
    }
    return ok({ added, later });
  }

  private async baseRef(): Promise<string | null> {
    if (this.base !== undefined) return this.base;
    this.base = null;
    for (const ref of BASE_REFS) {
      if ((await this.git(["rev-parse", "--verify", "--quiet", ref])).code === 0) {
        this.base = ref;
        break;
      }
    }
    return this.base;
  }

  private async git(args: readonly string[]): Promise<Git> {
    const r = await runOrFail(this.runner, {
      argv: ["git", "-c", "core.quotePath=false", ...args],
      cwd: this.cwd,
      timeoutMs: 60_000,
    });
    return { code: r.timedOut ? 124 : r.exitCode, out: r.stdout };
  }
}
