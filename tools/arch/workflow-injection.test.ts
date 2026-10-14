import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findInjections, scan } from "./workflow-injection";

/** Builds a GitHub expression without a literal template placeholder in source. */
const x = (expr: string) => `$\{{ ${expr} }}`;

const wf = `
jobs:
  triage:
    steps:
      - name: Vet
        env:
          TITLE: ${x("steps.issue.outputs.title")}
        run: echo "$TITLE"
      - name: Bad
        run: |
          REASON="${x("steps.triage.outputs.reason")}"
          echo "${x("github.event.issue.title")}"
      - name: Fine
        run: echo "$GITHUB_EVENT_NAME"
`;

test("flags expressions inside run blocks, not inside env", () => {
  expect(findInjections("wf.yml", wf)).toEqual([
    `wf.yml:triage:Bad:${x("steps.triage.outputs.reason")}`,
    `wf.yml:triage:Bad:${x("github.event.issue.title")}`,
  ]);
});

test("flags ANY expression in a run script, even a seemingly safe one", () => {
  const text = `
jobs:
  j:
    steps:
      - name: Safe-looking
        run: echo ${x("github.run_id")}
      - name: Inputs
        run: echo "${x("inputs.name")}"
      - name: Compact
        run: echo ${"$"}{{github.sha}}
`;
  expect(findInjections("wf.yml", text)).toEqual([
    `wf.yml:j:Safe-looking:${x("github.run_id")}`,
    `wf.yml:j:Inputs:${x("inputs.name")}`,
    `wf.yml:j:Compact:${"$"}{{github.sha}}`,
  ]);
});

test("scans composite actions (runs.steps[].run)", () => {
  const action = `
runs:
  using: composite
  steps:
    - name: Bad
      shell: bash
      run: echo "${x("github.event.comment.body")}"
`;
  expect(findInjections(".github/actions/x/action.yml", action)).toEqual([
    `.github/actions/x/action.yml:action:Bad:${x("github.event.comment.body")}`,
  ]);
});

test("flags expressions in actions/github-script with.script", () => {
  const text = `
jobs:
  j:
    steps:
      - name: Script
        uses: actions/github-script@v7
        with:
          script: |
            const t = "${x("github.run_id")}";
      - name: Safe script
        uses: actions/github-script@v7
        with:
          script: core.info(process.env.TITLE)
        env:
          TITLE: ${x("github.event.issue.title")}
`;
  expect(findInjections("wf.yml", text)).toEqual([`wf.yml:j:Script:${x("github.run_id")}`]);
});

test("expressions in env, with (non-script) and if are allowed", () => {
  const text = `
jobs:
  j:
    steps:
      - name: Ok
        if: ${x("github.event_name == 'push'")}
        uses: actions/checkout@v4
        with:
          ref: ${x("github.sha")}
        env:
          A: ${x("github.run_id")}
        run: echo "$A"
`;
  expect(findInjections("wf.yml", text)).toEqual([]);
});

test("malformed YAML is reported, not thrown", () => {
  expect(findInjections("bad.yml", "jobs: [unclosed\n  - : :\n")).toEqual([
    "bad.yml: unparseable YAML",
  ]);
});

test("empty or non-mapping documents yield no findings", () => {
  expect(findInjections("e.yml", "")).toEqual([]);
  expect(findInjections("s.yml", "just a string")).toEqual([]);
});

test("scan finds .yml, .yaml and composite action files inside the .github dot-dir", async () => {
  const root = mkdtempSync(join(tmpdir(), "wfi-"));
  mkdirSync(join(root, ".github/workflows"), { recursive: true });
  mkdirSync(join(root, ".github/actions/a/b"), { recursive: true });
  const bad = (name: string) =>
    `jobs:\n  j:\n    steps:\n      - name: ${name}\n        run: echo "${x("github.run_id")}"\n`;
  writeFileSync(join(root, ".github/workflows/one.yml"), bad("one"));
  writeFileSync(join(root, ".github/workflows/two.yaml"), bad("two"));
  writeFileSync(
    join(root, ".github/actions/a/b/action.yaml"),
    `runs:\n  using: composite\n  steps:\n    - name: three\n      shell: bash\n      run: echo "${x("github.run_id")}"\n`,
  );
  expect((await scan(root)).sort()).toEqual([
    `.github/actions/a/b/action.yaml:action:three:${x("github.run_id")}`,
    `.github/workflows/one.yml:j:one:${x("github.run_id")}`,
    `.github/workflows/two.yaml:j:two:${x("github.run_id")}`,
  ]);
});
