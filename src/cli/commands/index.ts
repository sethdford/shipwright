import type { Command } from "../command";
import { acceptanceCommand } from "./acceptance";
import { benchCommand } from "./bench";
import { breakerCommand } from "./breaker";
import { budgetCommand } from "./budget";
import { envCommand } from "./env";
import { evalCommand } from "./eval";
import { failureCommand } from "./failure";
import { gatesCommand } from "./gates";
import { governanceCommand } from "./governance";
import { helloCommand } from "./hello";
import { intakeCommand } from "./intake";
import { pauseCommand, pausedCommand, resumeCommand } from "./pause";
import { proofCommand } from "./proof";
import { repomodelCommand } from "./repomodel";
import { routeCommand } from "./route";
import { scorecardCommand } from "./scorecard";
import { stewardCommand } from "./steward";
import { tournamentCommand } from "./tournament";
import { verifyCommand } from "./verify";

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
  verifyCommand,
  proofCommand,
  governanceCommand,
  tournamentCommand,
  acceptanceCommand,
  repomodelCommand,
  routeCommand,
  benchCommand,
  stewardCommand,
  envCommand,
];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
