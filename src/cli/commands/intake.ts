import { checkIntake, describeIntake } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const usage = `USAGE
  shipwright intake check [--title TITLE]

DESCRIPTION
  Issue intake caps (spec §6.2, ADR-0007), consulted before automation files an issue.
  A gate: exit 0 only when filing is allowed. Exits 1 when 25 or more auto-patrol issues are
  open, when an open issue has the same title fingerprint (case, digits and punctuation
  ignored), or when issues cannot be listed (including a possibly truncated list). Exits 2 on
  bad arguments. Issue titles are never printed.

OPTIONS
  --title TITLE   Title of the issue about to be filed

EXAMPLES
  shipwright intake check --title "Security: lodash 4.17.20 in package-lock"`;

/** The --title value, null when absent, or undefined when the arguments are malformed. */
function parseTitle(rest: readonly string[]): string | null | undefined {
  if (rest.length === 0) return null;
  if (rest.length !== 2 || rest[0] !== "--title") return undefined;
  return rest[1]?.trim() ? rest[1] : undefined;
}

export const intakeCommand: Command = {
  name: "intake",
  aliases: [],
  summary: "Issue intake caps: may automation file this issue?",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelp(sub)) {
      io.out(usage);
      return 0;
    }
    const title = parseTitle(rest);
    if (sub !== "check" || title === undefined) {
      return usageError(io, usage, "Expected: check [--title TITLE] (TITLE must not be empty)");
    }
    const r = await checkIntake(safety(), title);
    if (!r.ok) return adapterFailure(io, "intake", r.error);
    io.out(`${r.value.allowed ? "✓" : "✗"} intake: ${describeIntake(r.value)}`);
    return r.value.allowed ? 0 : 1;
  },
};
