import { createHash } from "node:crypto";
import {
  closeSync,
  constants,
  fstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, normalize } from "node:path";
import type { ProofBranchWriter } from "../../contexts/integrations";
import type { ProofFile, ProofPublisher } from "../../contexts/quality";
import { idempotencyKey } from "../../shared/kernel/durability";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

/**
 * Hands a proof run's files to the proof branch writer (ADR-0019). The app under test runs as the
 * same user and could rewrite or swap a file after it was captured, so each file is opened without
 * following symlinks, read once, checked against the digest recorded when the run wrote it, and
 * copied into a private staging folder; git reads only that copy. One mismatch stops the publish.
 * The folder and key come from the label and the content hash, so a repeat reuses the commit.
 */

const MAX_FILE = 25_000_000;
const MAX_TOTAL = 60_000_000;
const PATH = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}(\/[A-Za-z0-9][A-Za-z0-9._-]{0,120}){0,3}$/;

export function labelSlug(label: string): string {
  const slug = label
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^[-.]+|[-.]+$/g, "")
    .slice(0, 60);
  return slug === "" ? "run" : slug;
}

/** The file's bytes, read through a descriptor opened without following symlinks. */
export function readRegular(path: string): Buffer | null {
  let fd: number | null = null;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > MAX_FILE) return null;
    return readFileSync(fd);
  } catch {
    return null;
  } finally {
    if (fd !== null) closeSync(fd);
  }
}

type Staged = { readonly files: string[]; readonly hash: string };

export class GitProofPublisher implements ProofPublisher {
  constructor(
    private readonly writer: ProofBranchWriter,
    private readonly repoRoot: string,
  ) {}

  async publish(
    dir: string,
    label: string,
    files: readonly ProofFile[],
  ): Promise<Result<string, AdapterError>> {
    const staging = mkdtempSync(join(tmpdir(), "sw-proof-stage-"));
    try {
      const staged = stage(dir, files, staging);
      if (!staged.ok) return staged;
      if (staged.value.files.length === 0)
        return err({ kind: "failed", message: "no artifacts to publish" });
      const prefix = `${labelSlug(label)}/${staged.value.hash.slice(0, 12)}`;
      const key = idempotencyKey("proof", prefix, staged.value.hash);
      const upload = { repoRoot: this.repoRoot, dir: staging, files: staged.value.files, prefix };
      const r = await this.writer.publishProof(key, upload);
      return r.ok ? ok(r.value.baseUrl) : r;
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }
  }
}

/** Verified copies of the files in `staging`, within the size caps, and their combined hash. */
function stage(
  dir: string,
  files: readonly ProofFile[],
  staging: string,
): Result<Staged, AdapterError> {
  const hash = createHash("sha256");
  const out: string[] = [];
  let total = 0;
  for (const f of [...files].sort((a, b) => a.path.localeCompare(b.path))) {
    const path = normalize(f.path);
    if (!PATH.test(path)) continue;
    const bytes = readRegular(join(dir, path));
    if (bytes === null || total + bytes.length > MAX_TOTAL) continue;
    if (createHash("sha256").update(bytes).digest("hex") !== f.sha256)
      return err({
        kind: "failed",
        message: `${path} changed after the run wrote it; nothing was published`,
      });
    mkdirSync(dirname(join(staging, path)), { recursive: true, mode: 0o700 });
    writeFileSync(join(staging, path), bytes, { mode: 0o600 });
    total += bytes.length;
    out.push(path);
    hash.update(path).update("\0").update(bytes);
  }
  return ok({ files: out, hash: hash.digest("hex") });
}
