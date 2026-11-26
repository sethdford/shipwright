import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProofBranchWriter, ProofPublished, ProofUpload } from "../../contexts/integrations";
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

/**
 * Publishes proof artifacts to the `shipwright-proof` branch (ADR-0019, F10). All git work happens
 * in a throwaway bare repository: the user's clone is never fetched into (so never made shallow),
 * and nothing the agent could have written in it applies here: no hooks, no .gitattributes
 * filters, no config but the origin URL and its auth header, which the pipeline's own push already
 * uses. The push is a fast-forward of the proof branch only; a race re-reads the tip and retries.
 */

export const PROOF_BRANCH = "shipwright-proof";
const TIP_REF = "refs/proof-tip";
const TIMEOUT_MS = 120_000;
const ATTEMPTS = 3;
const DEPTH = "20";
const IDENTITY = {
  GIT_AUTHOR_NAME: "shipwright",
  GIT_AUTHOR_EMAIL: "shipwright@users.noreply.github.com",
  GIT_COMMITTER_NAME: "shipwright",
  GIT_COMMITTER_EMAIL: "shipwright@users.noreply.github.com",
};
/** Repository-independent safety settings for every git call (hooks off, no fsmonitor). */
const SAFE = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"];

export const proofMarker = (key: IdempotencyKey): string => `shipwright-idempotency-key: ${key}`;

