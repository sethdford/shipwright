import { createHash } from "node:crypto";
import { join } from "node:path";
import pkg from "../package.json";
import { AgentSdkRunner, agentEnv } from "./adapters/agent/agent-sdk-runner";
import { buildBenchFactory } from "./adapters/bench/bench-factory";
import { FsEnvCache } from "./adapters/env/fs-env-cache";
import { GitEnvSource } from "./adapters/env/git-env-source";
import { GitScratch } from "./adapters/env/git-scratch";
import { JailedEnvExecutor } from "./adapters/env/jailed-env-executor";
import { GitAcceptanceWorkspace } from "./adapters/git/git-acceptance-workspace";
import { GitHistorySource } from "./adapters/git/git-history-source";
import { GitLocalChange } from "./adapters/git/git-local-change";
import { GitRepoDocs } from "./adapters/git/git-repo-docs";
import { GitRepoSource } from "./adapters/git/git-repo-source";
import { GitSurvivalSource } from "./adapters/git/git-survival-source";
import { GitWorkspaces } from "./adapters/git/git-workspaces";
import { buildStewardPorts } from "./adapters/github/build-steward-ports";
import { GhClosedPulls } from "./adapters/github/gh-closed-pulls";
import { GhGithubWriter } from "./adapters/github/gh-github-writer";
import { GhOpenIssues } from "./adapters/github/gh-open-issues";
import { GhPauseLabel } from "./adapters/github/gh-pause-label";
import { GhPullFiles } from "./adapters/github/gh-pull-files";
import { GhPullRequests } from "./adapters/github/gh-pull-requests";
import { GhRunHistory } from "./adapters/github/gh-run-history";
import { resolvePaths } from "./adapters/paths";
import { BashCommandRunner, testEnv } from "./adapters/process/bash-command-runner";
import { BunProcessRunner } from "./adapters/process/bun-process-runner";
import { processStdio } from "./adapters/process/stdio-lines";
import { TestGateExecutor } from "./adapters/process/test-gate-executor";
import { buildProofPorts } from "./adapters/proof/build-proof-ports";
import { FilePauseFlag } from "./adapters/state/file-pause-flag";
import { JsonCostLedger } from "./adapters/state/json-cost-ledger";
import { JsonModelStore } from "./adapters/state/json-model-store";
import { JsonVerifierStore } from "./adapters/state/json-verifier-store";
import { JsonlRoutingLog } from "./adapters/state/jsonl-routing-log";
import { JsonlScoreLog } from "./adapters/state/jsonl-score-log";
import { LedgerSpend } from "./adapters/state/ledger-spend";
import { NodeArtifactStore } from "./adapters/state/node-artifact-store";
import { NodeFileReader } from "./adapters/state/node-file-reader";
import type { CliIO, Command, CommandContext } from "./cli/command";
import { commands, findCommand } from "./cli/commands";
import type { DeliveryPorts } from "./contexts/delivery";
import type { RepoModelPorts, RoutingPorts } from "./contexts/intelligence";
import type { SafetyPorts } from "./contexts/orchestration";
import type { AcceptancePorts } from "./contexts/planning";
import type { EnvPorts } from "./contexts/platform";
import {
  type BenchFactory,
  candidateVerifier,
  type QualityPorts,
  type VerifierPorts,
} from "./contexts/quality";
import { installShutdown } from "./shutdown";

const consoleIO: CliIO = {
  out: (text) => process.stdout.write(`${text}\n`),
  err: (text) => process.stderr.write(`${text}\n`),
};

const fileReader = new NodeFileReader();
const files = () => fileReader;
const repoDocs = once(() => new GitRepoDocs(new BunProcessRunner(), fileReader));
const stdio = once(processStdio);

/** Adapters for the repository world model (ADR-0016): the working tree via git, the cache in the state dir. */
export function buildRepoModelPorts(
  env: Readonly<Record<string, string | undefined>>,
): RepoModelPorts {
  return {
    source: new GitRepoSource(new BunProcessRunner()),
    store: new JsonModelStore(join(resolvePaths(env).stateDir, "repo-model")),
    now: () => new Date().toISOString(),
    history: new GitHistorySource(
      new BunProcessRunner(),
      join(resolvePaths(env).stateDir, "repo-model"),
    ),
  };
}

