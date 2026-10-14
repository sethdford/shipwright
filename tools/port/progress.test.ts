import { expect, test } from "bun:test";
import { contextFor } from "./contexts";
import { parseRouter } from "./progress";

const router = `
    case "$subcmd" in
        recruit)      exec "$SCRIPT_DIR/sw-recruit.sh" "$@" ;;
        security-audit|audit) exec "$SCRIPT_DIR/sw-security-audit.sh" "$@" ;;
        hello)
            exec "$SCRIPT_DIR/sw-hello.sh" "$@"
            ;;
    esac`;

test("parses single-line, aliased and multi-line router entries", () => {
  expect(parseRouter(router)).toEqual([
    { command: "recruit", aliases: [], script: "sw-recruit.sh" },
    { command: "security-audit", aliases: ["audit"], script: "sw-security-audit.sh" },
    { command: "hello", aliases: [], script: "sw-hello.sh" },
  ]);
});

test("finds the exec when guard calls sit between the label and the exec", () => {
  const text = `
        ps)
            check_tmux
            exec "$SCRIPT_DIR/sw-ps.sh" "$@"
            ;;
        other)
            echo hi
            ;;
        next)  exec "$SCRIPT_DIR/sw-next.sh" "$@" ;;`;
  expect(parseRouter(text).map((e) => [e.command, e.script])).toEqual([
    ["ps", "sw-ps.sh"],
    ["next", "sw-next.sh"],
  ]);
});

test("a one-line label without an exec does not steal the next entry's exec", () => {
  const text = `
        help)             echo "Usage"; exit 0 ;;
        ""|release)       exec "$SCRIPT_DIR/sw-release.sh" "$@" ;;`;
  expect(parseRouter(text)).toEqual([{ command: "release", aliases: [], script: "sw-release.sh" }]);
});

test("keeps two different commands that route to the same script", () => {
  const text = `
        status)  exec "$SCRIPT_DIR/sw-status.sh" "$@" ;;
        overview)  exec "$SCRIPT_DIR/sw-status.sh" "$@" ;;`;
  expect(parseRouter(text).map((e) => e.command)).toEqual(["status", "overview"]);
});

test("dedupes by command name, not by script", () => {
  const text = `
        a)  exec "$SCRIPT_DIR/sw-a.sh" "$@" ;;
        a)  exec "$SCRIPT_DIR/sw-a.sh" "$@" ;;`;
  expect(parseRouter(text)).toHaveLength(1);
});

test("accepts router lines that pass extra args to the script", () => {
  const text = `        sub)  exec "$SCRIPT_DIR/sw-x.sh" sub "$@" ;;`;
  expect(parseRouter(text)).toEqual([{ command: "sub", aliases: [], script: "sw-x.sh" }]);
});

test("maps scripts to bounded contexts", () => {
  expect(contextFor("sw-loop.sh")).toBe("delivery");
  expect(contextFor("sw-github-checks.sh")).toBe("integrations");
  expect(contextFor("sw-recruit.sh")).toBe("teams");
  expect(contextFor("sw-hello.sh")).toBe("platform");
});

test("pipeline-vitals is observability, not delivery", () => {
  expect(contextFor("sw-pipeline-vitals.sh")).toBe("observability");
});
