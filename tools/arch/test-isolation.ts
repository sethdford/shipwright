import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, trackedFiles } from "./rule-catalog";

/**
 * Test isolation rule (#8648). Every bash suite (`scripts/*-test.sh`, which includes
 * `scripts/sw-lib-*-test.sh`) must call `sw_test_isolate` before any EXIT trap is set, so a suite run
 * directly cannot reach the developer's tmux server, HOME or process tree:
 * - the call `sw_test_isolate` must exist on its own line;
 * - every EXIT trap must be `trap '<cleanup>; sw_test_teardown' EXIT`, because bash keeps one trap per
 *   signal and the teardown kills the suite's processes and private tmux server;
 * - no EXIT trap may come before the isolation call.
 * Error severity, no baseline. Suites that cannot use the harness still source lib/test-isolate.sh.
 */
export const SUITE_GLOBS = ["scripts/*-test.sh", "scripts/sw-lib-*-test.sh"];
const ISOLATE_CALL = /^sw_test_isolate\s*$/;
const EXIT_TRAP = /^\s*trap\s.*\bEXIT\s*$/;
const TEARDOWN = /;\s*sw_test_teardown'\s+EXIT\s*$/;

export function findIsolationViolations(file: string, text: string): string[] {
  const lines = text.split("\n");
  const isolateAt = lines.findIndex((l) => ISOLATE_CALL.test(l));
  const out: string[] = [];
  if (isolateAt === -1) {
    out.push(
      `TEST-ISOLATION ${file} — add \`sw_test_isolate\` on its own line right after the harness is sourced (#8648).`,
    );
  }
  lines.forEach((line, i) => {
    if (!EXIT_TRAP.test(line)) return;
    if (!TEARDOWN.test(line)) {
      out.push(
        `TEST-ISOLATION ${file}:${i + 1} — EXIT trap must end with the teardown: trap '<cleanup>; sw_test_teardown' EXIT (#8648).`,
      );
    }
    if (isolateAt !== -1 && i < isolateAt) {
      out.push(
        `TEST-ISOLATION ${file}:${i + 1} — move \`sw_test_isolate\` above this EXIT trap so the trap is not replaced (#8648).`,
      );
    }
  });
  return out;
}

export async function scan(root = ROOT): Promise<string[]> {
  const files = (await trackedFiles(root)).filter((f) =>
    SUITE_GLOBS.some((g) => new Bun.Glob(g).match(f)),
  );
  return files.flatMap((f) => findIsolationViolations(f, readFileSync(join(root, f), "utf8")));
}

if (import.meta.main) {
  const found = await scan();
  for (const f of found) console.error(f);
  process.exit(found.length ? 1 : 0);
}
