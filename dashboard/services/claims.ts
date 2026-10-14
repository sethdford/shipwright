// Label-based claim coordination (/api/claim, /api/claim/release, stale-claim reaper).
//
// SECURITY: every value that reaches a subprocess here comes from an
// unauthenticated HTTP request body (or from the developer registry, which is
// fed by public /api/connect/* routes). Inputs are validated at the boundary and
// subprocesses are spawned with an argv array (execFileSync) — never via a shell
// string — so request data cannot be interpreted as shell syntax.
import { execFileSync, type ExecFileSyncOptions } from "child_process";

// ─── Validation ─────────────────────────────────────────────────────

export const MACHINE_NAME_RE = /^[A-Za-z0-9._-]{1,64}$/;
export const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

/** Positive safe integer issue number (accepts a number or a decimal string). */
export function parseIssueNumber(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value > 0 ? value : null;
  }
  if (typeof value === "string" && /^[1-9][0-9]{0,15}$/.test(value)) {
    const n = Number(value);
    return Number.isSafeInteger(n) ? n : null;
  }
  return null;
}

export function isValidMachineName(value: unknown): value is string {
  return typeof value === "string" && MACHINE_NAME_RE.test(value);
}

/** OWNER/REPO; segments may not be "." / ".." or start with "-" (flag-like). */
export function isValidRepo(value: unknown): value is string {
  if (typeof value !== "string" || !REPO_RE.test(value)) return false;
  return value
    .split("/")
    .every((seg) => seg !== "." && seg !== ".." && !seg.startsWith("-"));
}

// ─── Subprocess runner (injectable for tests) ───────────────────────

export type CommandRunner = (
  file: string,
  args: string[],
  options: ExecFileSyncOptions,
) => string;

export const defaultRunner: CommandRunner = (file, args, options) => {
  const out = execFileSync(file, args, options);
  return out == null ? "" : String(out);
};

const PIPE: ExecFileSyncOptions["stdio"] = ["pipe", "pipe", "pipe"];
const READ_OPTS: ExecFileSyncOptions = {
  encoding: "utf-8",
  timeout: 10000,
  stdio: PIPE,
};
const WRITE_OPTS: ExecFileSyncOptions = { timeout: 10000, stdio: PIPE };

function repoArgs(repo: string): string[] {
  return repo ? ["-R", repo] : [];
}

// ─── argv builders (one per former shell string) ────────────────────

export function ghIssueLabelsArgv(issue: number, repo: string): string[] {
  return [
    "issue",
    "view",
    String(issue),
    ...repoArgs(repo),
    "--json",
    "labels",
    "-q",
    ".labels[].name",
  ];
}

export function ghLabelCreateArgv(machine: string, repo: string): string[] {
  return [
    "label",
    "create",
    `claimed:${machine}`,
    ...repoArgs(repo),
    "--color",
    "EDEDED",
    "--description",
    `Claimed by ${machine}`,
    "--force",
  ];
}

export function ghIssueEditLabelArgv(
  issue: number,
  repo: string,
  op: "--add-label" | "--remove-label",
  label: string,
): string[] {
  return ["issue", "edit", String(issue), ...repoArgs(repo), op, label];
}

export function ghListClaimedIssuesArgv(machine: string): string[] {
  return [
    "issue",
    "list",
    "--label",
    `claimed:${machine}`,
    "--state",
    "open",
    "--json",
    "number",
    "-q",
    ".[].number",
  ];
}

// ─── Handlers ───────────────────────────────────────────────────────

export interface HandlerResult {
  status: number;
  body: Record<string, unknown>;
}

type ClaimInput = { issue: number; machine: string; repo: string };

function validateClaimBody(
  raw: unknown,
  machineRequired: boolean,
): ClaimInput | { error: string } {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { error: "Request body must be a JSON object" };
  }
  const body = raw as Record<string, unknown>;
  const issue = parseIssueNumber(body.issue);
  if (issue === null) {
    return { error: "issue must be a positive integer" };
  }
  const machine = body.machine || body.machine_name || "";
  if (machine === "" && !machineRequired) {
    // release without a machine: remove whichever claimed:* label exists
  } else if (!isValidMachineName(machine)) {
    return { error: "machine must match [A-Za-z0-9._-]{1,64}" };
  }
  const repo = body.repo ?? "";
  if (repo !== "" && !isValidRepo(repo)) {
    return { error: "repo must be OWNER/REPO" };
  }
  return { issue, machine: machine as string, repo: repo as string };
}

