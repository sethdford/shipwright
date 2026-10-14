import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findInjections, scan } from "./workflow-injection";

const wf = `
jobs:
  triage:
    steps:
      - name: Vet
        env:
          TITLE: \${{ steps.issue.outputs.title }}
        run: echo "$TITLE"
      - name: Bad
        run: |
          REASON="\${{ steps.triage.outputs.reason }}"
          echo "\${{ github.event.issue.title }}"
      - name: Fine
        run: echo "\${{ github.event_name }}"
`;

test("flags untrusted expressions inside run blocks, not inside env", () => {
  expect(findInjections("wf.yml", wf)).toEqual([
    "wf.yml:triage:Bad:${{ steps.triage.outputs.reason }}",
    "wf.yml:triage:Bad:${{ github.event.issue.title }}",
  ]);
});

test("scans composite actions (runs.steps[].run)", () => {
  const action = `
runs:
  using: composite
  steps:
    - name: Bad
      shell: bash
      run: echo "\${{ github.event.comment.body }}"
`;
  expect(findInjections(".github/actions/x/action.yml", action)).toEqual([
    ".github/actions/x/action.yml:action:Bad:${{ github.event.comment.body }}",
  ]);
});

test("flags untrusted expressions in actions/github-script with.script", () => {
  const text = `
jobs:
  j:
    steps:
      - name: Script
        uses: actions/github-script@v7
        with:
          script: |
            const t = "\${{ github.event.issue.title }}";
      - name: Safe script
        uses: actions/github-script@v7
        with:
          script: core.info(process.env.TITLE)
        env:
          TITLE: \${{ github.event.issue.title }}
`;
  expect(findInjections("wf.yml", text)).toEqual([
    "wf.yml:j:Script:${{ github.event.issue.title }}",
  ]);
});

test("flags workflow_run and head_commit attacker-controlled fields", () => {
  const text = `
jobs:
  j:
    steps:
      - name: A
        run: |
          echo "\${{ github.event.workflow_run.head_branch }}"
          echo "\${{ github.event.workflow_run.head_commit.message }}"
          echo "\${{ github.event.workflow_run.display_title }}"
          echo "\${{ github.event.head_commit.message }}"
          echo "\${{ github.head_ref }}"
`;
  expect(findInjections("wf.yml", text)).toHaveLength(5);
});

test("does not flag inputs.* (known gap)", () => {
  const text = `
jobs:
  j:
    steps:
      - name: A
        run: echo "\${{ inputs.name }}"
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
    `jobs:\n  j:\n    steps:\n      - name: ${name}\n        run: echo "\${{ github.event.issue.title }}"\n`;
  writeFileSync(join(root, ".github/workflows/one.yml"), bad("one"));
  writeFileSync(join(root, ".github/workflows/two.yaml"), bad("two"));
  writeFileSync(
    join(root, ".github/actions/a/b/action.yaml"),
    'runs:\n  using: composite\n  steps:\n    - name: three\n      shell: bash\n      run: echo "${{ github.event.issue.title }}"\n',
  );
  const found = (await scan(root)).sort();
  expect(found).toEqual([
    ".github/actions/a/b/action.yaml:action:three:${{ github.event.issue.title }}",
    ".github/workflows/one.yml:j:one:${{ github.event.issue.title }}",
    ".github/workflows/two.yaml:j:two:${{ github.event.issue.title }}",
  ]);
});
