/**
 * What a proof run saw (ADR-0019) and the verdict on it. Artifact paths are relative to the run's
 * output directory, so the same report renders against a local folder or a published URL.
 */

export interface StepOutcome {
  readonly step: string;
  readonly ok: boolean;
  readonly error?: string;
}

export interface Capture {
  readonly name: string;
  readonly file: string;
}

export interface HttpError {
  readonly url: string;
  readonly status: number;
}

export interface FlowResult {
  readonly name: string;
  readonly steps: readonly StepOutcome[];
  readonly screenshots: readonly Capture[];
  readonly video: string | null;
  /** console.error lines: reported, not failing (dev servers are noisy). */
  readonly consoleErrors: readonly string[];
  /** Uncaught exceptions in the page: failing. */
  readonly pageErrors: readonly string[];
  /** Responses with status 500 or more from the app: failing. */
  readonly httpErrors: readonly HttpError[];
  /** Requests to hosts outside the allow list, stopped before they left the machine. */
  readonly blocked: readonly string[];
}

export type WebResult =
  | {
      readonly status: "ran";
      readonly url: string;
      readonly flows: readonly FlowResult[];
      readonly serverLog: string;
    }
  | { readonly status: "start_failed"; readonly reason: string; readonly serverLog: string }
  | { readonly status: "browser_unavailable"; readonly reason: string; readonly serverLog: string };

export interface CliResult {
  readonly name: string;
  readonly argv: readonly string[];
  readonly exitCode: number;
  readonly expectExit: number;
  readonly timedOut: boolean;
  readonly transcript: string;
}

export type ProofStatus = "pass" | "fail" | "skipped";

export interface ProofVerdict {
  readonly status: ProofStatus;
  readonly failures: readonly string[];
  readonly warnings: readonly string[];
}

export function flowFailures(flow: FlowResult): string[] {
  const out: string[] = [];
  const bad = flow.steps.find((s) => !s.ok);
  if (bad) out.push(`${flow.name}: step "${bad.step}" failed${bad.error ? `: ${bad.error}` : ""}`);
  if (flow.pageErrors.length > 0)
    out.push(`${flow.name}: ${flow.pageErrors.length} uncaught page error(s)`);
  if (flow.httpErrors.length > 0)
    out.push(`${flow.name}: ${flow.httpErrors.length} server error response(s)`);
  return out;
}

export const cliPassed = (r: CliResult): boolean => !r.timedOut && r.exitCode === r.expectExit;

function webFindings(web: WebResult | null): { failures: string[]; warnings: string[] } {
  if (web === null) return { failures: [], warnings: [] };
  if (web.status === "start_failed")
    return { failures: [`app did not start: ${web.reason}`], warnings: [] };
  if (web.status === "browser_unavailable") return { failures: [], warnings: [web.reason] };
  const failures = web.flows.flatMap(flowFailures);
  const consoleCount = web.flows.reduce((n, f) => n + f.consoleErrors.length, 0);
  const warnings = consoleCount > 0 ? [`${consoleCount} console error(s) logged`] : [];
  return { failures, warnings };
}

/** pass: something ran and nothing failed. skipped: nothing could run. fail: anything failed. */
export function judgeProof(web: WebResult | null, cli: readonly CliResult[]): ProofVerdict {
  const w = webFindings(web);
  const failures = [
    ...w.failures,
    ...cli
      .filter((r) => !cliPassed(r))
      .map((r) =>
        r.timedOut
          ? `${r.name}: timed out`
          : `${r.name}: exited ${r.exitCode}, expected ${r.expectExit}`,
      ),
  ];
  const ran = web?.status === "ran" || web?.status === "start_failed" || cli.length > 0;
  const status: ProofStatus = failures.length > 0 ? "fail" : ran ? "pass" : "skipped";
  return { status, failures, warnings: w.warnings };
}

export type ProofMode = "off" | "advisory" | "enforce";

/** Enforce blocks the PR on a failed proof; advisory and a skipped proof never block. */
export const proofBlocks = (mode: ProofMode, verdict: ProofVerdict): boolean =>
  mode === "enforce" && verdict.status === "fail";
