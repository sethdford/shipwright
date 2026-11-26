import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import type { ProofBranchWriter } from "../../contexts/integrations";
import type { ProofPublisher } from "../../contexts/quality";
import { idempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

/**
 * Picks a proof run's files and hands them to the proof branch writer (ADR-0019). Only regular
 * files with plain names are published, none over the size caps, so a large video or a stray
 * dot-file never leaves the machine. The folder and key come from the label and the content
 * hash, so publishing the same run twice reuses the first commit.
 */

const MAX_FILE = 25_000_000;
const MAX_TOTAL = 60_000_000;
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/;

export function listFiles(dir: string, root: string = dir): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!NAME.test(entry.name)) continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listFiles(path, root));
    else if (entry.isFile()) out.push(relative(root, path));
  }
  return out.sort();
}

export function labelSlug(label: string): string {
  const slug = label
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^[-.]+|[-.]+$/g, "")
    .slice(0, 60);
  return slug === "" ? "run" : slug;
}

export class GitProofPublisher implements ProofPublisher {
  constructor(
    private readonly writer: ProofBranchWriter,
    private readonly repoRoot: string,
  ) {}

  async publish(
    dir: string,
    label: string,
    wanted: readonly string[],
  ): Promise<Result<string, AdapterError>> {
    const picked = this.pick(dir, new Set(wanted));
    if (picked.files.length === 0)
      return err({ kind: "failed", message: "no artifacts to publish" });
    const prefix = `${labelSlug(label)}/${picked.hash.slice(0, 12)}`;
    const key = idempotencyKey("proof", prefix, picked.hash);
    const r = await this.writer.publishProof(key, {
      repoRoot: this.repoRoot,
      dir,
      files: picked.files,
      prefix,
    });
    return r.ok ? ok(r.value.baseUrl) : r;
  }

  /** The wanted files that exist as plain files in `dir`, within the size caps. */
  private pick(dir: string, wanted: ReadonlySet<string>): { files: string[]; hash: string } {
    const hash = createHash("sha256");
    const files: string[] = [];
    let total = 0;
    for (const file of listFiles(dir).filter((f) => wanted.has(f))) {
      const size = statSync(join(dir, file)).size;
      if (size > MAX_FILE || total + size > MAX_TOTAL) continue;
      total += size;
      files.push(file);
      hash
        .update(file)
        .update("\0")
        .update(readFileSync(join(dir, file)));
    }
    return { files, hash: hash.digest("hex") };
  }
}
