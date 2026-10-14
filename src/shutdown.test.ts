import { expect, test } from "bun:test";
import { installShutdown } from "./shutdown";

function fakes() {
  const signals: string[] = [];
  const handlers = new Map<string, () => void>();
  const exits: number[] = [];
  const proc = {
    on: (sig: string, fn: () => void) => void handlers.set(sig, fn),
    exit: (code: number) => void exits.push(code),
  };
  return { runner: { killAll: (s: string) => signals.push(s) }, proc, signals, handlers, exits };
}

test("SIGTERM kills children, waits the grace, then SIGKILLs and exits 143", async () => {
  const f = fakes();
  installShutdown(f.runner, f.proc, 10);
  f.handlers.get("SIGTERM")?.();
  expect(f.signals).toEqual(["SIGTERM"]);
  expect(f.exits).toEqual([]);
  await Bun.sleep(40);
  expect(f.signals).toEqual(["SIGTERM", "SIGKILL"]);
  expect(f.exits).toEqual([143]);
});

test("SIGINT exits 130, and a second signal does not repeat the shutdown", async () => {
  const f = fakes();
  installShutdown(f.runner, f.proc, 10);
  f.handlers.get("SIGINT")?.();
  f.handlers.get("SIGINT")?.();
  await Bun.sleep(40);
  expect(f.signals).toEqual(["SIGTERM", "SIGKILL"]);
  expect(f.exits).toEqual([130]);
});