/** The routing log lives with the bash cost files in ~/.shipwright (ADR-0014). */
export function buildRoutingPorts(env: Readonly<Record<string, string | undefined>>): RoutingPorts {
  const legacyDir = join(resolvePaths(env).home, ".shipwright");
  return {
    log: new JsonlRoutingLog(join(legacyDir, "routing", "decisions.jsonl")),
    now: () => Date.now(),
  };
}

/** Acceptance-test ports (ADR-0015). Tests run through test-gate-exec.sh, without credentials. */
function acceptance(root: string = process.cwd()): AcceptancePorts {
  const runner = new BunProcessRunner({ reapGroup: true });
  const gate = join(import.meta.dir, "..", "scripts", "lib", "test-gate-exec.sh");
  return {
    ws: new GitAcceptanceWorkspace(runner, root),
    exec: new TestGateExecutor(runner, gate, root),
    artifacts: new NodeArtifactStore(),
  };
}

/** Environment recipes and their cache (ADR-0020); setup commands run through env-exec.sh. */
export function buildEnvPorts(env: Readonly<Record<string, string | undefined>>): EnvPorts {
  const { stateDir } = resolvePaths(env);
  const runner = new BunProcessRunner({ reapGroup: true });
  const script = join(import.meta.dir, "..", "scripts", "lib", "env-exec.sh");
  return {
    source: new GitEnvSource(new BunProcessRunner()),
    cache: new FsEnvCache(runner, join(stateDir, "env-cache"), { platform: process.platform }),
    exec: new JailedEnvExecutor(runner, script, env),
    scratch: new GitScratch(new BunProcessRunner(), join(stateDir, "env-scratch")),
    agent: once(() => new AgentSdkRunner(agentEnv(env))),
    digest: (text) => createHash("sha256").update(text).digest("hex"),
    platform: { os: process.platform, arch: process.arch },
    sleep: (ms) => Bun.sleep(ms),
    now: () => Date.now(),
  };
}

/** Adapters for the safety commands (ADR-0007). */
export function buildSafetyPorts(
  env: Readonly<Record<string, string | undefined>>,
): SafetyPorts & { readonly runner: BunProcessRunner } {
  // Files shared with the bash daemon live in ~/.shipwright, which bash uses even when
  // SHIPWRIGHT_STATE_DIR is set (spec §9); read them where bash writes them.
  const legacyDir = join(resolvePaths(env).home, ".shipwright");
  const runner = new BunProcessRunner();
  return {
    runner,
    now: () => Date.now(),
    runs: new GhRunHistory(runner),
    pauseFlag: new FilePauseFlag(join(legacyDir, "daemon-pause.flag")),
    pauseLabel: new GhPauseLabel(runner),
    github: new GhGithubWriter(runner),
    costs: new JsonCostLedger(legacyDir),
    pulls: new GhPullRequests(runner),
    issues: new GhOpenIssues(runner),
  };
}

/** Read-only adapters for the scorecard. */
export function buildQualityPorts(env: Readonly<Record<string, string | undefined>>): QualityPorts {
  const legacyDir = join(resolvePaths(env).home, ".shipwright");
  const runner = new BunProcessRunner();
  return {
    now: () => Date.now(),
    pulls: new GhClosedPulls(runner),
    spend: new LedgerSpend(new JsonCostLedger(legacyDir)),
  };
}

/** Adapters for the merge verifier: read-only git and GitHub, the model file, the critic agent. */
export function buildVerifierPorts(
  env: Readonly<Record<string, string | undefined>>,
  cwd: string,
): VerifierPorts {
  const runner = new BunProcessRunner();
  const dir = join(resolvePaths(env).stateDir, "verifier");
  return {
    now: () => Date.now(),
    pulls: new GhClosedPulls(runner),
    files: new GhPullFiles(runner),
    change: new GitLocalChange(runner, cwd),
    store: new JsonVerifierStore(join(dir, "model.json")),
    agent: new AgentSdkRunner(agentEnv(env)),
    survival: new GitSurvivalSource(runner, cwd),
    scores: new JsonlScoreLog(join(dir, "scores.jsonl")),
  };
}

/**
 * Adapters for the build tournament. Worktrees go under the state directory, one folder per run, so
 * attempts never appear in the repository's own status or diffs.
 */
