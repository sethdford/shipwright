import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import { parseProofConfig } from "../domain/proof/config";
import { detectApp } from "../domain/proof/detect";
import { type ProofPlan, planProof, type WebPlan } from "../domain/proof/plan";
import { redact, tail } from "../domain/proof/redact";
import { renderProofSection } from "../domain/proof/render";
import {
  type CliResult,
  type FlowResult,
  judgeProof,
  type ProofMode,
  type ProofVerdict,
  proofBlocks,
  type WebResult,
} from "../domain/proof/result";
import type { ProofPorts, RunningApp } from "../proof-ports";

/**
 * Run-the-app proof (ADR-0019): start the changed app, drive the changed flows, record what
 * happened, and render it as a PR section with links to the artifacts.
 */

export interface ProofRequest {
  readonly baseRef: string;
  readonly mode: ProofMode;
  readonly publish: boolean;
  /** Names the published folder, e.g. the branch. */
  readonly label: string;
  readonly video: boolean;
  /** Plan only: detect and print what would run, run nothing. */
  readonly dryRun: boolean;
}

export interface ProofReport {
  readonly plan: ProofPlan;
  readonly web: WebResult | null;
  readonly cli: readonly CliResult[];
  readonly verdict: ProofVerdict;
  readonly blocked: boolean;
  readonly baseUrl: string | null;
  readonly publishError: string | null;
  readonly outDir: string;
  readonly section: string;
}

const LOG_MAX = 200_000;
/** Server log lines shown in the PR when the app did not start. */
const START_LOG_INLINE = 2_000;
const CLI_TIMEOUT_MS = 120_000;
const EMPTY_PLAN: ProofPlan = { web: null, cli: [], notes: [] };

async function makePlan(
  ports: ProofPorts,
  baseRef: string,
): Promise<Result<ProofPlan, AdapterError>> {
  const raw = await ports.repo.config();
  if (!raw.ok) return raw;
  const parsed = parseProofConfig(raw.value);
  if (!parsed.ok)
    return err({
      kind: "failed",
      message: `.shipwright/proof.json: ${parsed.problems.join("; ")}`,
    });
  const facts = await ports.repo.facts();
  if (!facts.ok) return facts;
  const changed = await ports.repo.changedFiles(baseRef);
  const port = await ports.launcher.freePort();
  return ok(
    planProof({
      config: parsed.config,
      profile: detectApp(facts.value),
      changed: changed.ok ? changed.value : [],
      port,
    }),
  );
}

async function saveLog(ports: ProofPorts, path: string, text: string): Promise<string> {
  await ports.artifacts.write(path, redact(tail(text, LOG_MAX)));
  return path;
}

async function runWeb(
  ports: ProofPorts,
  plan: WebPlan,
  video: boolean,
  startLogs: Record<string, string>,
): Promise<WebResult> {
  const started = await ports.launcher.start({
    argv: plan.start,
    port: plan.port,
    url: plan.url,
    readyPath: plan.readyPath,
    readyTimeoutMs: plan.readyTimeoutMs,
  });
  if (!started.ok) {
    const serverLog = await saveLog(ports, "web/server.log", started.log);
    startLogs[serverLog] = redact(tail(started.log, START_LOG_INLINE));
    return { status: "start_failed", reason: started.reason, serverLog };
  }
  try {
    return await browse(ports, plan, video, started.app);
  } finally {
    await started.app.stop();
  }
}

async function browse(
  ports: ProofPorts,
  plan: WebPlan,
  video: boolean,
  app: RunningApp,
): Promise<WebResult> {
  const missing = await ports.browser.unavailable();
  if (missing !== null) {
    const reason = `the app started at ${app.url}, but no screenshots: ${missing}`;
    const serverLog = await saveLog(ports, "web/server.log", app.log());
    return { status: "browser_unavailable", reason, serverLog };
  }
  const flows = await ports.browser.run({
    baseUrl: app.url,
    flows: plan.flows,
    outDir: `${ports.artifacts.dir}/web`,
    allowHosts: plan.allowHosts,
    video,
  });
  const serverLog = await saveLog(ports, "web/server.log", app.log());
  return { status: "ran", url: app.url, flows: flows.map(prefixWeb), serverLog };
}

