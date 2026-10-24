import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { TestEnv } from "./test-env";

// The real bash classify_failure (scripts/lib/daemon-failure.sh). Tests run it live, so a change in
// bash shows up as drift in classify-parity.test.ts instead of a stale recorded label.
const LIB = fileURLToPath(new URL("../../scripts/lib/daemon-failure.sh", import.meta.url));

// Fixed driver, written once per env. The texts are data in log files, never in a shell string.
const DRIVER = `#!/usr/bin/env bash
set -u
source "$1"
n="$2"
for ((i = 1; i <= n; i++)); do
  classify_failure "$i"
done
`;

/**
 * Writes each text to $LOG_DIR/issue-N.log inside the isolated env and returns bash's label for each.
 * Nothing touches the real HOME or ~/.shipwright: DAEMON_DIR, LOG_DIR and WORKTREE_DIR all live in env.root.
 */
export function bashClassifyAll(env: TestEnv, texts: readonly string[]): string[] {
  const logs = join(env.root, "logs");
  const work = join(env.root, "work");
  mkdirSync(logs, { recursive: true });
  mkdirSync(work, { recursive: true });
  texts.forEach((text, i) => {
    writeFileSync(join(logs, `issue-${i + 1}.log`), `${text}\n`);
  });
  const driver = join(work, "classify-all.sh");
  writeFileSync(driver, DRIVER);
  const proc = Bun.spawnSync(["bash", driver, LIB, String(texts.length)], {
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      HOME: env.home,
      LC_ALL: "C",
      LOG_DIR: logs,
      DAEMON_DIR: env.stateDir,
      WORKTREE_DIR: join(env.root, "wt"),
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  if (proc.exitCode !== 0) {
    throw new Error(
      `bash classify_failure failed (exit ${proc.exitCode}): ${proc.stderr.toString()}`,
    );
  }
  const labels = proc.stdout.toString().trimEnd().split("\n");
  if (labels.length !== texts.length) {
    throw new Error(`bash returned ${labels.length} labels for ${texts.length} texts`);
  }
  return labels;
}
