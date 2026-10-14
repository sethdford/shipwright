import type { Command } from "../command";
import { breakerCommand } from "./breaker";
import { helloCommand } from "./hello";

export const commands: readonly Command[] = [helloCommand, breakerCommand];

export function findCommand(
  name: string,
  registry: readonly Command[] = commands,
): Command | undefined {
  return registry.find((c) => c.name === name || c.aliases.includes(name));
}
