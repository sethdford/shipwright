import { join, resolve } from "node:path";
import { Glob } from "bun";
import { parse } from "yaml";

export const ROOT = resolve(import.meta.dir, "../..");
const RULES_DIR = "tools/arch/rules";
const RULE_TESTS_DIR = "tools/arch/rule-tests";

/** One ast-grep rule file in tools/arch/rules. */
export interface RuleDoc {
  readonly file: string;
  readonly id: string;
  readonly severity?: string;
  readonly message?: string;
  readonly files?: readonly string[];
  readonly ignores?: readonly string[];
  readonly metadata?: {
    readonly ratchet?: boolean;
    readonly owner?: string;
    readonly docs?: string;
    /** Why the rule's `files` match nothing yet (it guards against a file type appearing). */
    readonly preemptive?: string;
  };
}
/** One ast-grep rule-test file in tools/arch/rule-tests. */
export interface RuleTestDoc {
  readonly file: string;
  readonly id: string;
  readonly valid?: readonly string[];
  readonly invalid?: readonly string[];
}

async function loadDir<T>(dir: string, root: string): Promise<(T & { file: string })[]> {
  const out: (T & { file: string })[] = [];
  for await (const name of new Glob("*.{yml,yaml}").scan(join(root, dir))) {
    const file = `${dir}/${name}`;
    out.push({ ...(parse(await Bun.file(join(root, file)).text()) as T), file });
  }
  return out.sort((a, b) => a.file.localeCompare(b.file));
}

export const loadRules = (root = ROOT) => loadDir<RuleDoc>(RULES_DIR, root);
export const loadRuleTests = (root = ROOT) => loadDir<RuleTestDoc>(RULE_TESTS_DIR, root);

/** Ratcheted rules are off for plain `ast-grep scan`; tools/arch/ast-scan.ts counts them. */
export const isRatcheted = (r: RuleDoc): boolean =>
  r.severity === "off" && r.metadata?.ratchet === true;

/**
 * Files git knows about: tracked plus untracked-but-not-ignored, minus deleted ones. Scans use this
 * list instead of walking directories, so .gitignore/.ignore files cannot hide a tracked file.
 */
export async function trackedFiles(root = ROOT): Promise<string[]> {
  const proc = Bun.spawnSync(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"],
    { cwd: root },
  );
  if (proc.exitCode !== 0) throw new Error(`git ls-files failed: ${proc.stderr.toString()}`);
  const names = proc.stdout.toString().split("\0").filter(Boolean);
  const present = await Promise.all(names.map((f) => Bun.file(join(root, f)).exists()));
  return names.filter((_, i) => present[i]).sort();
}
