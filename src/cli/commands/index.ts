import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { helloCommand } from "./hello";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
  budgetCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
