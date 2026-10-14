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