export function buildDeliveryPorts(
  env: Readonly<Record<string, string | undefined>>,
  cwd: string,
  verifier: () => VerifierPorts = () => buildVerifierPorts(env, cwd),
): DeliveryPorts {
  const runner = new BunProcessRunner();
  const run = `${new Date().toISOString().replace(/[:.]/g, "-")}-${process.pid}`;
  const root = join(resolvePaths(env).stateDir, "tournaments", run);
  return {
    agent: new AgentSdkRunner(agentEnv(env)),
    workspaces: new GitWorkspaces(runner, cwd, root),
    commands: new BashCommandRunner(runner, testEnv(env)),
    // The merge verifier is one selection signal and decides adaptive early stop (ADR-0018).
    verifier:
      env.SHIPWRIGHT_VERIFIER?.trim().toLowerCase() === "off"
        ? undefined
        : candidateVerifier(verifier()),
    random: Math.random,
  };
}

function once<T>(make: () => T): () => T {
  let value: T | undefined;
  return () => {
    value ??= make();
    return value;
  };
}

function renderHelp(registry: readonly Command[]): string {
  const rows = registry.map((c) => {
    const label = c.aliases.length > 0 ? `${c.name} (${c.aliases.join(", ")})` : c.name;
    return `  ${label.padEnd(20)} ${c.summary}`;
  });
  return ["USAGE", "  shipwright <command> [args]", "", "COMMANDS", ...rows].join("\n");
}

/** Runs one command; an exception becomes exit 1 with its message on stderr. */
async function runCommand(
  command: Command,
  args: readonly string[],
  ctx: CommandContext,
): Promise<number> {
  try {
    return await command.run(args, ctx);
  } catch (error) {
    ctx.io.err(`✗ ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}

/** Top-level help and version, only when they are the whole request; anything more is a command. */
function topLevel(
  argv: readonly string[],
  io: CliIO,
  registry: readonly Command[],
): number | undefined {
  const [name] = argv;
  const alone = argv.length <= 1;
  if (name === undefined || (alone && (name === "--help" || name === "-h"))) {
    io.out(renderHelp(registry));
    return 0;
  }
  if (alone && (name === "--version" || name === "-v")) {
    io.out(pkg.version);
    return 0;
  }
  return undefined;
}

/** Ports every command run gets that main() does not take as parameters; each builds on first use. */
function sharedPorts(env: Readonly<Record<string, string | undefined>>) {
  return {
    files,
    repoDocs,
    stdio,
    acceptance,
    routing: once(() => buildRoutingPorts(env)),
    steward: once(() => buildStewardPorts(process.cwd())),
    repoModel: once(() => buildRepoModelPorts(env)),
    environments: once(() => buildEnvPorts(env)),
    proof: (outDir: string | null) =>
      buildProofPorts(env, process.cwd(), join(import.meta.dir, ".."), outDir),
  };
}

/** Composition root. Adapters are constructed here as commands start needing them. */
export async function main(
  argv: readonly string[],
  io: CliIO = consoleIO,
  registry: readonly Command[] = commands,
  safety: () => SafetyPorts = once(() => {
    const ports = buildSafetyPorts(process.env);
    installShutdown(ports.runner, process);
    return ports;
  }),
  env: Readonly<Record<string, string | undefined>> = process.env,
  quality: () => QualityPorts = once(() => buildQualityPorts(env)),
  bench: () => BenchFactory = once(() => buildBenchFactory(env, join(import.meta.dir, ".."))),
  verifier: () => VerifierPorts = once(() => buildVerifierPorts(env, process.cwd())),
  delivery: () => DeliveryPorts = once(() => buildDeliveryPorts(env, process.cwd())),
): Promise<number> {
  const [name, ...args] = argv;
  const early = topLevel(argv, io, registry);
  if (early !== undefined || name === undefined) return early ?? 0;
  const command = findCommand(name, registry);
  if (!command) {
    // 2 = usage error (bash sw exited 1); 1 = command failed.
    io.err(`✗ Unknown command: ${name}`);
    return 2;
  }
  return runCommand(command, args, {
    io,
    version: pkg.version,
    safety,
    env,
    quality,
    bench,
    verifier,
    delivery,
    ...sharedPorts(env),
  });
}
