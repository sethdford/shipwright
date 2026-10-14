import { checkIntake, describeIntake } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";

const usage = `USAGE
  shipwright intake check [--title TITLE] [--label LABEL]

DESCRIPTION
  Issue intake caps (spec §6.2, ADR-0007), consulted before automation files an issue.
  A gate: exit 0 only when filing is allowed. Exits 1 when 25 or more auto-patrol issues are
  open, when an open issue has the same title fingerprint (case, digits and punctuation
  ignored), or when issues cannot be listed (including a possibly truncated list). Exits 2 on
  bad arguments. Issue titles are never printed.

OPTIONS
  --title TITLE   Title of the issue about to be filed. A title with no letters or digits is
                  never treated as a duplicate.
  --label LABEL   Label marking auto-filed issues (default auto-patrol; 1-50 printable chars)

EXAMPLES
  shipwright intake check --title "Security: lodash 4.17.20 in package-lock"`;

interface IntakeArgs {
  readonly title: string | null;
  readonly label?: string;
}

// biome-ignore lint/suspicious/noControlCharactersInRegex: rejecting control characters
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

/** Parsed `--title` and `--label` options, or undefined when the arguments are malformed. */
function parseArgs(rest: readonly string[]): IntakeArgs | undefined {
  let title: string | null = null;
  let label: string | undefined;
  for (let i = 0; i < rest.length; i += 2) {
    const value = rest[i + 1];
    if (value === undefined) return undefined;
    if (rest[i] === "--title" && title === null && value.trim()) title = value;
    else if (rest[i] === "--label" && label === undefined && value.length <= 50) {
      if (!value.trim() || CONTROL.test(value)) return undefined;
      label = value;
    } else return undefined;
  }
  return { title, label };
}

export const intakeCommand: Command = {
  name: "intake",
  aliases: [],
  summary: "Issue intake caps: may automation file this issue?",
  usage,
  async run(args, { io, safety }) {
    const [sub, ...rest] = args;
    if (isHelpRequest(args, ["check"])) {
      io.out(usage);
      return 0;
    }
    const parsed = parseArgs(rest);
    if (sub !== "check" || parsed === undefined) {
      return usageError(
        io,
        usage,
        "Expected: check [--title TITLE] [--label LABEL] (values must be valid and non-empty)",
      );
    }
    const r = await checkIntake(safety(), parsed.title, parsed.label);
    if (!r.ok) return adapterFailure(io, "intake", r.error);
    io.out(`${r.value.allowed ? "✓" : "✗"} intake: ${describeIntake(r.value)}`);
    return r.value.allowed ? 0 : 1;
  },
};
