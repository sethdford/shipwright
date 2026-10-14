import { expect, test } from "bun:test";
import { routerProblems } from "./check-router";
import type { ProgressEntry } from "./progress";

const entry = (command: string, status: ProgressEntry["status"]): ProgressEntry => ({
  command,
  aliases: [],
  script: `sw-${command}.sh`,
  context: "platform",
  parity: null,
  status,
});

const router = `hello)\n  exec bun "$SCRIPT_DIR/../src/cli.ts" hello "$@"\n;;`;

test("a TS-routed command must be parity-green or later", () => {
  expect(routerProblems(router, [entry("hello", "porting")])).toEqual([
    "hello is routed to TypeScript but its progress status is 'porting' (needs parity-green).",
  ]);
  expect(routerProblems(router, [entry("hello", "parity-green")])).toEqual([]);
});

test("a TS-routed command with no progress entry is a problem", () => {
  expect(routerProblems(router, [])).toEqual([
    "hello is routed to TypeScript but has no progress entry.",
  ]);
});

test("a bash-only router has no problems", () => {
  expect(routerProblems(`hello) exec "$SCRIPT_DIR/sw-hello.sh" "$@" ;;`, [])).toEqual([]);
});

test("the run_ts helper form counts as a TypeScript route", () => {
  const helperRouter = `hello) run_ts hello "$@" ;;`;
  expect(routerProblems(helperRouter, [entry("hello", "porting")])).toEqual([
    "hello is routed to TypeScript but its progress status is 'porting' (needs parity-green).",
  ]);
  expect(routerProblems(helperRouter, [entry("hello", "parity-green")])).toEqual([]);
  expect(routerProblems(helperRouter, [])).toEqual([
    "hello is routed to TypeScript but has no progress entry.",
  ]);
});

test("the run_ts function definition is not mistaken for a route", () => {
  expect(routerProblems(`run_ts() { exec bun "$SCRIPT_DIR/../src/cli.ts" "$@"; }`, [])).toEqual([]);
});

test.each([
  ["run_ts with a double-quoted name", `hello) run_ts "hello" "$@" ;;`],
  ["run_ts with a single-quoted name", `hello) run_ts 'hello' "$@" ;;`],
  [
    "inline bun with a braced SCRIPT_DIR",
    `hello) exec bun "\${SCRIPT_DIR}/../src/cli.ts" hello "$@" ;;`,
  ],
  [
    "inline bun with unquoted $SCRIPT_DIR",
    `hello) exec bun $SCRIPT_DIR/../src/cli.ts hello "$@" ;;`,
  ],
  ["inline bun with a quoted name", `hello) exec bun "$SCRIPT_DIR/../src/cli.ts" "hello" "$@" ;;`],
])("%s counts as a TypeScript route", (_label, line) => {
  expect(routerProblems(line, [entry("hello", "porting")])).toEqual([
    "hello is routed to TypeScript but its progress status is 'porting' (needs parity-green).",
  ]);
  expect(routerProblems(line, [entry("hello", "parity-green")])).toEqual([]);
});

test.each([
  ["a variable command name", `*) run_ts "$cmd" "$@" ;;`],
  ["a bare run_ts call", `x) run_ts ;;`],
  [
    "an inline route with a variable name",
    `*) exec bun "$SCRIPT_DIR/../src/cli.ts" "$cmd" "$@" ;;`,
  ],
  ["a cli.ts path in another form", `x) exec bun ./src/cli.ts hello ;;`],
])("fails closed on %s", (_label, line) => {
  const problems = routerProblems(line, []);
  expect(problems).toHaveLength(1);
  expect(problems[0]).toStartWith("line 1: cannot parse the TypeScript route in: ");
});

test("comments and the run_ts definition body are not routes", () => {
  const router = [
    "# run_ts hello routes to src/cli.ts",
    "run_ts() {",
    "    command -v bun >/dev/null 2>&1 || {",
    `        echo "needs bun" >&2`,
    "    }",
    `    exec bun "$SCRIPT_DIR/../src/cli.ts" "$@"`,
    "}",
    `  # hello) run_ts "$x" ;;`,
  ].join("\n");
  expect(routerProblems(router, [])).toEqual([]);
});

test("a route after the run_ts definition is still checked", () => {
  const router = [
    "run_ts() {",
    `    exec bun "$SCRIPT_DIR/../src/cli.ts" "$@"`,
    "}",
    `hello) run_ts hello "$@" ;;`,
  ].join("\n");
  expect(routerProblems(router, [])).toEqual([
    "hello is routed to TypeScript but has no progress entry.",
  ]);
});
