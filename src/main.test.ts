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

test("top-level --version and -v print the package version", async () => {
  for (const flag of ["--version", "-v"]) {
    const c = io();
    expect(await main([flag], c.io)).toBe(0);
    expect(c.out).toEqual(["3.3.0"]);
  }
});

test.each([[[]], [["--help"]], [["-h"]]])(
  "top-level help %p lists commands and exits 0",
  async (argv) => {
    const c = io();
    expect(await main(argv, c.io)).toBe(0);
    const text = c.out.join("\n");
    expect(text.startsWith("USAGE\n  shipwright <command> [args]\n\nCOMMANDS")).toBe(true);
    expect(text).toContain("hello");
  },
);

const aliased: Command = {
  name: "status",
  aliases: ["st", "s"],
  summary: "shows status",
  usage: "",
  run: async (args, { io }) => {
    io.out(`status:${args.join(",")}`);
    return 0;
  },
};

test("dispatches by alias and forwards args", async () => {
  const c = io();
  expect(await main(["st", "a", "b"], c.io, [aliased])).toBe(0);
  expect(c.out).toEqual(["status:a,b"]);
});

test("help lists aliases when present", async () => {
  const c = io();
  await main([], c.io, [aliased]);
  expect(c.out.join("\n")).toContain("status (st, s)");
});

test("args are forwarded to the command", async () => {
  const c = io();
  expect(await main(["hello", "--version"], c.io)).toBe(0);
  expect(c.out).toEqual(["3.3.0"]);
});
