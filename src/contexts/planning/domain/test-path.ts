/**
 * Where an acceptance test may be written. Paths come from model output, so they are checked
 * before anything touches the disk: relative, inside the repository, outside tool and CI
 * directories, and named like a test so the project's runner (and the integrity guard) see it as one.
 */

const FORBIDDEN_ROOTS = [".git", ".github", ".claude", ".shipwright", "node_modules"];

const TEST_NAME = [
  /(^|\/)(tests?|__tests__|spec|specs)\//i,
  /\.(test|spec)\.[cm]?[jt]sx?$/i,
  /(^|\/)test_[^/]+\.py$/i,
  /_test\.(py|go|rb|exs)$/i,
  /_spec\.rb$/i,
  /Tests?\.(java|kt|cs|swift)$/,
  /-test\.sh$/,
];

export type PathProblem = "empty" | "absolute" | "traversal" | "forbidden_root" | "not_a_test";

/** Why `path` cannot hold an acceptance test, or null when it can. */
export function testPathProblem(path: string): PathProblem | null {
  if (path.length === 0 || path.length > 300) return "empty";
  if (path.startsWith("/") || path.startsWith("~") || /^[A-Za-z]:/.test(path)) return "absolute";
  if (path.includes("\\") || path.includes("\0")) return "traversal";
  const parts = path.split("/");
  if (parts.some((p) => p === ".." || p === "." || p === "")) return "traversal";
  if (FORBIDDEN_ROOTS.includes(parts[0] ?? "")) return "forbidden_root";
  if (!isTestPath(path)) return "not_a_test";
  return null;
}

/** True when a repository path is named like a test file in any of the common conventions. */
export function isTestPath(path: string): boolean {
  return TEST_NAME.some((re) => re.test(path));
}

const TEST_CONFIG = [
  /(^|\/)(jest|vitest|vite|playwright|cypress|karma|ava|mocha)\.config\.[cm]?[jt]s$/,
  /(^|\/)\.mocharc(\.\w+)?$/,
  /(^|\/)(pytest\.ini|tox\.ini|conftest\.py|setup\.cfg|bunfig\.toml|phpunit\.xml(\.dist)?|\.rspec)$/,
];

/** True for files that decide which tests run (a change there can silently drop tests). */
export function isTestConfigPath(path: string): boolean {
  return TEST_CONFIG.some((re) => re.test(path));
}
