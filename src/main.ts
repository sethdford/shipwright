import pkg from "../package.json";
import type { CliIO, Command } from "./cli/command";
import { commands, findCommand } from "./cli/commands";

const consoleIO: CliIO = {
  out: (text) => process.stdout.write(`${text}\n`),
  err: (text) => process.stderr.write(`${text}\n`),
};

// TODO(signals): install signal handlers that call runner.killAll when the first command constructs a BunProcessRunner.

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
): Promise<number> {
  const [name, ...args] = argv;
  if (name === undefined || name === "--help" || name === "-h") {
    io.out(renderHelp(registry));
    return 0;
  }
  if (name === "--version" || name === "-v") {
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
    return await command.run(args, { io, version: pkg.version });
  } catch (error) {
    io.err(`✗ ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}
