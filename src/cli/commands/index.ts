import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { failureCommand } from "./failure";
import { gatesCommand } from "./gates";
import { governanceCommand } from "./governance";
import { helloCommand } from "./hello";
import { intakeCommand } from "./intake";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";
import { routeCommand } from "./route";

export const commands: readonly Command[] = [
  helloCommand,
  breakerCommand,
  pauseCommand,
  resumeCommand,
  pausedCommand,
  budgetCommand,
  intakeCommand,
  gatesCommand,
  failureCommand,
  governanceCommand,
  routeCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
