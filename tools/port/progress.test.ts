import { expect, test } from "bun:test";
import { CONTEXTS, type Context, contextFor } from "./contexts";
import { ProgressEntry, parseRouter } from "./progress";

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

test("merges aliases when a command repeats, collapsing deploy/deploys", () => {
  const text = `
        deploy|deploys)   exec "$SCRIPT_DIR/sw-github-deploy.sh" "$@" ;;
        strategic)    exec "$SCRIPT_DIR/sw-strategic.sh" "$@" ;;
        release-manager)  exec "$SCRIPT_DIR/sw-release-manager.sh" "$@" ;;
        strategic|strategy)
            exec "$SCRIPT_DIR/sw-strategic.sh" "$@"
            ;;
        release-manager|rm)
            exec "$SCRIPT_DIR/sw-release-manager.sh" "$@"
            ;;
        deploys|deployments)
            exec "$SCRIPT_DIR/sw-github-deploy.sh" "$@"
            ;;`;
  expect(parseRouter(text)).toEqual([
    { command: "deploy", aliases: ["deploys", "deployments"], script: "sw-github-deploy.sh" },
    { command: "strategic", aliases: ["strategy"], script: "sw-strategic.sh" },
    { command: "release-manager", aliases: ["rm"], script: "sw-release-manager.sh" },
  ]);
});

test("a repeated identical entry does not duplicate aliases", () => {
  const text = `
        a|b)  exec "$SCRIPT_DIR/sw-a.sh" "$@" ;;
        a|b)  exec "$SCRIPT_DIR/sw-a.sh" "$@" ;;`;
  expect(parseRouter(text)).toEqual([{ command: "a", aliases: ["b"], script: "sw-a.sh" }]);
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

const EXPECTED: [string, Context][] = [
  ["sw-standup.sh", "teams"],
  ["sw-autonomous.sh", "orchestration"],
  ["sw-incident.sh", "orchestration"],
  ["sw-context.sh", "delivery"],
  ["sw-decide.sh", "intelligence"],
  ["sw-e2e-orchestrator.sh", "quality"],
];
test.each(EXPECTED)("%s belongs to %s", (script, context) => {
  expect(contextFor(script)).toBe(context);
});

test("every rule targets a known context", () => {
  for (const script of ["sw-status.sh", "sw-loop.sh", "sw-daemon.sh", "sw-pm.sh"]) {
    expect(CONTEXTS).toContain(contextFor(script));
  }
});

test("progress entries reject unknown contexts and extra keys", () => {
  const ok = {
    command: "a",
    aliases: [],
    script: "sw-a.sh",
    context: "platform",
    parity: null,
    status: "bash",
  };
  expect(ProgressEntry.safeParse(ok).success).toBe(true);
  expect(ProgressEntry.safeParse({ ...ok, context: "nope" }).success).toBe(false);
  expect(ProgressEntry.safeParse({ ...ok, extra: 1 }).success).toBe(false);
});

test("pipeline-vitals is observability, not delivery", () => {
  expect(contextFor("sw-pipeline-vitals.sh")).toBe("observability");
});
