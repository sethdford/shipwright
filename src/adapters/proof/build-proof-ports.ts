import { join } from "node:path";
import type { ProofPorts } from "../../contexts/quality";
import { GitProofBranch } from "../github/git-proof-branch";
import { resolvePaths } from "../paths";
import { testEnv } from "../process/bash-command-runner";
import { BunProcessRunner } from "../process/bun-process-runner";
import { TestGateExecutor } from "../process/test-gate-executor";
import { FsProofRepo } from "./fs-proof-repo";
import { GatedAppLauncher } from "./gated-app-launcher";
import { GitProofPublisher } from "./git-proof-publisher";
import { NodeProofArtifacts } from "./node-proof-artifacts";
import { PlaywrightBrowser } from "./playwright-browser";

/**
 * Adapters for `shipwright proof` (ADR-0019). The app and CLI runs go through test-gate-exec.sh
 * (no credentials); only the publisher, which runs in this trusted process, uses git's push
 * credentials. `outDir` null puts the run under the state directory.
 */
export function buildProofPorts(
  env: Readonly<Record<string, string | undefined>>,
  root: string,
  shipwrightRoot: string,
  outDir: string | null,
): ProofPorts {
  const runner = new BunProcessRunner({ reapGroup: true });
  const gate = join(shipwrightRoot, "scripts", "lib", "test-gate-exec.sh");
  const run = `${new Date().toISOString().replace(/[:.]/g, "-")}-${process.pid}`;
  const dir = outDir ?? join(resolvePaths(env).stateDir, "proof", run);
  const clean = testEnv(env);
  const chromium = env.SHIPWRIGHT_PROOF_CHROMIUM;
  return {
    repo: new FsProofRepo(runner, root),
    launcher: new GatedAppLauncher(gate, root, clean),
    browser: new PlaywrightBrowser(undefined, chromium && chromium !== "" ? chromium : undefined),
    cli: new TestGateExecutor(runner, gate, root),
    artifacts: new NodeProofArtifacts(dir),
    publisher: new GitProofPublisher(new GitProofBranch(runner, clean), root),
  };
}
