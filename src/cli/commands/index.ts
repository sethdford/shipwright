import type { Command } from "../command";
import { benchCommand } from "./bench";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { evalCommand } from "./eval";
import { failureCommand } from "./failure";
import { gatesCommand } from "./gates";
import { helloCommand } from "./hello";
import { intakeCommand } from "./intake";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";
import { scorecardCommand } from "./scorecard";

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
  scorecardCommand,
  evalCommand,
  benchCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
