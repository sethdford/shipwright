import { expect, test } from "bun:test";
import { findIsolationViolations, scan } from "./test-isolation";

const good = [
  "#!/usr/bin/env bash",
  'source "$SCRIPT_DIR/lib/test-helpers.sh"',
  "sw_test_isolate",
  "trap 'cleanup_test_env; sw_test_teardown' EXIT",
].join("\n");

test("a suite that isolates before its EXIT trap passes", () => {
  expect(findIsolationViolations("scripts/x-test.sh", good)).toEqual([]);
});

test("a suite without the isolation call is flagged", () => {
  const bad = good.replace("sw_test_isolate\n", "");
  expect(findIsolationViolations("scripts/x-test.sh", bad)[0]).toContain("add `sw_test_isolate`");
});

test("an EXIT trap without the teardown is flagged", () => {
  const bad = good.replace("cleanup_test_env; sw_test_teardown", "cleanup_test_env");
  expect(findIsolationViolations("scripts/x-test.sh", bad)[0]).toContain("sw_test_teardown");
});

test("an EXIT trap set before the isolation call is flagged", () => {
  const bad = ["trap 'cleanup; sw_test_teardown' EXIT", "sw_test_isolate"].join("\n");
  expect(findIsolationViolations("scripts/x-test.sh", bad)[0]).toContain("move `sw_test_isolate`");
});

test("every bash suite in the repo calls sw_test_isolate", async () => {
  expect(await scan()).toEqual([]);
});
