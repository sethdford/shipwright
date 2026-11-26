import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProofBranchWriter, ProofPublished, ProofUpload } from "../../contexts/integrations";
import type { IdempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";

/**
 * Publishes proof artifacts to the `shipwright-proof` branch with git plumbing (ADR-0019, F10):
 * blobs, a tree and a commit are built in a throwaway index, so the working tree, the real index
 * and the checked-out branch are never touched. The push is a fast-forward of the proof branch
 * only; a race with another run re-reads the tip and tries again.
 */

export const PROOF_BRANCH = "shipwright-proof";
const TIP_REF = "refs/shipwright/proof-tip";
const TIMEOUT_MS = 120_000;
const ATTEMPTS = 3;
const IDENTITY = {
  GIT_AUTHOR_NAME: "shipwright",
  GIT_AUTHOR_EMAIL: "shipwright@users.noreply.github.com",
  GIT_COMMITTER_NAME: "shipwright",
  GIT_COMMITTER_EMAIL: "shipwright@users.noreply.github.com",
};

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

export class GitProofBranch implements ProofBranchWriter {
  constructor(
    private readonly runner: ProcessRunner,
    private readonly env: Readonly<Record<string, string>>,
  ) {}

  async publishProof(
    key: IdempotencyKey,
    upload: ProofUpload,
  ): Promise<Result<ProofPublished, AdapterError>> {
    const remote = await this.git(upload.repoRoot, ["config", "--get", "remote.origin.url"]);
    if (!remote.ok) return remote;
    const repo = githubRepoOf(remote.value);
    if (repo === null) return err(fail("origin is not a GitHub repository"));
    const url = (commit: string) => `https://github.com/${repo}/raw/${commit}/${upload.prefix}/`;
    let last: AdapterError = fail("no attempt");
    for (let i = 0; i < ATTEMPTS; i++) {
      const tip = await this.fetchTip(upload.repoRoot);
      if (!tip.ok) return tip;
      const existing = tip.value ? await this.find(upload.repoRoot, key) : null;
      if (existing) return ok({ commit: existing, baseUrl: url(existing), action: "unchanged" });
      const commit = await this.commit(key, upload, tip.value);
      if (!commit.ok) return commit;
      const pushed = await this.git(upload.repoRoot, [
        "push",
        "--quiet",
        "origin",
        `${commit.value}:refs/heads/${PROOF_BRANCH}`,
      ]);
      if (pushed.ok)
        return ok({ commit: commit.value, baseUrl: url(commit.value), action: "created" });
      last = pushed.error;
      if (!/rejected|fetch first|non-fast-forward|stale info/i.test(last.message)) return pushed;
    }
    return err(last);
  }

  /** The proof branch tip as a local ref, or null when the branch does not exist yet. */
  private async fetchTip(root: string): Promise<Result<string | null, AdapterError>> {
    const listed = await this.git(root, ["ls-remote", "origin", `refs/heads/${PROOF_BRANCH}`]);
    if (!listed.ok) return listed;
    if (listed.value.trim() === "") return ok(null);
    const fetched = await this.git(root, [
      "fetch",
      "--quiet",
      "--depth=50",
      "origin",
      `+refs/heads/${PROOF_BRANCH}:${TIP_REF}`,
    ]);
    if (!fetched.ok) return fetched;
    const sha = await this.git(root, ["rev-parse", "--verify", `${TIP_REF}^{commit}`]);
    return sha.ok && SHA.test(sha.value.trim())
      ? ok(sha.value.trim())
      : err(fail("cannot read the proof branch tip"));
  }

  private async find(root: string, key: IdempotencyKey): Promise<string | null> {
    const log = await this.git(root, ["log", "-n", "50", "--format=%H%x00%B%x1e", TIP_REF]);
    if (!log.ok) return null;
    const marker = proofMarker(key);
    for (const entry of log.value.split("\x1e")) {
      const [sha, body] = entry.trim().split("\0");
      if (sha && SHA.test(sha) && body?.split("\n").some((l) => l.trim() === marker)) return sha;
    }
    return null;
  }

  private async commit(
    key: IdempotencyKey,
    upload: ProofUpload,
    parent: string | null,
  ): Promise<Result<string, AdapterError>> {
    const dir = mkdtempSync(join(tmpdir(), "sw-proof-index-"));
    try {
      const env = { ...this.env, ...IDENTITY, GIT_INDEX_FILE: join(dir, "index") };
      const tree = await this.tree(upload, env);
      if (!tree.ok) return tree;
      const message = `proof: ${upload.prefix}\n\n${proofMarker(key)}`;
      const args = ["commit-tree", tree.value, ...(parent ? ["-p", parent] : []), "-m", message];
      const commit = await this.git(upload.repoRoot, args, undefined, env);
      return commit.ok ? ok(commit.value.trim()) : commit;
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  /** Writes the run's files as blobs into a throwaway index and returns its tree. */
  private async tree(
    upload: ProofUpload,
    env: Readonly<Record<string, string>>,
  ): Promise<Result<string, AdapterError>> {
    const paths = upload.files.map((f) => join(upload.dir, f)).join("\n");
    const hash = ["hash-object", "-w", "--stdin-paths"];
    const blobs = await this.git(upload.repoRoot, hash, paths, env);
    if (!blobs.ok) return blobs;
    const shas = blobs.value.trim().split("\n");
    if (shas.length !== upload.files.length || !shas.every((s) => SHA.test(s)))
      return err(fail("git hash-object returned unexpected output"));
    const info = upload.files.map((f, i) => `100644 blob ${shas[i]}\t${upload.prefix}/${f}`);
    const update = ["update-index", "--add", "--index-info"];
    const indexed = await this.git(upload.repoRoot, update, `${info.join("\n")}\n`, env);
    if (!indexed.ok) return indexed;
    const tree = await this.git(upload.repoRoot, ["write-tree"], undefined, env);
    return tree.ok ? ok(tree.value.trim()) : tree;
  }

  private async git(
    root: string,
    args: readonly string[],
    stdin?: string,
    env: Readonly<Record<string, string>> = this.env,
  ): Promise<Result<string, AdapterError>> {
    const r = await runOrFail(this.runner, {
      argv: ["git", "-C", root, ...args],
      env,
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
