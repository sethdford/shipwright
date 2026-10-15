import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parse } from "yaml";

/**
 * Parity: the marker and dispatch writes exist twice, in shipwright-dispatch.yml's loop (inline: a
 * composite action cannot run per issue) and in .github/actions/dispatch-pipeline. Both must post
 * the same comment (marker text) and dispatch the same workflow with the same arguments (ADR-0007).
 * This reads both real files, normalises variable names and whitespace, and compares.
 */

const ROOT = join(import.meta.dir, "..", "..");
type Step = { name?: string; uses?: string; run?: string };

function stepRun(file: string, name: string): string {
  const doc = parse(readFileSync(join(ROOT, file), "utf8"));
  const steps: Step[] = doc.jobs
    ? (Object.values(doc.jobs)[0] as { steps: Step[] }).steps
    : doc.runs.steps;
  const step = steps.find((s) => s.name === name);
  if (!step?.run) throw new Error(`no run step "${name}" in ${file}`);
  return step.run;
}

interface Writes {
  commentIssue: string;
  commentRepo: string;
  body: string;
  dispatchRepo: string;
  dispatchIssue: string;
  template: string;
}

function writesOf(script: string, form: "inline" | "printf"): Writes {
  const flat = script.replace(/\\\n/g, " ").replace(/\n/g, " ");
  const comment = /gh issue comment "\$(\w+)"\s+--repo "\$(\w+)"\s+--body (.*?); then/.exec(flat);
  const dispatch =
    /gh workflow run shipwright-pipeline\.yml\s+--repo "\$(\w+)"\s+-f issue_number="\$(\w+)"\s+-f template=(\w+)/.exec(
      flat,
    );
  if (!comment || !dispatch) throw new Error("marker or dispatch command not found");
  let body: string;
  if (form === "printf") {
    const printf = /BODY=\$\(printf '([^']*)' "\$REQUESTED_AT"\)/.exec(script);
    if (!printf) throw new Error("printf body not found");
    body = printf[1]!.replace(/\\n/g, "").replace(/%s/g, "${REQUESTED_AT}");
  } else {
    body = comment[3]!.replace(/^"|"$/g, "");
  }
  // Map each script's own variable names onto one vocabulary.
  const id = (v: string) => (v === "issue" || v === "ISSUE" ? "ID" : v);
  const repo = (v: string) => (v === "GITHUB_REPOSITORY" || v === "REPO" ? "REPO" : v);
  return {
    commentIssue: id(comment[1]!),
    commentRepo: repo(comment[2]!),
    body: body.replace(/\s+/g, ""),
    dispatchRepo: repo(dispatch[1]!),
    dispatchIssue: id(dispatch[2]!),
    template: dispatch[3]!,
  };
}

test("the inline loop and the composite action write the same marker and dispatch", () => {
  const inline = writesOf(
    stepRun(
      ".github/workflows/shipwright-dispatch.yml",
      "Scan and dispatch shipwright-labeled issues",
    ),
    "inline",
  );
  const composite = writesOf(
    [
      stepRun(".github/actions/dispatch-pipeline/action.yml", "Post the dispatch marker"),
      stepRun(".github/actions/dispatch-pipeline/action.yml", "Dispatch the pipeline"),
    ].join("\n"),
    "printf",
  );
  expect(composite).toEqual(inline);
  expect(inline.commentIssue).toBe("ID");
  expect(inline.commentRepo).toBe("REPO");
  expect(inline.template).toBe("standard");
  // The marker the bot reads: one line, whitespace removed for the comparison.
  expect(inline.body).toContain("<!--SHIPWRIGHT-DISPATCHED:run-request${REQUESTED_AT}-->");
});
