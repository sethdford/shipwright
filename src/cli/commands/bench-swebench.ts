import {
  gradeRows,
  latestRows,
  mineHoldout,
  parseProblems,
  predictionLine,
  resolvedIds,
  sweTasks,
  toEvalResults,
} from "../../contexts/quality";
import type { CommandContext } from "../command";
import type { BenchFlags } from "./bench-flags";
import { BenchError, loadRows, portsFor, readJson, readJsonLines } from "./bench-load";

const HARNESS =
  "python -m swebench.harness.run_evaluation --dataset_name princeton-nlp/SWE-bench_Verified";

/** One arm's graded runs in the `shipwright eval` format, for `eval ratchet`. */
export async function benchExportEval(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const ports = portsFor(ctx, flags);
  const arm = flags.values.arm ?? "";
  const { results, unknownCost } = toEvalResults(await loadRows(ports), arm);
  if (results.runs.length === 0) throw new BenchError(`no graded runs for arm ${arm}`);
  const w = await ports.store.write(`eval-${arm}.json`, JSON.stringify(results, null, 2));
  if (!w.ok) throw new BenchError(w.error.message);
  ctx.io.out(w.value);
  if (unknownCost > 0)
    ctx.io.err(`⚠ ${unknownCost} run(s) reported no spend; written as costUsd 0`);
  return 0;
}

/** predictions.jsonl for the official SWE-bench harness, from one arm's ungraded runs. */
export async function benchExportSwebench(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const ports = portsFor(ctx, flags);
  const arm = flags.values.arm ?? "";
  const pending = latestRows(await loadRows(ports)).filter(
    (r) => r.armId === arm && r.trial === flags.trial && r.resolved === null && r.status === "ok",
  );
  const lines: string[] = [];
  for (const row of pending) {
    const patch = await ports.store.readPatch(arm, row.taskId, row.trial);
    if (!patch.ok) throw new BenchError(patch.error.message);
    lines.push(predictionLine(row.taskId, arm, patch.value ?? ""));
  }
  if (lines.length === 0)
    throw new BenchError(`no ungraded SWE-bench runs for ${arm} trial ${flags.trial}`);
  const name = `predictions-${arm}-t${flags.trial}.jsonl`;
  const w = await ports.store.write(name, `${lines.join("\n")}\n`);
  if (!w.ok) throw new BenchError(w.error.message);
  ctx.io.out(w.value);
  ctx.io.err(
    `grade with: ${HARNESS} --predictions_path ${w.value} --run_id ${arm}-t${flags.trial}`,
  );
  return 0;
}

/** Appends graded rows from the harness report (`<model>.<run_id>.json`). */
export async function benchImportSwebench(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const ports = portsFor(ctx, flags);
  const ids = resolvedIds(await readJson(ctx, flags.values.report ?? ""));
  if (!ids.ok) throw new BenchError(ids.reason);
  const rows = latestRows(await loadRows(ports));
  const arm = flags.values.arm ?? "";
  const submitted = new Set(
    rows.filter((r) => r.armId === arm && r.status === "ok").map((r) => r.taskId),
  );
  const graded = gradeRows(
    rows,
    arm,
    flags.trial,
    ids.value,
    submitted,
    new Date(ports.now()).toISOString(),
  );
  for (const row of graded) {
    const a = await ports.store.append(row);
    if (!a.ok) throw new BenchError(a.error.message);
  }
  const won = graded.filter((r) => r.resolved).length;
  ctx.io.out(`graded ${graded.length} run(s) of ${arm}: ${won} resolved`);
  return 0;
}

/** Prints a task manifest drawn from a SWE-bench Verified JSONL export. */
export async function benchSampleSwebench(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const lines = await readJsonLines(ctx, flags.values.from ?? "");
  const seed = Number(flags.values.seed ?? "1");
  const tasks = sweTasks(lines, Number(flags.values.n), seed);
  if (!tasks.ok) throw new BenchError(tasks.reason);
  const name = flags.values.name ?? `swe-bench-verified-n${tasks.value.length}-seed${seed}`;
  ctx.io.out(JSON.stringify({ name, tasks: tasks.value }, null, 2));
  return 0;
}

/** Prints a holdout manifest mined from a repo's merged PRs or commits; rejections go to stderr. */
export async function benchMineHoldout(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const repo = flags.values.repo ?? "";
  const source = ctx.bench().holdout(repo);
  const problems = flags.values.problems
    ? parseProblems(await readJson(ctx, flags.values.problems))
    : ({ ok: true, value: {} } as const);
  if (!problems.ok) throw new BenchError(`problems: ${problems.reason}`);
  const r = await mineHoldout(
    {
      repo: flags.values["clone-url"] ?? `https://github.com/${repo}`,
      sinceMs: Date.parse(flags.values.since ?? ""),
      maxPulls: Number(flags.values.max ?? "200"),
      setup: flags.setup,
      from: flags.values.source === "commits" ? "commits" : "pulls",
      problems: problems.value,
    },
    source,
  );
  if (!r.ok) throw new BenchError(r.error.message);
  for (const x of r.value.rejected) ctx.io.err(`skip ${x.ref}: ${x.reason}`);
  const name = flags.values.name ?? `${repo.replace("/", "-")}-holdout`;
  ctx.io.out(JSON.stringify({ name, tasks: r.value.tasks }, null, 2));
  ctx.io.err(`${r.value.tasks.length} task(s), ${r.value.rejected.length} change(s) skipped`);
  return 0;
}
