import { z } from "zod";
import type { FileChange, PullFiles } from "../../contexts/quality";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { runOrFail } from "../process/run-or-fail";
import { classifyGhError } from "./gh-json";

const Row = z.object({ filename: z.string(), additions: z.number(), deletions: z.number() });

/** One JSON object per line, as `--jq '.[]'` prints them across every page. */
export function parseFileRows(stdout: string): Result<FileChange[], AdapterError> {
  const out: FileChange[] = [];
  for (const line of stdout.split("\n")) {
    if (line.trim() === "") continue;
    let json: unknown;
    try {
      json = JSON.parse(line);
    } catch {
      return err({ kind: "failed", message: `unexpected gh output: ${line.slice(0, 80)}` });
    }
    const row = Row.safeParse(json);
    if (!row.success) return err({ kind: "failed", message: "unexpected gh file row" });
    out.push({
      path: row.data.filename,
      additions: row.data.additions,
      deletions: row.data.deletions,
    });
  }
  return ok(out);
}

/**
 * Per-file line counts of a PR through the REST API (`gh api … --paginate`, argv only). REST, not
 * `gh pr view --json files`: GraphQL caps the file list at 100 and is blocked in some sandboxes.
 */
export class GhPullFiles implements PullFiles {
  constructor(private readonly runner: ProcessRunner) {}

  async files(pr: number) {
    if (!Number.isInteger(pr) || pr <= 0)
      return err({ kind: "failed" as const, message: "bad PR number" });
    const argv = [
      "gh",
      "api",
      "--paginate",
      `repos/{owner}/{repo}/pulls/${pr}/files?per_page=100`,
      "--jq",
      ".[] | {filename, additions, deletions}",
    ];
    const r = await runOrFail(this.runner, { argv, timeoutMs: 60_000 });
    if (r.exitCode !== 0 || r.timedOut) return err(classifyGhError(r));
    return parseFileRows(r.stdout);
  }
}
