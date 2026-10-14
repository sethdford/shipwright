import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { gatesCommand } from "./gates";
import { helloCommand } from "./hello";
import { intakeCommand } from "./intake";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
  budgetCommand,
  intakeCommand,
  gatesCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
