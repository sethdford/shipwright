import { type ProofPlan, type ProofReport, runProof } from "../../contexts/quality";
import type { Command, CommandContext } from "../command";
import { adapterFailure, isHelpRequest, usageError } from "../shared";
import { parseProofFlags } from "./proof-flags";

const usage = `USAGE
  shipwright proof run  [--base REF] [--mode off|advisory|enforce] [--publish|--no-publish]
                        [--label NAME] [--out DIR] [--no-video] [--format text|json|markdown]
  shipwright proof plan [--base REF] [--format text|json]

DESCRIPTION
  Run-the-app proof (ADR-0019): starts the app the current branch changed, drives the changed
  flows in a headless browser (or runs the CLI), and writes screenshots, a video, the server log
  and CLI transcripts, plus a "Proof it runs" section for the PR body.

  run   Detects the app from the repository root (package.json dev/start scripts and framework,
        a package.json bin, Cargo or Go mains), or follows .shipwright/proof.json. Web pages come
        from the files the change touched (file-system routes: Next.js, SvelteKit, Astro, Nuxt,
        Remix), always starting at "/". The app runs through scripts/lib/test-gate-exec.sh,
        without GitHub, git or Claude credentials; pages may only reach the app and the hosts
        proof.json allows. --publish pushes the artifacts to the shipwright-proof branch so the
        PR can show them. Artifacts go to --out (default: the state dir, proof/<run>).
  plan  Prints what run would do, and runs nothing.

PROOF.JSON
  { "web": { "start": ["npm","run","dev"], "port": 3000, "readyPath": "/",
             "allowHosts": ["fonts.googleapis.com"],
             "flows": [ { "name": "login", "steps": [ {"goto": "/login"},
               {"fill": {"selector": "#email", "value": "a@b.co"}}, {"click": "text=Sign in"},
               {"expectText": "Welcome"}, {"screenshot": "signed-in"} ] } ] },
    "cli": { "runs": [ { "name": "help", "argv": ["node","bin/cli.js","--help"] } ] } }
  Steps: goto, click, fill, press, waitFor, expectText, screenshot. They are data, never code.

GATE
  The mode comes from --mode, else SHIPWRIGHT_PROOF (default advisory). A run fails when the
  app does not start, a step fails, a page throws, the app answers 5xx, or a CLI run exits with
  an unexpected code. Enforce blocks the PR on a failure; advisory only reports. Nothing to run
  (or no browser) is "skipped" and never blocks.

EXIT CODES
  0  pass, skipped, or a failure in advisory mode   1  could not read the repository
  2  usage error                                    3  blocked (enforce mode only)`;

const SUBCOMMANDS = ["run", "plan"];

function renderPlan(plan: ProofPlan): string {
  const lines: string[] = [];
  if (plan.web) {
    lines.push(`web: ${plan.web.start.join(" ")} (${plan.web.source}, port ${plan.web.port})`);
    for (const f of plan.web.flows) lines.push(`  flow ${f.name}: ${f.steps.length} step(s)`);
  }
  for (const r of plan.cli) lines.push(`cli: ${r.argv.join(" ")} (expect exit ${r.expectExit})`);
  for (const n of plan.notes) lines.push(`note: ${n}`);
  return lines.length > 0 ? lines.join("\n") : "nothing to run";
}

function renderText(report: ProofReport): string {
  const lines = [`proof: ${report.verdict.status}${report.blocked ? " (blocked)" : ""}`];
  for (const f of report.verdict.failures) lines.push(`  ✗ ${f}`);
  for (const w of report.verdict.warnings) lines.push(`  ⚠ ${w}`);
  lines.push(`artifacts: ${report.baseUrl ?? report.outDir}`);
  return lines.join("\n");
}

function output(report: ProofReport, format: string): string {
  if (format === "json") return JSON.stringify(report, null, 2);
  if (format === "markdown") return report.section;
  return renderText(report);
}

async function run(args: readonly string[], ctx: CommandContext, dryRun: boolean): Promise<number> {
  const flags = parseProofFlags(args, ctx.env.SHIPWRIGHT_PROOF);
  if (typeof flags === "string") return usageError(ctx.io, usage, flags);
  const ports = ctx.proof(flags.outDir);
  const r = await runProof(ports, {
    baseRef: flags.base,
    mode: flags.mode,
    publish: flags.publish,
    label: flags.label,
    video: flags.video,
    dryRun,
  });
  if (!r.ok) return adapterFailure(ctx.io, "proof", r.error);
  if (dryRun) {
    ctx.io.out(
      flags.format === "json" ? JSON.stringify(r.value.plan, null, 2) : renderPlan(r.value.plan),
    );
    return 0;
  }
  ctx.io.out(output(r.value, flags.format));
  return r.value.blocked ? 3 : 0;
}

export const proofCommand: Command = {
  name: "proof",
  aliases: [],
  summary: "Run the changed app and record screenshots, video and logs as PR proof",
  usage,
  async run(args, ctx) {
    if (isHelpRequest(args, SUBCOMMANDS)) {
      ctx.io.out(usage);
      return 0;
    }
    const [sub, ...rest] = args;
    if (sub === "run") return run(rest, ctx, false);
    if (sub === "plan") return run(rest, ctx, true);
    return usageError(
      ctx.io,
      usage,
      sub === undefined ? "missing subcommand" : `unknown subcommand ${sub}`,
    );
  },
};
