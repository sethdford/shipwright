import { parseAnswer } from "../domain/agent-output";
import { type AcceptanceManifest, parseManifest, untracedCriteria } from "../domain/manifest";
import { chooseTemplate, type RunTemplate, renderRun } from "../domain/run-command";
import { type RunVerdict, redVerdict } from "../domain/run-verdict";
import type { AcceptanceWorkspace, ArtifactStore, TestExecutor } from "../ports";

export interface AcceptancePorts {
  readonly ws: AcceptanceWorkspace;
  readonly exec: TestExecutor;
  readonly artifacts: ArtifactStore;
}

export interface TestRun {
  readonly path: string;
  readonly argv: readonly string[];
  readonly verdict: RunVerdict;
  /** The end of the run's output, for the report and the writer's retry prompt. */
  readonly tail: string;
}

export type Materialized =
  | { readonly ok: true; readonly kind: "tests"; readonly files: readonly string[] }
  | { readonly ok: true; readonly kind: "not_testable"; readonly reason: string }
  | { readonly ok: false; readonly problems: readonly string[] };

/**
 * Writes the test writer's answer: the manifest to the artifacts and each test file into the
 * repository. Nothing is written unless the whole answer is valid and every test file is new.
 */
export async function materialize(
  answer: string,
  manifestPath: string,
  ports: Pick<AcceptancePorts, "ws" | "artifacts">,
): Promise<Materialized> {
  const parsed = parseAnswer(answer);
  if (!parsed.ok) return parsed;
  const existing: string[] = [];
  for (const f of parsed.files) if (await ports.ws.exists(f.path)) existing.push(f.path);
  if (existing.length > 0) {
    return {
      ok: false,
      problems: existing.map((p) => `${p}: already exists; acceptance tests go in new files`),
    };
  }
  for (const f of parsed.files) {
    const w = await ports.ws.writeText(f.path, f.content);
    if (!w.ok) return { ok: false, problems: [`${f.path}: ${w.error.message}`] };
  }
  const saved = await ports.artifacts.write(manifestPath, parsed.manifestJson);
  if (!saved.ok) return { ok: false, problems: [`manifest: ${saved.error.message}`] };
  if (parsed.manifest.kind === "not_testable") {
    return { ok: true, kind: "not_testable", reason: parsed.manifest.reason };
  }
  return { ok: true, kind: "tests", files: parsed.files.map((f) => f.path) };
}

export interface RunOptions {
  readonly manifestPath: string;
  readonly configured?: RunTemplate | undefined;
  readonly testCmd?: string | undefined;
  readonly timeoutMs: number;
}

export type RedReport =
  | { readonly ok: true; readonly kind: "not_testable"; readonly reason: string }
  | {
      readonly ok: boolean;
      readonly kind: "tests";
      readonly problems: readonly string[];
      readonly runs: readonly TestRun[];
      readonly template?: RunTemplate;
    };

export async function loadManifest(
  path: string,
  artifacts: ArtifactStore,
): Promise<
  { ok: true; manifest: AcceptanceManifest } | { ok: false; problems: readonly string[] }
> {
  const text = await artifacts.read(path);
  if (!text.ok) return { ok: false, problems: [`manifest: ${text.error.message}`] };
  return parseManifest(text.value);
}

/**
 * Proves each acceptance test red before any implementation exists: run alone, it must fail on
 * an assertion or on the missing feature, and name itself in the output.
 */
export async function verifyRed(opts: RunOptions, ports: AcceptancePorts): Promise<RedReport> {
  const loaded = await loadManifest(opts.manifestPath, ports.artifacts);
  if (!loaded.ok) return { ok: false, kind: "tests", problems: loaded.problems, runs: [] };
  const m = loaded.manifest;
  if (m.kind === "not_testable") return { ok: true, kind: "not_testable", reason: m.reason };
  const chosen = chooseTemplate({
    configured: opts.configured,
    testCmd: opts.testCmd,
    proposed: m.run,
  });
  if (!chosen.ok) return { ok: false, kind: "tests", problems: [chosen.problem], runs: [] };
  const problems: string[] = [];
  const runs: TestRun[] = [];
  for (const t of m.tests) {
    const content = await ports.ws.readText(t.path);
    if (!content.ok) {
      problems.push(`${t.path}: ${content.error.message}`);
      continue;
    }
    for (const c of untracedCriteria(t, content.value))
      problems.push(`${t.path}: never mentions ${c}`);
    const run = await runOne(t.path, chosen.template, opts.timeoutMs, ports.exec);
    runs.push({ ...run, verdict: redVerdict(run.outcome, t.path, t.criteria) });
  }
  const ok = problems.length === 0 && runs.every((r) => r.verdict.ok);
  return { ok, kind: "tests", problems, runs, template: chosen.template };
}

export async function runOne(
  path: string,
  template: RunTemplate,
  timeoutMs: number,
  exec: TestExecutor,
): Promise<{
  path: string;
  argv: readonly string[];
  tail: string;
  outcome: { exitCode: number; timedOut: boolean; output: string };
}> {
  const argv = renderRun(template, path);
  const r = await exec.run(argv, timeoutMs);
  const output = `${r.stdout}\n${r.stderr}`;
  return {
    path,
    argv,
    tail: tailLines(output, 40),
    outcome: { exitCode: r.exitCode, timedOut: r.timedOut, output },
  };
}

function tailLines(text: string, n: number): string {
  const lines = text.trimEnd().split("\n");
  return lines.slice(-n).join("\n").slice(-4000);
}
