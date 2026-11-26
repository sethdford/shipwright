import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, normalize, sep } from "node:path";
import type { ProofArtifacts } from "../../contexts/quality";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";

/**
 * A proof run's output folder (ADR-0019). Writes stay inside it: a path that climbs out, or a
 * folder on the way that is a symlink (the app under test could plant one), is refused. Each
 * write records the sha256 of what was written.
 */
export class NodeProofArtifacts implements ProofArtifacts {
  private readonly hashes = new Map<string, string>();
  private readonly root: string;

  constructor(readonly dir: string) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    this.root = realpathSync(dir);
  }

  digests(): ReadonlyMap<string, string> {
    return this.hashes;
  }

  async write(relPath: string, data: string | Uint8Array): Promise<Result<void, AdapterError>> {
    const clean = normalize(relPath);
    const target = join(this.root, clean);
    if (clean.startsWith("..") || clean.startsWith(sep) || !this.inside(dirname(target)))
      return err({ kind: "failed", message: `path outside the run folder: ${relPath}` });
    try {
      // A temp file and a rename: the rename replaces whatever is at the target, a planted
      // symlink included, instead of writing through it.
      const tmp = `${target}.tmp.${process.pid}`;
      writeFileSync(tmp, data, { mode: 0o600, flag: "wx" });
      renameSync(tmp, target);
    } catch (cause) {
      return err({ kind: "failed", message: String(cause) });
    }
    this.hashes.set(clean, createHash("sha256").update(data).digest("hex"));
    return ok(undefined);
  }

  /** Creates `folder` and checks that no part of it below the root is a symlink. */
  private inside(folder: string): boolean {
    try {
      mkdirSync(folder, { recursive: true, mode: 0o700 });
      let here = folder;
      while (here.length > this.root.length) {
        if (lstatSync(here).isSymbolicLink()) return false;
        here = dirname(here);
      }
      return here === this.root && realpathSync(folder).startsWith(this.root);
    } catch {
      return false;
    }
  }
}
