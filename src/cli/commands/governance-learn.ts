import {
  applyReflection,
  DEFAULT_MINE,
  decidePromotion,
  type Lesson,
  loadGuidance,
  mineDrafts,
  needsReflection,
  parseLesson,
  parseReflection,
  parseTrialVerdict,
  type RunLog,
  reflectionPrompt,
  sectionText,
} from "../../contexts/governance";
import type { CommandContext } from "../command";
import { adapterFailure } from "../shared";
import type { GovFlags } from "./governance-flags";

/** Subcommands of the self-improvement loop (ADR-0010 amendment): mine, reflect, apply-reflection, promote. */
export const LEARN_ALLOWED: Readonly<Record<string, readonly string[]>> = {
  mine: ["--manifest", "--min", "--limit", "--root", "--ref", "--json"],
  reflect: ["--draft"],
  "apply-reflection": ["--draft", "--reply"],
  promote: ["--draft", "--verdict", "--trial", "--json"],
};

type Fail = (message: string) => number;

async function read(ctx: CommandContext, path: string): Promise<string | number> {
  const r = await ctx.files().readText(path);
  return r.ok ? r.value : adapterFailure(ctx.io, `read ${path}`, r.error);
}

/** `source<TAB or spaces>log path` per line; blank lines and # comments are skipped. */
export function parseManifest(text: string): { source: string; path: string }[] | string {
  const out: { source: string; path: string }[] = [];
  for (const [i, raw] of text.split("\n").entries()) {
    const line = raw.trim();
    if (line.length === 0 || line.startsWith("#")) continue;
    const m = /^(\S+)\s+(\S.*)$/.exec(line);
    if (!m) return `manifest line ${i + 1}: expected "<source> <log path>"`;
    out.push({ source: m[1] ?? "", path: (m[2] ?? "").trim() });
  }
  return out;
}

function count(value: string | undefined, fallback: number): number | null {
  if (value === undefined) return fallback;
  return /^[1-9]\d{0,2}$/.test(value) ? Number(value) : null;
}

async function mine(ctx: CommandContext, flags: GovFlags, fail: Fail): Promise<number> {
  const manifestPath = flags.values["--manifest"];
  const minCount = count(flags.values["--min"], DEFAULT_MINE.minCount);
  const limit = count(flags.values["--limit"], DEFAULT_MINE.limit);
  if (manifestPath === undefined) return fail("--manifest is required");
  if (minCount === null || limit === null) return fail("--min and --limit must be 1 to 999");
  const manifestText = await read(ctx, manifestPath);
  if (typeof manifestText === "number") return manifestText;
  const entries = parseManifest(manifestText);
  if (typeof entries === "string") return fail(entries);
  const logs: RunLog[] = [];
  for (const e of entries) {
    const log = await read(ctx, e.path);
    if (typeof log === "number") return log;
    logs.push({ source: e.source, log });
  }
  const ref = flags.values["--ref"];
  const source = { root: flags.values["--root"] ?? ".", ...(ref === undefined ? {} : { ref }) };
  const g = await loadGuidance(ctx.repoDocs(), source);
  if (!g.ok) return adapterFailure(ctx.io, "governance documents", g.error);
  const drafts = mineDrafts(g.value.lessons, logs, { minCount, limit });
  const rows = drafts.map((d) => ({
    ...d.draft,
    count: d.candidate.count,
    failureClass: d.candidate.failureClass,
  }));
  if (flags.switches.has("--json")) ctx.io.out(JSON.stringify({ runs: logs.length, drafts: rows }));
  else
    for (const r of rows)
      ctx.io.out(`==> ${r.path} (${r.count}x ${r.failureClass}) <==\n${r.markdown}`);
  return 0;
}

async function draftOf(ctx: CommandContext, flags: GovFlags, fail: Fail): Promise<Lesson | number> {
  const path = flags.values["--draft"];
  if (path === undefined) return fail("--draft is required");
  const raw = await read(ctx, path);
  if (typeof raw === "number") return raw;
  const lesson = parseLesson(".shipwright/lessons/draft.md", raw);
  if (!/^L-\d{4,}$/.test(lesson.id)) return fail(`${path} is not a lesson (no L-NNNN id)`);
  return lesson;
}

function evidenceOf(l: Lesson, raw: string): string {
  return sectionText(raw, "Evidence") ?? l.text;
}

async function reflect(ctx: CommandContext, flags: GovFlags, fail: Fail): Promise<number> {
  const l = await draftOf(ctx, flags, fail);
  if (typeof l === "number") return l;
  const raw = await read(ctx, flags.values["--draft"] ?? "");
  if (typeof raw === "number") return raw;
  if (!needsReflection(l)) {
    ctx.io.err(`${l.id} already has a rule and a hypothesis`);
    return 3;
  }
  ctx.io.out(reflectionPrompt(l, evidenceOf(l, raw).replace(/^```text\n|\n```$/g, "")));
  return 0;
}

async function applyReply(ctx: CommandContext, flags: GovFlags, fail: Fail): Promise<number> {
  const l = await draftOf(ctx, flags, fail);
  if (typeof l === "number") return l;
  const replyPath = flags.values["--reply"];
  if (replyPath === undefined) return fail("--reply is required");
  const [raw, reply] = [await read(ctx, flags.values["--draft"] ?? ""), await read(ctx, replyPath)];
  if (typeof raw === "number") return raw;
  if (typeof reply === "number") return reply;
  const r = parseReflection(reply);
  if (!r.ok) {
    ctx.io.err(`✗ reflection rejected: ${r.reason}`);
    return 1;
  }
  const evidence = evidenceOf(l, raw).replace(/^```text\n|\n```$/g, "");
  ctx.io.out(applyReflection(l, evidence, r.value));
  return 0;
}

async function promote(ctx: CommandContext, flags: GovFlags, fail: Fail): Promise<number> {
  const l = await draftOf(ctx, flags, fail);
  if (typeof l === "number") return l;
  const verdictPath = flags.values["--verdict"];
  if (verdictPath === undefined) return fail("--verdict is required");
  if (l.status !== "proposed")
    return fail(`${l.id} is ${l.status}; only a proposed lesson can be promoted`);
  if (needsReflection(l)) return fail(`${l.id} still has placeholder text; reflect on it first`);
  const [raw, vText] = [
    await read(ctx, flags.values["--draft"] ?? ""),
    await read(ctx, verdictPath),
  ];
  if (typeof raw === "number") return raw;
  if (typeof vText === "number") return vText;
  let json: unknown;
  try {
    json = JSON.parse(vText);
  } catch {
    return fail(`${verdictPath} is not JSON`);
  }
  const v = parseTrialVerdict(json);
  if (!v.ok) return fail(v.reason);
  const p = decidePromotion(
    l,
    sectionText(raw, "Evidence"),
    v.value,
    flags.values["--trial"] ?? verdictPath,
  );
  if (flags.switches.has("--json")) ctx.io.out(JSON.stringify(p));
  else ctx.io.out(p.markdown);
  return p.outcome === "promote" ? 0 : 3;
}

export const LEARN_RUNNERS: Readonly<
  Record<string, (ctx: CommandContext, flags: GovFlags, fail: Fail) => Promise<number>>
> = { mine, reflect, "apply-reflection": applyReply, promote };
