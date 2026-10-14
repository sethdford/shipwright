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
