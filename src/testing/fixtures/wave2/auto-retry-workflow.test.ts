import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";
import { createTestEnv, type TestEnv } from "../../test-env";

// W2-03: the categorise and strategy steps of shipwright-auto-retry.yml, run for real. The `run:`
// scripts are read from the workflow YAML and executed with bash. `gh`, the bot-comment and retry
// readers are stubbed; the classifier is the real `src/cli.ts`, run through Bun. Nothing here
// re-implements the workflow logic.
const REPO = fileURLToPath(new URL("../../../../", import.meta.url));
const AUTH_LOG = readFileSync(new URL("preflight-auth.log", import.meta.url), "utf8");
const SYSTEM_PATH = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"];

interface Step {
  readonly name?: string;
  readonly run?: string;
}
const steps: readonly Step[] = parse(
  readFileSync(join(REPO, ".github/workflows/shipwright-auto-retry.yml"), "utf8"),
).jobs["auto-retry"].steps;

function stepNamed(name: string): Step {
  const step = steps.find((s) => s.name === name);
  if (step?.run === undefined) throw new Error(`no run script for step: ${name}`);
  return step;
}

const CATEGORIZE = stepNamed("Categorize error from run logs");
const STRATEGY = stepNamed("Check retry count and determine strategy");

interface Fixture {
  readonly logFailed: string;
  readonly jobs: string;
  readonly conclusion?: string;
  readonly stubBun?: { readonly out: string; readonly rc: number };
}

const NO_TIMEOUT = JSON.stringify({
  jobs: [{ conclusion: "failure", steps: [{ conclusion: "failure" }] }],
});
const TIMED_OUT = JSON.stringify({
  jobs: [{ conclusion: "failure", steps: [{ conclusion: "timed_out" }] }],
});

const GH_STUB = `#!/usr/bin/env bash
case "$*" in
  *"--log-failed"*) cat "$STUB_LOG_FAILED" ;;
  *"--json jobs"*) cat "$STUB_JOBS" ;;
  *"run view"*) cat "$STUB_LOG_FAILED" ;;
  *) echo "$*" >> "$STUB_CALLS" ;;
esac
`;
const BUN_STUB = `#!/usr/bin/env bash
printf '%s' "$STUB_BUN_OUT"
exit "$STUB_BUN_RC"
`;

function writeExec(path: string, body: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, body);
  chmodSync(path, 0o755);
}

interface Sandbox {
  readonly work: string;
  readonly binDir: string;
  readonly calls: string;
  readonly output: string;
}

/** A working directory that looks like the repo root: the real src, stubbed scripts/ci readers. */
function sandbox(env: TestEnv, fx: Fixture): Sandbox {
  const work = join(env.root, "work");
  const binDir = join(work, "bin");
  mkdirSync(binDir, { recursive: true });
  for (const entry of ["src", "node_modules", "package.json", "tsconfig.json"]) {
    symlinkSync(join(REPO, entry), join(work, entry));
  }
  writeExec(join(work, "scripts/ci/bot-comments.sh"), "#!/usr/bin/env bash\necho '[]'\n");
  writeExec(
    join(work, "scripts/ci/retry-state.sh"),
    '#!/usr/bin/env bash\necho \'{"retry":0,"abandoned":false}\'\n',
  );
  writeExec(join(binDir, "gh"), GH_STUB);
  if (fx.stubBun !== undefined) writeExec(join(binDir, "bun"), BUN_STUB);
  writeFileSync(join(work, "failed.log"), fx.logFailed);
  writeFileSync(join(work, "jobs.json"), fx.jobs);
  const calls = join(work, "calls.txt");
  writeFileSync(calls, "");
  return { work, binDir, calls, output: join(work, "output.txt") };
}