/** owner/repo of a GitHub remote URL (https, ssh or git@), or null for anything else. */
export function githubRepoOf(url: string): string | null {
  const m =
    /^(?:https:\/\/(?:[^@/]+@)?github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?\/?$/.exec(
      url.trim(),
    );
  return m?.[1] ?? null;
}

const SHA = /^[0-9a-f]{40,64}$/;
const fail = (message: string): AdapterError => ({ kind: "failed", message });

interface Remote {
  readonly url: string;
  readonly repo: string;
  /** GIT_CONFIG_* variables carrying the clone's GitHub auth header (actions/checkout). */
  readonly auth: Readonly<Record<string, string>>;
}

export class GitProofBranch implements ProofBranchWriter {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly env: Readonly<Record<string, string>>,
  ) {}

  async publishProof(
    key: IdempotencyKey,
    upload: ProofUpload,
  ): Promise<Result<ProofPublished, AdapterError>> {
    const remote = await this.remote(upload.repoRoot);
    if (!remote.ok) return remote;
    const work = mkdtempSync(join(tmpdir(), "sw-proof-git-"));
    try {
      const init = await this.git(work, ["init", "--quiet", "--bare", work]);
      if (!init.ok) return init;
      return await this.attempts(work, remote.value, key, upload);
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }

  private async attempts(
    work: string,
    remote: Remote,
    key: IdempotencyKey,
    upload: ProofUpload,
  ): Promise<Result<ProofPublished, AdapterError>> {
    const url = (c: string) => `https://github.com/${remote.repo}/raw/${c}/${upload.prefix}/`;
    let last: AdapterError = fail("no attempt");
    for (let i = 0; i < ATTEMPTS; i++) {
      const tip = await this.fetchTip(work, remote);
      if (!tip.ok) return tip;
      const existing = tip.value ? await this.find(work, key) : null;
      if (existing) return ok({ commit: existing, baseUrl: url(existing), action: "unchanged" });
      const commit = await this.commit(work, key, upload, tip.value);
      if (!commit.ok) return commit;
      const ref = `${commit.value}:refs/heads/${PROOF_BRANCH}`;
      const pushed = await this.git(
        work,
        ["push", "--quiet", "--no-verify", remote.url, ref],
        remote.auth,
      );
      if (pushed.ok)
        return ok({ commit: commit.value, baseUrl: url(commit.value), action: "created" });
      last = pushed.error;
      if (!/rejected|fetch first|non-fast-forward|stale info/i.test(last.message)) return pushed;
    }
    return err(last);
  }

  /** The clone's origin URL and GitHub auth header, read as plain config values. */
  private async remote(root: string): Promise<Result<Remote, AdapterError>> {
    const url = await this.git(root, ["config", "--get", "remote.origin.url"]);
    if (!url.ok) return url;
    const repo = githubRepoOf(url.value);
    if (repo === null) return err(fail("origin is not a GitHub repository"));
    const headers = await this.git(root, [
      "config",
      "--get-regexp",
      "^http\\.https://github\\.com/\\.extraheader$",
    ]);
    const auth: Record<string, string> = {};
    const line = headers.ok ? headers.value.trim().split("\n")[0] : undefined;
    const m = line ? /^(\S+) (.+)$/.exec(line) : null;
    if (m?.[1] && m[2]) {
      Object.assign(auth, {
        GIT_CONFIG_COUNT: "1",
        GIT_CONFIG_KEY_0: m[1],
        GIT_CONFIG_VALUE_0: m[2],
      });
    }
    return ok({ url: url.value.trim(), repo, auth });
  }

  /** The proof branch tip, fetched shallowly into the throwaway repo, or null when it is new. */
  private async fetchTip(
    work: string,
    remote: Remote,
  ): Promise<Result<string | null, AdapterError>> {
    const ref = `refs/heads/${PROOF_BRANCH}`;
    const listed = await this.git(work, ["ls-remote", remote.url, ref], remote.auth);
    if (!listed.ok) return listed;
    if (listed.value.trim() === "") return ok(null);
    const args = ["fetch", "--quiet", `--depth=${DEPTH}`, remote.url, `+${ref}:${TIP_REF}`];
    const fetched = await this.git(work, args, remote.auth);
    if (!fetched.ok) return fetched;
    const sha = await this.git(work, ["rev-parse", "--verify", `${TIP_REF}^{commit}`]);
    return sha.ok && SHA.test(sha.value.trim())
      ? ok(sha.value.trim())
      : err(fail("cannot read the proof branch tip"));
  }

  /** A commit among the recent ones that already carries this key. */
  private async find(work: string, key: IdempotencyKey): Promise<string | null> {
    const log = await this.git(work, ["log", "-n", DEPTH, "--format=%H%x00%B%x1e", TIP_REF]);
    if (!log.ok) return null;
    const marker = proofMarker(key);
    for (const entry of log.value.split("\x1e")) {
      const [sha, body] = entry.trim().split("\0");
      if (sha && SHA.test(sha) && body?.split("\n").some((l) => l.trim() === marker)) return sha;
    }
    return null;
  }

  private async commit(
    work: string,
    key: IdempotencyKey,
    upload: ProofUpload,
    parent: string | null,
  ): Promise<Result<string, AdapterError>> {
    const env = { ...IDENTITY, GIT_INDEX_FILE: join(work, "proof-index") };
    const tree = await this.tree(work, upload, env);
    if (!tree.ok) return tree;
    const message = `proof: ${upload.prefix}\n\n${proofMarker(key)}`;
    const args = ["commit-tree", tree.value, ...(parent ? ["-p", parent] : []), "-m", message];
    const commit = await this.git(work, args, env);
    return commit.ok ? ok(commit.value.trim()) : commit;
  }

  /** Stores the run's files as blobs (no filters: bytes as they are) and returns their tree. */
  private async tree(
    work: string,
    upload: ProofUpload,
    env: Readonly<Record<string, string>>,
  ): Promise<Result<string, AdapterError>> {
    const paths = upload.files.map((f) => join(upload.dir, f)).join("\n");
    const hash = ["hash-object", "-w", "--no-filters", "--stdin-paths"];
    const blobs = await this.git(work, hash, env, paths);
    if (!blobs.ok) return blobs;
    const shas = blobs.value.trim().split("\n");
    if (shas.length !== upload.files.length || !shas.every((s) => SHA.test(s)))
      return err(fail("git hash-object returned unexpected output"));
    const info = upload.files.map((f, i) => `100644 blob ${shas[i]}\t${upload.prefix}/${f}`);
    const update = ["update-index", "--add", "--index-info"];
    const indexed = await this.git(work, update, env, `${info.join("\n")}\n`);
    if (!indexed.ok) return indexed;
    const tree = await this.git(work, ["write-tree"], env);
    return tree.ok ? ok(tree.value.trim()) : tree;
  }

  private async git(
    dir: string,
    args: readonly string[],
    extraEnv: Readonly<Record<string, string>> = {},
    stdin?: string,
  ): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["git", ...SAFE, "-C", dir, ...args],
      env: { ...this.env, ...extraEnv },
      timeoutMs: TIMEOUT_MS,
      ...(stdin === undefined ? {} : { stdin }),
    });
    if (r.exitCode === 0) return ok(r.stdout);
    return err({
      kind: r.timedOut ? "transient" : "failed",
      message: `git ${args[0]}: ${r.stderr.trim().slice(0, 300)}`,
    });
  }
}
