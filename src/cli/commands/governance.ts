import {
  briefInputs,
  buildChecklist,
  type DocSource,
  type Guidance,
  loadGuidance,
  proposeLesson,
  renderBrief,
  renderChecklist,
} from "../../contexts/governance";
import { classifyAndDecide } from "../../contexts/learning";
import type { AgentFailureKind } from "../../shared/kernel/ports";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { envOff, type GovFlags, parseGovFlags, pathLines, SWITCH_FLAGS } from "./governance-flags";
import { LEARN_ALLOWED, LEARN_RUNNERS } from "./governance-learn";

const SUBCOMMANDS = [
  "brief",
  "check",
  "list",
  "propose",
  "mine",
  "reflect",
  "apply-reflection",
  "promote",
] as const;

const usage = `USAGE
  shipwright governance brief   [--root DIR] [--ref REF] [--issue FILE] [--paths FILE]
                                [--failure-class C] [--fingerprint F] [--no-lessons] [--no-governance] [--json]
  shipwright governance check   --changed FILE [--root DIR] [--ref REF] [--json]
  shipwright governance list    [--root DIR] [--ref REF] [--json]
  shipwright governance propose --log FILE --source TEXT [--kind KIND] [--root DIR] [--ref REF] [--json]
  shipwright governance mine    --manifest FILE [--min N] [--limit N] [--root DIR] [--ref REF] [--json]
  shipwright governance reflect --draft FILE
  shipwright governance apply-reflection --draft FILE --reply FILE
  shipwright governance promote --draft FILE --verdict FILE [--trial TEXT] [--json]

DESCRIPTION
  Reads the repository's ADRs (docs/adr, docs/decisions, adr), policies (docs/policies, .shipwright/policies),
  standards (docs/standards, .shipwright/standards) and lessons (.shipwright/lessons). Tracked files only; with
  --ref, the files committed at that ref, so an agent's edits cannot change what it is told (ADR-0010).

  brief    The governance brief for an agent prompt: documents in force, then the active lessons that fit the
           issue (--issue), the planned or changed paths (--paths, one per line) and an earlier failure. Prints
           nothing when there is nothing to say. --json also lists which documents and lessons went in.
  check    The checklist a reviewer checks a change against: documents whose applies_to matches a changed path
           (--changed, one per line), then repository-wide policies and standards.
  list     Every document and lesson with its id, kind and status.
  propose  Drafts a lesson (status: proposed) from a failed run's log, or names the lesson that already covers
           that failure. Writes nothing: the draft goes to stdout for a maintainer to finish and merge.

SELF-IMPROVEMENT LOOP (ADR-0010)
  mine     Classifies failed-run logs (--manifest: "<source> <log path>" per line) and drafts a proposed lesson for
           each failure that recurs at least --min times (default 2) in a learnable class and that no lesson covers.
  reflect  Prints the prompt that asks an agent to write a draft's rule, hypothesis, paths and keywords.
  apply-reflection  Validates the agent's JSON reply and prints the draft with it written in (still proposed).
  promote  Reads a paired-ratchet verdict (shipwright eval ratchet --json) for a trialled draft and prints it as
           active (accepted on at least 12 cases, exit 0) or retired (exit 3), with an Evaluation section.
  Nothing here writes a lesson file or opens a pull request. A person merges every status change.

ABLATION AND TRIAL ARMS (for paired eval runs)
  SHIPWRIGHT_LESSONS=off or --no-lessons leaves lessons out; SHIPWRIGHT_GOVERNANCE=off or --no-governance leaves
  the documents out. SHIPWRIGHT_LESSONS_TRIAL=L-0007,L-0008 or --trial treats those proposed lessons as active.

EXIT CODES
  0  done      1  could not read (fails closed)      2  usage error
  3  propose: already covered; reflect: nothing to do; promote: retired`;

const ALLOWED: Readonly<Record<string, readonly string[]>> = {
  ...LEARN_ALLOWED,
  brief: [
    "--root",
    "--ref",
    "--issue",
    "--paths",
    "--failure-class",
    "--fingerprint",
    "--trial",
    ...SWITCH_FLAGS,
  ],
  check: ["--root", "--ref", "--changed", "--json"],
  list: ["--root", "--ref", "--json"],
  propose: ["--root", "--ref", "--log", "--source", "--kind", "--json"],
};

function sourceOf(flags: GovFlags): DocSource {
  const ref = flags.values["--ref"];
  return { root: flags.values["--root"] ?? ".", ...(ref === undefined ? {} : { ref }) };
}

async function load(ctx: CommandContext, flags: GovFlags): Promise<Guidance | number> {
  const g = await loadGuidance(ctx.repoDocs(), sourceOf(flags));
  return g.ok ? g.value : adapterFailure(ctx.io, "governance documents", g.error);
}

async function readOptional(
  ctx: CommandContext,
  path: string | undefined,
): Promise<string | number> {
  if (path === undefined) return "";
  const r = await ctx.files().readText(path);
  if (r.ok) return r.value;
  return adapterFailure(ctx.io, `read ${path}`, r.error);
}

