import {
  buildBenchReport,
  estimateUsd,
  oracleOk,
  pendingRuns,
  planRuns,
  runBenchmark,
  validateTask,
} from "../../contexts/quality";
import type { CommandContext } from "../command";
import type { BenchFlags } from "./bench-flags";
import { BenchError, loadArms, loadManifest, loadRows, portsFor } from "./bench-load";
import { renderBenchHtml, renderBenchMarkdown } from "./bench-render";

/** Counts runs and estimated spend; touches nothing. */
export async function benchPlan(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const manifest = await loadManifest(ctx, flags);
  const { arms } = await loadArms(ctx, flags);
  const plan = planRuns(manifest.tasks, arms, flags.trials);
  const todo = flags.values.out ? pendingRuns(plan, await loadRows(portsFor(ctx, flags))) : plan;
  ctx.io.out(
    `${manifest.name}: ${manifest.tasks.length} task(s) × ${arms.length} arm(s) × ${flags.trials} trial(s) = ${plan.length} run(s)`,
  );
  for (const arm of arms) {
    const mine = todo.filter((p) => p.armId === arm.id);
    ctx.io.out(
      `  ${arm.id.padEnd(20)} ${String(mine.length).padStart(5)} run(s)  est. $${estimateUsd(mine, [arm]).toFixed(2)}`,
    );
  }
  ctx.io.out(`  to run: ${todo.length}, estimated $${estimateUsd(todo, arms).toFixed(2)}`);
  return 0;
}

/** Runs the benchmark under a hard budget; resumable. */
export async function benchRun(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const manifest = await loadManifest(ctx, flags);
  const { arms } = await loadArms(ctx, flags);
  const ports = portsFor(ctx, flags);
  const budgetUsd = Number(flags.values.budget);
  const r = await runBenchmark(
    { tasks: manifest.tasks, arms, trials: flags.trials, budgetUsd },
    ports,
    (row, i, n) => {
      const outcome = row.resolved === null ? "pending" : row.resolved ? "resolved" : "unresolved";
      const cost = row.costUsd === null ? "$?" : `$${row.costUsd.toFixed(2)}`;
      ctx.io.out(
        `[${i}/${n}] ${row.taskId} ${row.armId} t${row.trial}: ${row.status}, ${outcome}, ${cost}`,
      );
    },
  );
  if (!r.ok) throw new BenchError(r.error.message);
  const s = r.value;
  ctx.io.out(
    `ran ${s.ran}, already done ${s.skipped}, spent $${s.spentUsd.toFixed(2)} of $${budgetUsd.toFixed(2)}`,
  );
  if (s.stoppedForBudget) {
    ctx.io.err(
      "✗ bench: stopped before a run the budget cannot cover (raise --budget to continue)",
    );
    return 3;
  }
  return 0;
}

/** Writes report.md, report.html and report.json into the results directory. */
export async function benchReport(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const manifest = await loadManifest(ctx, flags);
  const { arms, baseline } = await loadArms(ctx, flags, false);
  const ports = portsFor(ctx, flags);
  const report = buildBenchReport(
    manifest,
    arms,
    baseline,
    await loadRows(ports),
    flags.k,
    ports.now(),
  );
  const md = renderBenchMarkdown(report);
  for (const [name, text] of [
    ["report.md", md],
    ["report.html", renderBenchHtml(report)],
    ["report.json", JSON.stringify(report, null, 2)],
  ] as const) {
    const w = await ports.store.write(name, text);
    if (!w.ok) throw new BenchError(w.error.message);
  }
  const format = flags.values.format ?? "md";
  ctx.io.out(
    format === "json"
      ? JSON.stringify(report, null, 2)
      : format === "html"
        ? renderBenchHtml(report)
        : md,
  );
  return 0;
}

/** The oracle check: hidden tests fail on base and pass on the gold fix. Exit 3 if any task fails. */
export async function benchValidate(flags: BenchFlags, ctx: CommandContext): Promise<number> {
  const manifest = await loadManifest(ctx, flags);
  const ports = portsFor(ctx, flags);
  let bad = 0;
  for (const task of manifest.tasks) {
    const c = await validateTask(task, ports);
    const good = oracleOk(c);
    if (!good) bad++;
    ctx.io.out(
      `${good ? "✓" : "✗"} ${task.id}: fails on base ${c.failsOnBase}, passes on gold ${c.passesOnGold}${good ? "" : ` (${c.note.slice(0, 200)})`}`,
    );
  }
  ctx.io.out(
    `${manifest.tasks.length - bad} of ${manifest.tasks.length} task(s) have a fair oracle`,
  );
  return bad === 0 ? 0 : 3;
}
