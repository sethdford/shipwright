import { expect, test } from "bun:test";
import type { Command } from "./cli/command";
import { main } from "./main";

function io() {
  const out: string[] = [];
  const err: string[] = [];
  return { out, err, io: { out: (t: string) => out.push(t), err: (t: string) => err.push(t) } };
}

test("dispatches to a command by name", async () => {
  const c = io();
  expect(await main(["hello"], c.io)).toBe(0);
  expect(c.out).toEqual(["hello world"]);
});

test("unknown command exits 2 with a message", async () => {
  const c = io();
  expect(await main(["nope"], c.io)).toBe(2);
  expect(c.err[0]).toBe("✗ Unknown command: nope");
});

const boom = (thrown: unknown): Command => ({
  name: "boom",
  aliases: [],
  summary: "throws",
  usage: "",
  run: async () => {
    throw thrown;
  },
});

test("a throwing command is reported on stderr and exits 1, never escaping main", async () => {
  const c = io();
  expect(await main(["boom"], c.io, [boom(new Error("kaput"))])).toBe(1);
  expect(c.err).toEqual(["✗ kaput"]);
});

test("a non-Error throw is still reported", async () => {
  const c = io();
  expect(await main(["boom"], c.io, [boom("oops")])).toBe(1);
  expect(c.err).toEqual(["✗ oops"]);
});
