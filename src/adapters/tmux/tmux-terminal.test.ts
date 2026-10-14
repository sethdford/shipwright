import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { TmuxTerminal } from "./tmux-terminal";

const tmux = (exitCode: number, stdout: string, stderr = "", timedOut = false) =>
  new FakeProcessRunner([{ prefix: ["tmux"], result: { exitCode, stdout, stderr, timedOut } }]);

test("refuses to operate without an explicit socket name", () => {
  expect(() => new TmuxTerminal(tmux(0, ""), "")).toThrow(/socket/);
});

test("every command targets the private socket", async () => {
  const runner = tmux(0, "a\nb\n");
  const t = new TmuxTerminal(runner, "sw-test-x");
  expect(await t.listSessions()).toEqual({ ok: true, value: ["a", "b"] });
  await t.killSession("a");
  expect(runner.calls.every((c) => c.argv[1] === "-L" && c.argv[2] === "sw-test-x")).toBe(true);
});

test("killSession uses exact-name matching so it can never hit a prefix-matched session", async () => {
  const runner = tmux(0, "");
  expect(await new TmuxTerminal(runner, "s").killSession("claude-team")).toEqual({
    ok: true,
    value: undefined,
  });
  expect(runner.calls[0]?.argv).toEqual(["tmux", "-L", "s", "kill-session", "-t", "=claude-team"]);
});

test("no server running means no sessions, not a failure", async () => {
  const t = new TmuxTerminal(tmux(1, "", "no server running on /tmp/tmux-501/s\n"), "s");
  expect(await t.listSessions()).toEqual({ ok: true, value: [] });
});

test("killing an absent session is ok (idempotent)", async () => {
  const t = new TmuxTerminal(tmux(1, "", "can't find session: =x\n"), "s");
  expect(await t.killSession("x")).toEqual({ ok: true, value: undefined });
});

test("other failures are reported, so callers never mistake 'could not look' for 'nothing there'", async () => {
  const t = new TmuxTerminal(tmux(1, "", "protocol version mismatch\n"), "s");
  expect(await t.listSessions()).toEqual({
    ok: false,
    error: { kind: "failed", message: "protocol version mismatch" },
  });
});

test("a timeout is transient", async () => {
  const r = await new TmuxTerminal(tmux(143, "", "", true), "s").listSessions();
  expect(!r.ok && r.error.kind).toBe("transient");
});

test("a spawn failure is a failed error, not a rejection", async () => {
  const t = new TmuxTerminal(new FakeProcessRunner([]), "s");
  const l = await t.listSessions();
  const k = await t.killSession("x");
  expect(!l.ok && l.error.kind).toBe("failed");
  expect(!k.ok && k.error.kind).toBe("failed");
});

test("an unreachable socket (permission denied) is failed, not 'no server'", async () => {
  const stderr = "error connecting to /tmp/tmux-501/s (Permission denied)\n";
  const t = new TmuxTerminal(tmux(1, "", stderr), "s");
  const l = await t.listSessions();
  const k = await t.killSession("x");
  expect(!l.ok && l.error.kind).toBe("failed");
  expect(!k.ok && k.error.kind).toBe("failed");
});

test("a missing socket file means no server", async () => {
  const stderr = "error connecting to /tmp/tmux-501/s (No such file or directory)\n";
  const t = new TmuxTerminal(tmux(1, "", stderr), "s");
  expect(await t.listSessions()).toEqual({ ok: true, value: [] });
  expect(await t.killSession("x")).toEqual({ ok: true, value: undefined });
});

test("newSession passes name and cwd; failure is reported", async () => {
  const runner = tmux(0, "");
  expect(await new TmuxTerminal(runner, "s").newSession("n", "/w")).toEqual({
    ok: true,
    value: undefined,
  });
  expect(runner.calls[0]?.argv).toEqual([
    "tmux",
    "-L",
    "s",
    "new-session",
    "-d",
    "-s",
    "n",
    "-c",
    "/w",
  ]);
  const r = await new TmuxTerminal(tmux(1, "", "duplicate session: n\n"), "s").newSession(
    "n",
    "/w",
  );
  expect(r).toEqual({ ok: false, error: { kind: "failed", message: "duplicate session: n" } });
});

test("killSession with no server is ok", async () => {
  const t = new TmuxTerminal(tmux(1, "", "no server running on /tmp/tmux-501/s\n"), "s");
  expect(await t.killSession("x")).toEqual({ ok: true, value: undefined });
});

test("killSession timeout is transient", async () => {
  const r = await new TmuxTerminal(tmux(143, "", "", true), "s").killSession("x");
  expect(!r.ok && r.error.kind).toBe("transient");
});