async function brief(ctx: CommandContext, flags: GovFlags): Promise<number> {
  const issue = await readOptional(ctx, flags.values["--issue"]);
  if (typeof issue === "number") return issue;
  const pathsText = await readOptional(ctx, flags.values["--paths"]);
  if (typeof pathsText === "number") return pathsText;
  const g = await load(ctx, flags);
  if (typeof g === "number") return g;
  const paths = pathLines(pathsText);
  const failureClass = flags.values["--failure-class"];
  const fingerprint = flags.values["--fingerprint"];
  const trial = (flags.values["--trial"] ?? ctx.env.SHIPWRIGHT_LESSONS_TRIAL ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
  const inputs = briefInputs(g, {
    trial,
    lessons: !flags.switches.has("--no-lessons") && !envOff(ctx.env.SHIPWRIGHT_LESSONS),
    governance: !flags.switches.has("--no-governance") && !envOff(ctx.env.SHIPWRIGHT_GOVERNANCE),
    context: {
      text: issue,
      paths,
      ...(failureClass === undefined ? {} : { failureClass }),
      ...(fingerprint === undefined ? {} : { fingerprint }),
    },
  });
  const text = renderBrief(inputs.docs, inputs.lessons, paths);
  if (!flags.switches.has("--json")) {
    if (text.length > 0) ctx.io.out(text);
    return 0;
  }
  const used = renderedDocIds(inputs.docs, text);
  const lessons = inputs.lessons.map((s) => ({ id: s.lesson.id, score: s.score, why: s.why }));
  ctx.io.out(JSON.stringify({ brief: text, docs: used, lessons }));
  return 0;
}

function renderedDocIds(docs: Guidance["docs"], text: string): readonly string[] {
  // In the order the brief shows them; a document cut off by the size limit is not reported as used.
  return docs
    .map((d) => ({ id: d.id, at: text.indexOf(`### ${d.id}: `) }))
    .filter((d) => d.at !== -1)
    .sort((a, b) => a.at - b.at)
    .map((d) => d.id);
}

async function check(ctx: CommandContext, flags: GovFlags): Promise<number> {
  const changedPath = flags.values["--changed"];
  if (changedPath === undefined) return usageError(ctx.io, usage, "--changed is required");
  const changed = await readOptional(ctx, changedPath);
  if (typeof changed === "number") return changed;
  const g = await load(ctx, flags);
  if (typeof g === "number") return g;
  const items = buildChecklist(g.docs, pathLines(changed));
  if (flags.switches.has("--json")) ctx.io.out(JSON.stringify({ items }));
  else if (items.length > 0) ctx.io.out(renderChecklist(items));
  return 0;
}

async function list(ctx: CommandContext, flags: GovFlags): Promise<number> {
  const g = await load(ctx, flags);
  if (typeof g === "number") return g;
  const rows = [...g.docs, ...g.lessons].map((d) => ({
    id: d.id,
    kind: d.kind,
    status: d.status,
    title: d.title,
    path: d.path,
  }));
  if (flags.switches.has("--json")) ctx.io.out(JSON.stringify({ documents: rows }));
  else
    for (const r of rows)
      ctx.io.out(`${r.id.padEnd(12)} ${r.kind.padEnd(9)} ${r.status.padEnd(10)} ${r.title}`);
  return 0;
}

async function propose(ctx: CommandContext, flags: GovFlags): Promise<number> {
  const logPath = flags.values["--log"];
  const source = flags.values["--source"];
  if (logPath === undefined || source === undefined) {
    return usageError(ctx.io, usage, "--log and --source are required");
  }
  const log = await readOptional(ctx, logPath);
  if (typeof log === "number") return log;
  const g = await load(ctx, flags);
  if (typeof g === "number") return g;
  const kind = flags.values["--kind"] as AgentFailureKind | undefined;
  const cls = classifyAndDecide({
    text: log,
    attempts: [],
    ...(kind === undefined ? {} : { kind }),
  });
  const p = proposeLesson(g.lessons, {
    failureClass: cls.class,
    fingerprint: cls.fingerprint,
    source,
    log,
  });
  if (flags.switches.has("--json")) ctx.io.out(JSON.stringify(p));
  else if (p.kind === "draft") ctx.io.out(p.markdown);
  else ctx.io.err(`already covered by ${p.id} (${p.path})`);
  return p.kind === "draft" ? 0 : 3;
}

const RUNNERS: Readonly<Record<string, (ctx: CommandContext, flags: GovFlags) => Promise<number>>> =
  {
    brief,
    check,
    list,
    propose,
  };

export const governanceCommand: Command = {
  name: "governance",
  aliases: ["gov"],
  summary:
    "ADRs, policies, standards and lessons for agents: brief, review checklist, lesson drafts",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, [...SUBCOMMANDS])) {
      ctx.io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    if (sub === undefined) return usageError(ctx.io, usage, "a subcommand is required");
    if (!(SUBCOMMANDS as readonly string[]).includes(sub)) {
      return usageError(ctx.io, usage, `unknown subcommand: ${sub}`);
    }
    const flags = parseGovFlags(rest, ALLOWED[sub] ?? []);
    if (typeof flags === "string") return usageError(ctx.io, usage, flags);
    const learn = LEARN_RUNNERS[sub];
    if (learn) return learn(ctx, flags, (m) => usageError(ctx.io, usage, m));
    const run = RUNNERS[sub];
    return run ? run(ctx, flags) : usageError(ctx.io, usage, `unknown subcommand: ${sub}`);
  },
};