/** The driver names files relative to web/; the report names them relative to the run folder. */
function prefixWeb(flow: FlowResult): FlowResult {
  return {
    ...flow,
    screenshots: flow.screenshots.map((s) => ({ ...s, file: `web/${s.file}` })),
    video: flow.video === null ? null : `web/${flow.video}`,
  };
}

async function runCli(
  ports: ProofPorts,
  plan: ProofPlan,
): Promise<{ results: CliResult[]; texts: Record<string, string> }> {
  const results: CliResult[] = [];
  const texts: Record<string, string> = {};
  for (const [i, run] of plan.cli.entries()) {
    const r = await ports.cli.run(run.argv, CLI_TIMEOUT_MS);
    const text = redact(
      tail(
        `$ ${run.argv.join(" ")}\n${r.stdout}${r.stderr ? `\n${r.stderr}` : ""}\n[exit ${r.exitCode}${r.timedOut ? ", timed out" : ""}]`,
        LOG_MAX,
      ),
    );
    const transcript = `cli/${i + 1}.txt`;
    await ports.artifacts.write(transcript, text);
    texts[transcript] = text;
    results.push({
      name: run.name,
      argv: run.argv,
      exitCode: r.exitCode,
      expectExit: run.expectExit,
      timedOut: r.timedOut,
      transcript,
    });
  }
  return { results, texts };
}

async function publish(ports: ProofPorts, req: ProofRequest, hasArtifacts: boolean) {
  if (!req.publish || !hasArtifacts) return { baseUrl: null, publishError: null };
  const r = await ports.publisher.publish(ports.artifacts.dir, req.label);
  return r.ok
    ? { baseUrl: r.value, publishError: null }
    : { baseUrl: null, publishError: r.error.message };
}

function finish(
  ports: ProofPorts,
  req: ProofRequest,
  parts: {
    plan: ProofPlan;
    web: WebResult | null;
    cli: readonly CliResult[];
    texts: Record<string, string>;
    baseUrl: string | null;
    publishError: string | null;
  },
): ProofReport {
  const verdict = judgeProof(parts.web, parts.cli);
  const shown = parts.publishError
    ? {
        ...verdict,
        warnings: [...verdict.warnings, `artifacts not published: ${parts.publishError}`],
      }
    : verdict;
  const view = { ...parts, verdict: shown, outDir: ports.artifacts.dir };
  return {
    ...parts,
    verdict: shown,
    blocked: proofBlocks(req.mode, verdict),
    outDir: ports.artifacts.dir,
    section: renderProofSection(view),
  };
}

export async function runProof(
  ports: ProofPorts,
  req: ProofRequest,
): Promise<Result<ProofReport, AdapterError>> {
  const none = { web: null, cli: [], texts: {}, baseUrl: null, publishError: null };
  if (req.mode === "off")
    return ok(
      finish(ports, req, {
        plan: { ...EMPTY_PLAN, notes: ["proof is off (SHIPWRIGHT_PROOF=off)"] },
        ...none,
      }),
    );
  const plan = await makePlan(ports, req.baseRef);
  if (!plan.ok) return plan;
  if (req.dryRun) return ok(finish(ports, req, { plan: plan.value, ...none }));
  const startLogs: Record<string, string> = {};
  const web = plan.value.web ? await runWeb(ports, plan.value.web, req.video, startLogs) : null;
  const cli = await runCli(ports, plan.value);
  const pub = await publish(ports, req, web !== null || cli.results.length > 0);
  const report = finish(ports, req, {
    plan: plan.value,
    web,
    cli: cli.results,
    texts: { ...cli.texts, ...startLogs },
    ...pub,
  });
  await ports.artifacts.write(
    "report.json",
    JSON.stringify({ ...report, section: undefined }, null, 2),
  );
  await ports.artifacts.write("proof.md", report.section);
  return ok(report);
}
