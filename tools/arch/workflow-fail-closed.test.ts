import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findFailOpen, scan } from "./workflow-fail-closed";

const step = (run: string, shell = "bash") =>
  `jobs:\n  j:\n    steps:\n      - name: S\n        shell: ${shell}\n        run: |\n${run
    .split("\n")
    .map((l) => `          ${l}`)
    .join("\n")}\n`;

test("the required bot-comments pattern passes", () => {
  const ok = step(
    [
      'if ! COMMENTS_JSON=$(scripts/ci/bot-comments.sh "$ISSUE_NUMBER"); then',
      '  echo "::error::cannot read bot comments; refusing to retry"; exit 1',
      "fi",
      "jq -r '.[].body' <<<\"$COMMENTS_JSON\"",
      'if ! STATE=$(scripts/ci/retry-state.sh "$ISSUE_NUMBER" "$RUN_ID"); then exit 1; fi',
    ].join("\n"),
  );
  expect(findFailOpen("wf.yml", ok)).toEqual([]);
});

test("bot-comments.sh piped, ||-defaulted or with stderr discarded is flagged", () => {
  const bad = step(
    [
      'C=$(scripts/ci/bot-comments.sh "$I" | jq -c ".[]")',
      'C=$(scripts/ci/bot-comments.sh "$I" || echo "")',
      'C=$(scripts/ci/bot-comments.sh "$I" 2>/dev/null)',
      'C=$(scripts/ci/bot-comments.sh "$I" 2> /dev/null)',
      'C=$(scripts/ci/bot-comments.sh "$I" &>/dev/null)',
      'S=$(scripts/ci/retry-state.sh "$I" "$R" || echo "{}")',
    ].join("\n"),
  );
  const found = findFailOpen("wf.yml", bad);
  expect(found).toHaveLength(6);
  expect(found[0]).toStartWith("wf.yml:7: ");
  expect(found[0]).toContain("bot-comments.sh");
});

test("a pipe on a continuation line is still the same invocation", () => {
  const bad = step(['C=$(scripts/ci/bot-comments.sh "$I" \\', '  | jq -c ".[]")'].join("\n"));
  expect(findFailOpen("wf.yml", bad)).toHaveLength(1);
});

test("a pipe BEFORE bot-comments.sh is not its output being swallowed", () => {
  expect(
    findFailOpen("wf.yml", step('echo 1 | true; X=$(scripts/ci/bot-comments.sh "$I")')),
  ).toEqual([]);
});

test("gates check passes in an if, fails with --no-github, || or 2>/dev/null", () => {
  expect(
    findFailOpen("wf.yml", step("if ! bun src/cli.ts gates check --retry 0; then exit 1; fi")),
  ).toEqual([]);
  const bad = step(
    [
      "bun src/cli.ts gates check --retry 0 --no-github",
      "bun src/cli.ts gates check --retry 0 || true",
      "bun src/cli.ts gates check --retry 0 2>/dev/null",
    ].join("\n"),
  );
  expect(findFailOpen("wf.yml", bad)).toHaveLength(3);
});

test("gate and marker steps must run under shell: bash (-eo pipefail)", () => {
  const noShell = `jobs:\n  j:\n    steps:\n      - name: Gate\n        run: if ! bun src/cli.ts gates check --retry 0; then exit 1; fi\n`;
  expect(findFailOpen("wf.yml", noShell)).toEqual([
    "wf.yml:j:Gate: invokes gates check / bot-comments.sh / retry-state.sh without shell: bash",
  ]);
  expect(
    findFailOpen("wf.yml", step('X=$(scripts/ci/bot-comments.sh "$I") || exit 1', "sh")),
  ).toHaveLength(2);
  const jobDefault = `jobs:\n  j:\n    defaults:\n      run:\n        shell: bash\n    steps:\n      - name: Gate\n        run: if ! bun src/cli.ts gates check --retry 0; then exit 1; fi\n`;
  expect(findFailOpen("wf.yml", jobDefault)).toEqual([]);
  const wfDefault = `defaults:\n  run:\n    shell: bash\njobs:\n  j:\n    steps:\n      - name: Gate\n        run: if ! bun src/cli.ts gates check --retry 0; then exit 1; fi\n`;
  expect(findFailOpen("wf.yml", wfDefault)).toEqual([]);
});

test("composite action steps are checked", () => {
  const action = `runs:\n  using: composite\n  steps:\n    - name: Gate\n      shell: sh\n      run: bun src/cli.ts gates check --retry "$RETRY" || true\n`;
  expect(findFailOpen("action.yml", action)).toHaveLength(2);
});

test("unrelated steps and unparseable YAML", () => {
  expect(findFailOpen("wf.yml", step("echo hi | tee x 2>/dev/null || true", "sh"))).toEqual([]);
  expect(findFailOpen("bad.yml", "jobs: [unclosed\n  - : :\n")).toEqual([
    "bad.yml: unparseable YAML",
  ]);
});

test("scan covers workflows and every file under .github/actions", async () => {
  const root = mkdtempSync(join(tmpdir(), "wfc-"));
  mkdirSync(join(root, ".github/workflows"), { recursive: true });
  mkdirSync(join(root, ".github/actions/a"), { recursive: true });
  writeFileSync(
    join(root, ".github/workflows/w.yml"),
    step('X=$(scripts/ci/bot-comments.sh "$I" | jq .)'),
  );
  writeFileSync(
    join(root, ".github/actions/a/run.sh"),
    "bun src/cli.ts gates check --retry 0 || true\n",
  );
  const found = await scan(root);
  expect(found.map((f) => f.split(":")[0]).sort()).toEqual([
    ".github/actions/a/run.sh",
    ".github/workflows/w.yml",
  ]);
});
