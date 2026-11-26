import type { ProofPlan } from "./plan";
import {
  type CliResult,
  cliPassed,
  type FlowResult,
  flowFailures,
  type ProofVerdict,
  type WebResult,
} from "./result";

/** The "Proof it runs" section of the PR body (ADR-0019). */

export interface ProofReportView {
  readonly plan: ProofPlan;
  readonly web: WebResult | null;
  readonly cli: readonly CliResult[];
  readonly verdict: ProofVerdict;
  /** Where artifacts are served, ending in "/", or null when they stayed on the machine. */
  readonly baseUrl: string | null;
  /** Local output directory, named when nothing was published. */
  readonly outDir: string;
  /** Redacted text of small artifacts (CLI transcripts), keyed by artifact path. */
  readonly texts: Readonly<Record<string, string>>;
}

export const PROOF_MARKER = "<!-- shipwright:proof -->";
const INLINE_MAX = 1500;

const ICON = { pass: "✅", fail: "❌", skipped: "⏭️" } as const;

/** Text safe inside a markdown table cell or inline code: no pipes, backticks or newlines. */
export function cell(text: string): string {
  return text.replace(/[`|]/g, "'").replace(/\s+/g, " ").trim().slice(0, 200);
}

/** A code fence longer than any backtick run inside, so output cannot close it early. */
export function fenced(text: string): string {
  const longest = Math.max(2, ...[...text.matchAll(/`+/g)].map((m) => m[0].length));
  const fence = "`".repeat(longest + 1);
  return `${fence}text\n${text}\n${fence}`;
}

function link(view: ProofReportView, file: string, label: string): string {
  return view.baseUrl === null ? `\`${cell(file)}\`` : `[${label}](${view.baseUrl}${file})`;
}

function flowBlock(view: ProofReportView, flow: FlowResult): string[] {
  const failed = flowFailures(flow).length > 0;
  const lines = [`**${failed ? ICON.fail : ICON.pass} ${cell(flow.name)}**`, ""];
  for (const s of flow.screenshots) {
    lines.push(
      view.baseUrl === null
        ? `- screenshot \`${cell(s.file)}\``
        : `![${cell(s.name)}](${view.baseUrl}${s.file})`,
    );
  }
  if (flow.video) lines.push(`- ${link(view, flow.video, "video of this flow")}`);
  const bad = flow.steps.find((s) => !s.ok);
  if (bad) lines.push(`- failed at \`${cell(bad.step)}\`: ${cell(bad.error ?? "")}`);
  for (const e of flow.pageErrors.slice(0, 3)) lines.push(`- page error: \`${cell(e)}\``);
  for (const h of flow.httpErrors.slice(0, 3)) lines.push(`- HTTP ${h.status}: \`${cell(h.url)}\``);
  if (flow.consoleErrors.length > 0)
    lines.push(
      `- ${flow.consoleErrors.length} console error(s), first: \`${cell(flow.consoleErrors[0] ?? "")}\``,
    );
  if (flow.blocked.length > 0)
    lines.push(`- blocked ${flow.blocked.length} request(s) to outside hosts`);
  return [...lines, ""];
}

function webSection(view: ProofReportView, web: WebResult): string[] {
  const log = link(view, web.serverLog, "server log");
  if (web.status !== "ran") {
    const icon = web.status === "start_failed" ? ICON.fail : ICON.skipped;
    const lines = [`#### Web app`, "", `${icon} ${cell(web.reason)} (${log})`, ""];
    const text = view.texts[web.serverLog];
    if (text !== undefined && text.trim() !== "")
      lines.push(
        "<details><summary>last lines of the server log</summary>",
        "",
        fenced(text),
        "",
        "</details>",
        "",
      );
    return lines;
  }
  const source = view.plan.web?.source === "config" ? ".shipwright/proof.json" : "detected";
  const lines = [
    `#### Web app`,
    "",
    `Started \`${cell(view.plan.web?.start.join(" ") ?? "")}\` (${source}), served at \`${cell(web.url)}\`. ${log}.`,
    "",
  ];
  for (const flow of web.flows) lines.push(...flowBlock(view, flow));
  return lines;
}

function cliSection(view: ProofReportView): string[] {
  if (view.cli.length === 0) return [];
  const lines = ["#### Command line", ""];
  for (const r of view.cli) {
    const status = r.timedOut ? "timed out" : `exit ${r.exitCode}`;
    lines.push(
      `**${cliPassed(r) ? ICON.pass : ICON.fail} \`${cell(r.argv.join(" "))}\`** (${status})`,
    );
    const text = view.texts[r.transcript];
    if (text !== undefined) {
      const shown = text.length > INLINE_MAX ? `${text.slice(0, INLINE_MAX)}\n…` : text;
      lines.push("", "<details><summary>output</summary>", "", fenced(shown), "", "</details>");
    }
    lines.push("");
  }
  return lines;
}

function summary(verdict: ProofVerdict): string[] {
  const head = {
    pass: "The app ran and the changed flows worked.",
    fail: "Running the app found a problem.",
    skipped: "Nothing could be run.",
  }[verdict.status];
  const lines = [`${ICON[verdict.status]} **${head}**`, ""];
  for (const f of verdict.failures.slice(0, 5)) lines.push(`- ${cell(f)}`);
  for (const w of verdict.warnings.slice(0, 3)) lines.push(`- note: ${cell(w)}`);
  return lines.length > 2 ? [...lines, ""] : lines;
}

export function renderProofSection(view: ProofReportView): string {
  const lines = [PROOF_MARKER, "### Proof it runs", "", ...summary(view.verdict)];
  for (const note of view.plan.notes) lines.push(`- ${cell(note)}`, "");
  if (view.web) lines.push(...webSection(view, view.web));
  lines.push(...cliSection(view));
  if (view.baseUrl === null && (view.web !== null || view.cli.length > 0))
    lines.push(
      `_Artifacts were kept on the machine that ran the pipeline, in \`${cell(view.outDir)}\`._`,
    );
  lines.push("_Run in the sandbox without credentials; requests to outside hosts were blocked._");
  return lines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trimEnd();
}