export function handleClaim(
  rawBody: unknown,
  run: CommandRunner = defaultRunner,
): HandlerResult {
  const input = validateClaimBody(rawBody, true);
  if ("error" in input) {
    // Deliberately no `approved` field: the daemon (scripts/lib/daemon-state.sh
    // claim_issue) treats approved:false as "claimed elsewhere" and skips the
    // issue, whereas any other response makes it fall back to its own direct
    // (properly quoted) gh label claim — the safe, pre-existing degraded path.
    return { status: 400, body: { error: input.error } };
  }
  const { issue, machine, repo } = input;
  const ourLabel = `claimed:${machine}`;

  // Check for existing claimed:* label
  let labels = "";
  try {
    labels = run("gh", ghIssueLabelsArgv(issue, repo), READ_OPTS).trim();
  } catch {
    labels = "";
  }
  const claimedLabel = labels.split("\n").find((l) => l.startsWith("claimed:"));
  if (claimedLabel) {
    return {
      status: 200,
      body: { approved: false, claimed_by: claimedLabel.replace("claimed:", "") },
    };
  }

  // Ensure the claimed label exists (no-op if already created)
  try {
    run("gh", ghLabelCreateArgv(machine, repo), WRITE_OPTS);
  } catch {
    /* label may already exist or gh label create not supported — fallback below */
  }

  // Add claimed:<machine> label
  try {
    run(
      "gh",
      ghIssueEditLabelArgv(issue, repo, "--add-label", ourLabel),
      WRITE_OPTS,
    );
  } catch {
    return {
      status: 500,
      body: { approved: false, error: "Failed to set label" },
    };
  }

  // VERIFY: re-read labels — if competing claimed:* labels exist, we lost the race
  try {
    const verifyLabels = run("gh", ghIssueLabelsArgv(issue, repo), READ_OPTS)
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("claimed:"));
    if (verifyLabels.length !== 1 || verifyLabels[0] !== ourLabel) {
      // Competing claim — remove ours and reject
      run(
        "gh",
        ghIssueEditLabelArgv(issue, repo, "--remove-label", ourLabel),
        WRITE_OPTS,
      );
      return {
        status: 200,
        body: {
          approved: false,
          claimed_by:
            verifyLabels[0]?.replace("claimed:", "") || "another machine",
          error: "Claim race lost",
        },
      };
    }
  } catch {
    // Verification failed — conservative: remove our label and reject
    try {
      run(
        "gh",
        ghIssueEditLabelArgv(issue, repo, "--remove-label", ourLabel),
        WRITE_OPTS,
      );
    } catch {
      /* best-effort cleanup */
    }
    return {
      status: 500,
      body: { approved: false, error: "Claim verification failed" },
    };
  }

  return { status: 200, body: { approved: true, claimed_by: machine } };
}

export function handleClaimRelease(
  rawBody: unknown,
  run: CommandRunner = defaultRunner,
): HandlerResult {
  const input = validateClaimBody(rawBody, false);
  if ("error" in input) {
    return { status: 400, body: { ok: false, error: input.error } };
  }
  const { issue, machine, repo } = input;

  // Find the actual claimed label if machine not specified
  let targetLabel = machine ? `claimed:${machine}` : "";
  if (!targetLabel) {
    try {
      const labels = run("gh", ghIssueLabelsArgv(issue, repo), READ_OPTS).trim();
      targetLabel =
        labels.split("\n").find((l) => l.startsWith("claimed:")) || "";
    } catch {
      /* ignore */
    }
  }

  if (targetLabel) {
    try {
      run(
        "gh",
        ghIssueEditLabelArgv(issue, repo, "--remove-label", targetLabel),
        WRITE_OPTS,
      );
    } catch {
      /* label may already be removed */
    }
  }

  return { status: 200, body: { ok: true } };
}

/**
 * Remove claimed:<machine> from every open issue (stale-claim reaper).
 * machineName comes from the developer registry (fed by public routes), so it
 * is validated and an invalid name is skipped. Throws if listing fails.
 */
export function releaseStaleClaims(
  machineName: unknown,
  run: CommandRunner = defaultRunner,
): number[] {
  if (!isValidMachineName(machineName)) return [];
  const result = run("gh", ghListClaimedIssuesArgv(machineName), {
    encoding: "utf-8",
    timeout: 15000,
    stdio: PIPE,
  }).trim();
  const released: number[] = [];
  if (!result) return released;
  for (const line of result.split("\n").filter(Boolean)) {
    const issueNum = parseIssueNumber(line.trim());
    if (issueNum === null) continue;
    try {
      run(
        "gh",
        ghIssueEditLabelArgv(
          issueNum,
          "",
          "--remove-label",
          `claimed:${machineName}`,
        ),
        WRITE_OPTS,
      );
      released.push(issueNum);
    } catch {
      /* label may already be removed */
    }
  }
  return released;
}
