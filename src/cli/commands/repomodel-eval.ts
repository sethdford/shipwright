import { type EvalReport, evaluateLocalization } from "../../contexts/intelligence";
import type { CommandContext } from "../command";
import { adapterFailure } from "../shared";
import { envOn } from "./governance-flags";
import { type ModelArgs, rootOf } from "./repomodel-args";

const pct = (x: number) => `${Math.round(x * 100)}%`;

function render(r: EvalReport, arm: string): string {
  const s = r.summary;
  const lines = [
    `Localization check (semantic ${arm}): ${s.cases} past PRs, each scored on a model of its parent commit`,
    `  first changed file at rank 1: ${pct(s.acc1)}   in top 5: ${pct(s.acc5)}   in top 10: ${pct(s.acc10)}`,
    `  share of changed files in top 10: ${pct(s.recall10)}`,
    "",
  ];
  for (const c of r.results.filter((x) => x.findable.length > 0)) {
    const hit = c.firstHit === null ? "miss" : `#${c.firstHit}`;
    lines.push(`  ${hit.padStart(4)}  ${c.id}  ${c.task.slice(0, 90)}`);
  }
  return lines.join("\n");
}

/** Per-case results in the eval ratchet's format: a case passes when a changed file ranks in the top 5. */
function exported(r: EvalReport, policy: string): string {
  const runs = r.results
    .filter((c) => c.findable.length > 0)
    .map((c) => ({ case: c.id, pass: c.firstHit !== null && c.firstHit <= 5, costUsd: 0 }));
  return JSON.stringify({ policy, runs });
}

export async function evaluate(ctx: CommandContext, a: ModelArgs): Promise<number> {
  const semantic = envOn(ctx.env.SHIPWRIGHT_REPO_MODEL_SEMANTIC);
  const arm = semantic ? "on" : "off";
  const r = await evaluateLocalization(ctx.repoModel(), {
    root: rootOf(ctx, a),
    ref: a.values["--ref"] ?? "HEAD",
    commits: Number(a.values["--commits"] ?? "200"),
    semantic,
  });
  if (!r.ok) return adapterFailure(ctx.io, "localization check", r.error);
  if (a.switches.has("--export"))
    ctx.io.out(exported(r.value, a.values["--policy"] ?? `repomodel-semantic-${arm}`));
  else if (a.switches.has("--json")) ctx.io.out(JSON.stringify({ ...r.value, semantic: arm }));
  else ctx.io.out(render(r.value, arm));
  return 0;
}