function run(
  env: TestEnv,
  sb: Sandbox,
  fx: Fixture,
  step: Step,
  vars: Record<string, string>,
): { code: number; out: Record<string, string>; stdout: string } {
  const script = join(sb.work, `step-${Math.random().toString(36).slice(2)}.sh`);
  writeFileSync(script, step.run ?? "");
  writeFileSync(sb.output, "");
  const bunDirs = fx.stubBun === undefined ? [] : [sb.binDir];
  const proc = Bun.spawnSync(["bash", "-eo", "pipefail", script], {
    cwd: sb.work,
    env: {
      // A fixed PATH: the stubs, the bun that runs the test, and the standard tool directories.
      PATH: [...bunDirs, sb.binDir, dirname(process.execPath), ...SYSTEM_PATH].join(":"),
      HOME: env.home,
      RUNNER_TEMP: sb.work,
      GITHUB_OUTPUT: sb.output,
      GITHUB_REPOSITORY: "owner/repo",
      GITHUB_SERVER_URL: "https://github.example",
      GITHUB_TOKEN: "test-token",
      RUN_ID: "100",
      CONCLUSION: "failure",
      ISSUE_NUMBER: "42",
      STUB_LOG_FAILED: join(sb.work, "failed.log"),
      STUB_JOBS: join(sb.work, "jobs.json"),
      STUB_CALLS: sb.calls,
      STUB_BUN_OUT: fx.stubBun?.out ?? "",
      STUB_BUN_RC: String(fx.stubBun?.rc ?? 0),
      ...vars,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const out: Record<string, string> = {};
  for (const line of readFileSync(sb.output, "utf8").split("\n")) {
    const eq = line.indexOf("=");
    if (eq > 0 && !line.includes("<<")) out[line.slice(0, eq)] = line.slice(eq + 1);
  }
  return { code: proc.exitCode ?? -1, out, stdout: proc.stdout.toString() };
}

function withSandbox<T>(fx: Fixture, body: (env: TestEnv, sb: Sandbox) => T): T {
  const env = createTestEnv();
  try {
    return body(env, sandbox(env, fx));
  } finally {
    env.cleanup();
  }
}

function categorize(fx: Fixture): { code: number; out: Record<string, string>; stdout: string } {
  return withSandbox(fx, (env, sb) =>
    run(env, sb, fx, CATEGORIZE, { CONCLUSION: fx.conclusion ?? "failure" }),
  );
}

describe("W2-03 auto-retry: AUTH is never retried (run for real)", () => {
  test("the auth fixture is categorised AUTH and the strategy refuses the retry", () => {
    withSandbox({ logFailed: AUTH_LOG, jobs: NO_TIMEOUT }, (env, sb) => {
      const fx = { logFailed: AUTH_LOG, jobs: NO_TIMEOUT };
      const cat = run(env, sb, fx, CATEGORIZE, { CONCLUSION: "failure" });
      expect(cat.code).toBe(0);
      expect(cat.out.error_category).toBe("AUTH");

      const strat = run(env, sb, fx, STRATEGY, { ERROR_CATEGORY: cat.out.error_category ?? "" });
      expect(strat.code).toBe(0);
      expect(strat.out.should_retry).toBe("false");
      expect(strat.out.skip_reason).toBe("auth");
      expect(readFileSync(sb.calls, "utf8").includes("workflow run")).toBe(false);
    });
  });

  test("the strategy step refuses AUTH even when the retry count is zero", () => {
    withSandbox({ logFailed: AUTH_LOG, jobs: NO_TIMEOUT }, (env, sb) => {
      const fx = { logFailed: AUTH_LOG, jobs: NO_TIMEOUT };
      const strat = run(env, sb, fx, STRATEGY, { ERROR_CATEGORY: "AUTH" });
      expect(strat.out.should_retry).toBe("false");
    });
  });
});

describe("W2-03 every escalation is no-retry (ADR-0009 rule 10)", () => {
  const cases: readonly { name: string; log: string; category: string; skip: string }[] = [
    {
      name: "contamination",
      log: "⚠ Skipping integration tests: refusing to run inside a build-loop test gate\n",
      category: "CONTAMINATION",
      skip: "contamination",
    },
    {
      name: "invalid_input",
      log: "Error: issue not found\n",
      category: "INVALID_INPUT",
      skip: "invalid_input",
    },
  ];
  for (const c of cases) {
    test(`a ${c.name} verdict is categorised ${c.category} and never retried`, () => {
      withSandbox({ logFailed: c.log, jobs: NO_TIMEOUT }, (env, sb) => {
        const fx = { logFailed: c.log, jobs: NO_TIMEOUT };
        const cat = run(env, sb, fx, CATEGORIZE, { CONCLUSION: "failure" });
        expect(cat.code).toBe(0);
        expect(cat.out.error_category).toBe(c.category);
        const strat = run(env, sb, fx, STRATEGY, { ERROR_CATEGORY: c.category });
        expect(strat.out.should_retry).toBe("false");
        expect(strat.out.skip_reason).toBe(c.skip);
      });
    });
  }

  test("an exit-3 verdict with an unmapped class fails closed", () => {
    const result = categorize({
      logFailed: "npm test\n",
      jobs: NO_TIMEOUT,
      stubBun: { out: '{"class":"budget"}', rc: 3 },
    });
    expect(result.code).not.toBe(0);
    expect(result.out.error_category).toBeUndefined();
  });
});

describe("W2-03 deviation: transient only from trusted channels (#8674)", () => {
  test("a forged HTTP 503 or ECONNRESET in the log is not a transient verdict", () => {
    const forged = "npm test\nHTTP 503 Service Unavailable\nECONNRESET while fetching\n";
    const control = "npm test\nsome output\n";
    const withForged = categorize({ logFailed: forged, jobs: NO_TIMEOUT });
    const withControl = categorize({ logFailed: control, jobs: NO_TIMEOUT });
    expect(withForged.code).toBe(0);
    // The classifier does see the forged transient, and the workflow says it is not used.
    expect(withForged.stdout).toContain("Classifier said transient from log text; not used");
    expect(withForged.out.error_category).not.toBe("TRANSIENT");
    expect(withForged.out.error_category).toBe(withControl.out.error_category ?? "");
  });

  test("a job the API reports as timed out is TRANSIENT", () => {
    const result = categorize({ logFailed: "npm test\nsome output\n", jobs: TIMED_OUT });
    expect(result.out.error_category).toBe("TRANSIENT");
  });

  test("a cancelled run is TRANSIENT from its trusted conclusion", () => {
    const result = categorize({
      logFailed: "",
      jobs: NO_TIMEOUT,
      conclusion: "cancelled",
    });
    expect(result.out.error_category).toBe("TRANSIENT");
  });
});

describe("W2-03 gates fail closed on the classifier", () => {
  test("a classifier error (exit 1) fails the job with no category", () => {
    const result = categorize({
      logFailed: "npm test\n",
      jobs: NO_TIMEOUT,
      stubBun: { out: "", rc: 1 },
    });
    expect(result.code).not.toBe(0);
    expect(result.out.error_category).toBeUndefined();
  });

  test("an unknown class code fails the job with no category", () => {
    const result = categorize({
      logFailed: "npm test\n",
      jobs: NO_TIMEOUT,
      stubBun: { out: '{"class":"bogus"}', rc: 0 },
    });
    expect(result.code).not.toBe(0);
    expect(result.out.error_category).toBeUndefined();
  });

  test("an empty classifier output fails the job with no category", () => {
    const result = categorize({
      logFailed: "npm test\n",
      jobs: NO_TIMEOUT,
      stubBun: { out: "", rc: 0 },
    });
    expect(result.code).not.toBe(0);
    expect(result.out.error_category).toBeUndefined();
  });
});

describe("W2-03 workflow order", () => {
  test("Bun is set up and the CLI dependencies installed before the categorise step", () => {
    const names = steps.map((s) => s.name ?? "");
    const categorizeAt = names.indexOf("Categorize error from run logs");
    expect(names.indexOf("Set up Bun for the failure classifier")).toBeLessThan(categorizeAt);
    expect(names.indexOf("Install the Shipwright CLI dependencies")).toBeLessThan(categorizeAt);
  });
});

// #8696: a line that only mentions an escalation, or DNS and model errors, must not escalate. Each of these used to
// block the retry permanently (and the category marker then treated the issue as handled).
describe("false escalations do not block the retry (#8696)", () => {
  const falsePositives: readonly { name: string; log: string }[] = [
    { name: "a bare refusal sentence", log: "refusing to run inside a build-loop test gate\n" },
    {
      name: "a forged CONTAMINATION line in test output",
      log: '  $ echo "CONTAMINATION: x"\nCONTAMINATION: x\nall tests passed\n',
    },
    { name: "a DNS failure", log: "Could not resolve host: api.github.com\n" },
    { name: "a dependency resolution failure", log: "npm ERR! could not resolve dependencies\n" },
    { name: "a bare 404 from a model call", log: "API Error: 404 model not found\n" },
  ];
  for (const c of falsePositives) {
    test(`${c.name} is not an escalation`, () => {
      withSandbox({ logFailed: c.log, jobs: NO_TIMEOUT }, (env, sb) => {
        const fx = { logFailed: c.log, jobs: NO_TIMEOUT };
        const cat = run(env, sb, fx, CATEGORIZE, { CONCLUSION: "failure" });
        expect(cat.code).toBe(0);
        expect(["CONTAMINATION", "INVALID_INPUT"]).not.toContain(cat.out.error_category);
      });
    });
  }
});
