/**
 * How to run one acceptance test file. A template is an argv array (never a shell string)
 * with placeholders: {file} (repository path), {dir} ("./" + its directory, for `go test`)
 * and {stem} (file name without extension, for `cargo test --test`).
 *
 * Sources, most trusted first: the operator's configured template, a template derived from
 * the project's own test command, then the template the test writer proposed (checked
 * against a list of known test runners).
 */
export type RunTemplate = readonly string[];

export type TemplateSource = "configured" | "derived" | "proposed";

const PLACEHOLDER = /\{(file|dir|stem)\}/;
const SHELL_META = /[|&;<>()$`"'\\*?!{}[\]]/;

const RUNNERS = new Set([
  "bun",
  "npx",
  "pnpm",
  "yarn",
  "npm",
  "node",
  "deno",
  "pytest",
  "python",
  "python3",
  "go",
  "cargo",
  "jest",
  "vitest",
  "mocha",
  "rspec",
  "bundle",
  "mix",
  "dotnet",
  "mvn",
  "gradle",
  "./gradlew",
  "phpunit",
  "vendor/bin/phpunit",
  "bash",
]);
const EVAL_FLAGS = new Set(["-e", "-c", "--eval", "-p", "--print", "-r", "--require", "--import"]);

/** The argv for one file. */
export function renderRun(template: RunTemplate, path: string): readonly string[] {
  const slash = path.lastIndexOf("/");
  const dir = slash < 0 ? "." : `./${path.slice(0, slash)}`;
  const base = path.slice(slash + 1);
  const dot = base.indexOf(".");
  const stem = dot <= 0 ? base : base.slice(0, dot);
  return template.map((arg) =>
    arg.replaceAll("{file}", path).replaceAll("{dir}", dir).replaceAll("{stem}", stem),
  );
}

/** A proposed or configured template is usable when it names a known runner and a placeholder. */
export function templateProblem(template: RunTemplate): string | null {
  const [program] = template;
  if (program === undefined) return "empty command";
  if (!RUNNERS.has(program)) return `${program} is not a known test runner`;
  if (!template.some((a) => PLACEHOLDER.test(a)))
    return "command never names the test file ({file})";
  if (template.some((a) => EVAL_FLAGS.has(a))) return "command evaluates inline code";
  return null;
}

/**
 * A per-file template from the project's test command, or null when the command's shape is not
 * known (the caller then falls back to a proposed template). Only plain words are accepted: a
 * command with quotes, pipes or variables is not split.
 */
export function deriveTemplate(testCmd: string): RunTemplate | null {
  const words = testCmd
    .trim()
    .split(/\s+/)
    .filter((w) => w.length > 0);
  if (words.length === 0 || words.some((w) => SHELL_META.test(w))) return null;
  const [a, b, c] = words;
  if (a === "go" && b === "test") return ["go", "test", "-count=1", "{dir}"];
  if (a === "cargo" && b === "test") return ["cargo", "test", "--test", "{stem}"];
  if (a === "npm" && (b === "test" || (b === "run" && c === "test"))) {
    return [...words.filter((w) => w !== "--"), "--", "{file}"];
  }
  if (isFileRunner(words)) return [...withoutPathArgs(words), "{file}"];
  return null;
}

/** Drops positional path arguments (`bun test ./src`), so the run covers only the one file. */
function withoutPathArgs(words: readonly string[]): string[] {
  const kept: string[] = [];
  let flagValueNext = false;
  for (const w of words) {
    if (w.startsWith("-")) {
      kept.push(w);
      flagValueNext = !w.includes("=");
    } else if (flagValueNext || !(w.includes("/") || w.startsWith("."))) {
      kept.push(w);
      flagValueNext = false;
    }
  }
  return kept;
}

function isFileRunner(words: readonly string[]): boolean {
  const [a, b, c] = words;
  const tool = a === "npx" || a === "pnpm" || a === "yarn" || a === "bunx" ? b : a;
  if (a === "bun" && b === "test") return true;
  if (a === "bun" && b === "run" && c === "test") return false;
  if ((a === "python" || a === "python3") && b === "-m") return c === "pytest";
  if ((a === "pnpm" || a === "yarn") && b === "test") return true;
  if (tool === "vitest" || tool === "jest" || tool === "pytest" || tool === "mocha") return true;
  return a === "deno" && b === "test";
}

export type ChosenTemplate =
  | { readonly ok: true; readonly template: RunTemplate; readonly source: TemplateSource }
  | { readonly ok: false; readonly problem: string };

/** Picks the template to use, most trusted source first. */
export function chooseTemplate(input: {
  readonly configured?: RunTemplate | undefined;
  readonly testCmd?: string | undefined;
  readonly proposed?: RunTemplate | undefined;
}): ChosenTemplate {
  if (input.configured) {
    const problem = templateProblem(input.configured);
    if (problem) return { ok: false, problem: `configured acceptance command: ${problem}` };
    return { ok: true, template: input.configured, source: "configured" };
  }
  const derived = input.testCmd ? deriveTemplate(input.testCmd) : null;
  if (derived) return { ok: true, template: derived, source: "derived" };
  if (input.proposed) {
    const problem = templateProblem(input.proposed);
    if (problem) return { ok: false, problem: `proposed command: ${problem}` };
    return { ok: true, template: input.proposed, source: "proposed" };
  }
  return {
    ok: false,
    problem:
      "no way to run one test file: set acceptance.command (argv with {file}) or a test command shipwright recognizes",
  };
}
