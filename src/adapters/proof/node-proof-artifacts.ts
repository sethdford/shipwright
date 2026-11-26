import { mkdirSync } from "node:fs";
import { join, normalize } from "node:path";
import type { ProofArtifacts } from "../../contexts/quality";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, type Result } from "../../shared/kernel/result";
import { NodeArtifactStore } from "../state/node-artifact-store";

/** A proof run's output folder. Writes stay inside it: a path that climbs out is refused. */
export class NodeProofArtifacts implements ProofArtifacts {
  private readonly store = new NodeArtifactStore();

  constructor(readonly dir: string) {
    mkdirSync(dir, { recursive: true });
  }

  write(relPath: string, text: string): Promise<Result<void, AdapterError>> {
    const clean = normalize(relPath);
    if (clean.startsWith("..") || clean.startsWith("/"))
      return Promise.resolve(
        err({ kind: "failed", message: `path outside the run folder: ${relPath}` }),
      );
    return this.store.write(join(this.dir, clean), text);
  }
}
