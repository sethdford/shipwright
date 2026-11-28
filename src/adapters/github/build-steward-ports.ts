import type { StewardPorts } from "../../contexts/delivery";
import { GitLocalChange } from "../git/git-local-change";
import { BunProcessRunner } from "../process/bun-process-runner";
import { GhGithubWriter } from "./gh-github-writer";
import { GhStewardReader } from "./gh-steward-reader";

/** Adapters for the PR steward: GitHub reads, the F10 writer and the local diff (ADR-0017). */
export function buildStewardPorts(cwd: string): StewardPorts {
  const runner = new BunProcessRunner();
  return {
    reader: new GhStewardReader(runner),
    writer: new GhGithubWriter(runner),
    change: new GitLocalChange(runner, cwd),
  };
}
