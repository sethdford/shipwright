import { tmpdir } from "node:os";
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
 * Wires the benchmark adapters. The mirror cache lives under `<state dir>/bench`, checkouts under
 * the system temp dir; agents run under the
 * repo's `config/agent-permissions.json`. CLAUDE_BIN picks the `claude` binary; SHIPWRIGHT_BENCH_BIN
 * picks the Shipwright under test (default: this checkout's scripts/sw), e.g. an installed release.
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
      // Checkouts live away from the mirror cache, so `..` from a workspace does not lead to it.
      workspaces: new GitBenchWorkspaces(
        runner,
        join(paths.stateDir, "bench"),
        toolEnv,
        join(tmpdir(), `shipwright-bench-work-${process.getuid?.() ?? "user"}`),
      ),
      grader: new ProcessBenchGrader(runner, toolEnv),
      store: new JsonlBenchStore(outDir),
      arms: new ProcessArmRunner(
        runner,
        new LedgerSpend(new JsonCostLedger(join(paths.home, ".shipwright"))),
        {
          claudeBin: env.CLAUDE_BIN ?? "claude",
          shipwrightBin: env.SHIPWRIGHT_BENCH_BIN ?? join(repoRoot, "scripts", "sw"),
          policyPath: join(repoRoot, "config", "agent-permissions.json"),
          env,
          now,
        },
      ),
    }),
    holdout: (repo) => new GhHoldoutSource(runner, repo),
  };
}
