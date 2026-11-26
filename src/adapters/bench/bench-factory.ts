import { join } from "node:path";
import type { BenchFactory } from "../../contexts/quality";
import { GhHoldoutSource } from "../github/gh-holdout-source";
import { resolvePaths } from "../paths";
import { BunProcessRunner } from "../process/bun-process-runner";
import { JsonCostLedger } from "../state/json-cost-ledger";
import { LedgerSpend } from "../state/ledger-spend";
import { agentEnv } from "./agent-env";
import { GitBenchWorkspaces } from "./git-bench-workspaces";
import { JsonlBenchStore } from "./jsonl-bench-store";
import { ProcessArmRunner } from "./process-arm-runner";
import { ProcessBenchGrader } from "./process-bench-grader";

/**
 * Wires the benchmark adapters. Checkouts live under `<state dir>/bench`; agents run under the
 * repo's `config/agent-permissions.json`; set CLAUDE_BIN to use a specific `claude` binary.
 */
export function buildBenchFactory(
  env: Readonly<Record<string, string | undefined>>,
  repoRoot: string,
): BenchFactory {
  const runner = new BunProcessRunner({ reapGroup: true });
  const paths = resolvePaths(env);
  const toolEnv = agentEnv(env);
  const now = () => Date.now();
  return {
    ports: (outDir) => ({
      now,
      workspaces: new GitBenchWorkspaces(runner, join(paths.stateDir, "bench"), toolEnv),
      grader: new ProcessBenchGrader(runner, toolEnv),
      store: new JsonlBenchStore(outDir),
      arms: new ProcessArmRunner(
        runner,
        new LedgerSpend(new JsonCostLedger(join(paths.home, ".shipwright"))),
        {
          claudeBin: env.CLAUDE_BIN ?? "claude",
          shipwrightBin: join(repoRoot, "scripts", "sw"),
          policyPath: join(repoRoot, "config", "agent-permissions.json"),
          env,
          now,
        },
      ),
    }),
    holdout: (repo) => new GhHoldoutSource(runner, repo),
  };
}
