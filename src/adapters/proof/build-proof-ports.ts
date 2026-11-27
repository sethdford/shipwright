import { mkdirSync, mkdtempSync } from "node:fs";
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
  // A fresh, private folder per run (mkdtemp, 0700) unless the caller names one.
  const base = join(resolvePaths(env).stateDir, "proof");
  mkdirSync(base, { recursive: true, mode: 0o700 });
  const dir = outDir ?? mkdtempSync(join(base, `${new Date().toISOString().slice(0, 10)}-`));
  const clean = testEnv(env);
  // The push runs here, in this trusted process, with the pipeline's own git credentials.
  const full: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined) full[k] = v;
  const chromium = env.SHIPWRIGHT_PROOF_CHROMIUM;
  return {
    repo: new FsProofRepo(runner, root),
    launcher: new GatedAppLauncher(gate, root, clean),
    browser: new PlaywrightBrowser(undefined, chromium && chromium !== "" ? chromium : undefined),
    cli: new TestGateExecutor(runner, gate, root),
    artifacts: new NodeProofArtifacts(dir),
    publisher: new GitProofPublisher(new GitProofBranch(runner, full), root),
  };
}
