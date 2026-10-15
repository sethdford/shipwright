import { join } from "node:path";
import pkg from "../package.json";
import { GhGithubWriter } from "./adapters/github/gh-github-writer";
import { GhOpenIssues } from "./adapters/github/gh-open-issues";
import { GhPauseLabel } from "./adapters/github/gh-pause-label";
import { GhPullRequests } from "./adapters/github/gh-pull-requests";
import { GhRunHistory } from "./adapters/github/gh-run-history";
import { resolvePaths } from "./adapters/paths";
import { BunProcessRunner } from "./adapters/process/bun-process-runner";
import { FilePauseFlag } from "./adapters/state/file-pause-flag";
import { JsonCostLedger } from "./adapters/state/json-cost-ledger";
import type { CliIO, Command } from "./cli/command";
import { commands, findCommand } from "./cli/commands";
import type { SafetyPorts } from "./contexts/orchestration";
import { installShutdown } from "./shutdown";

const consoleIO: CliIO = {
  out: (text) => process.stdout.write(`${text}\n`),
  err: (text) => process.stderr.write(`${text}\n`),
};

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
): Promise<number> {
  const [name, ...args] = argv;
  // Top-level help and version only when they are the whole request; anything more exits 2 below.
  const alone = argv.length <= 1;
  if (name === undefined || (alone && (name === "--help" || name === "-h"))) {
    io.out(renderHelp(registry));
    return 0;
  }
  if (alone && (name === "--version" || name === "-v")) {
    io.out(pkg.version);
    return 0;
  }
  const command = findCommand(name, registry);
  if (!command) {
    // 2 = usage error (bash sw exited 1); 1 = command failed.
    io.err(`✗ Unknown command: ${name}`);
    return 2;
  }
  try {
    return await command.run(args, { io, version: pkg.version, safety, env });
  } catch (error) {
    io.err(`✗ ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}
