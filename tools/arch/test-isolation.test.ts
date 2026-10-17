import { expect, test } from "bun:test";
import { findIsolationViolations, scan } from "./test-isolation";

const f = "scripts/x-test.sh";
const ok = (text: string) => expect(findIsolationViolations(f, text)).toEqual([]);
const bad = (text: string, needle: string) => {
  const found = findIsolationViolations(f, text);
  expect(found.some((m) => m.includes(needle))).toBe(true);
};

const good = [
  "#!/usr/bin/env bash",
  'source "$SCRIPT_DIR/lib/test-helpers.sh"',
  "sw_test_isolate",
  "trap 'cleanup_test_env; sw_test_teardown' EXIT",
].join("\n");

test("a suite that isolates before its EXIT trap passes", () => ok(good));

test("a suite without the isolation call is flagged", () => {
  bad(good.replace("sw_test_isolate\n", ""), "add `sw_test_isolate`");
});

test("an EXIT trap without the teardown is flagged", () => {
  bad(good.replace("cleanup_test_env; sw_test_teardown", "cleanup_test_env"), "sw_test_teardown");
});

test("an EXIT trap set before the isolation call is flagged", () => {
  bad("trap 'cleanup; sw_test_teardown' EXIT\nsw_test_isolate", "move `sw_test_isolate`");
});

test("multi-signal traps that include EXIT are checked", () => {
  ok("sw_test_isolate\ntrap 'cleanup; sw_test_teardown' EXIT INT TERM");
  bad("sw_test_isolate\ntrap cleanup EXIT INT TERM", "sw_test_teardown");
});

test("trap x 0 is an EXIT trap", () => {
  ok("sw_test_isolate\ntrap 'cleanup; sw_test_teardown' 0");
  bad("sw_test_isolate\ntrap cleanup 0", "sw_test_teardown");
  bad("trap cleanup 0\nsw_test_isolate", "move `sw_test_isolate`");
});

test("a trailing comment does not count as the teardown", () => {
  ok("sw_test_isolate\ntrap 'cleanup; sw_test_teardown' EXIT  # teardown runs here");
  bad("sw_test_isolate\ntrap cleanup EXIT # sw_test_teardown", "sw_test_teardown");
});

test("a continued trap line is joined before it is checked", () => {
  ok("sw_test_isolate\ntrap 'cleanup; \\\n  sw_test_teardown' EXIT");
  bad("sw_test_isolate\ntrap 'cleanup; \\\n  true' EXIT", "sw_test_teardown");
});

test("resetting the EXIT trap is flagged", () => {
  bad("sw_test_isolate\ntrap - EXIT", "do not reset");
});

test("an isolation call inside a heredoc does not count", () => {
  bad(
    "cat <<'EOF'\nsw_test_isolate\nEOF\ntrap 'cleanup; sw_test_teardown' EXIT",
    "add `sw_test_isolate`",
  );
});

test("an isolation call after a top-level exit is unreachable", () => {
  bad("exit 0\nsw_test_isolate\ntrap 'cleanup; sw_test_teardown' EXIT", "unreachable");
});

test("an isolation call only inside a function nothing calls is unreachable", () => {
  bad("setup() {\n  sw_test_isolate\n}\ntrap 'cleanup; sw_test_teardown' EXIT", "unreachable");
});

test("an isolation call in a function that the suite calls is reachable", () => {
  ok("setup() {\n  sw_test_isolate\n}\nsetup\ntrap 'cleanup; sw_test_teardown' EXIT");
});

test("an exit inside an if block is conditional and does not make the call unreachable", () => {
  ok(
    "if [[ -n \"${X:-}\" ]]; then\n  exit 0\nfi\nsw_test_isolate\ntrap 'cleanup; sw_test_teardown' EXIT",
  );
});

test("every bash suite in the repo calls sw_test_isolate", async () => {
  expect(await scan()).toEqual([]);
});
