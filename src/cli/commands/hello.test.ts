import { describe, expect, test } from "bun:test";
import { commandContext } from "../../testing/cli-harness";
import type { CliIO } from "../command";
import { helloCommand } from "./hello";

function capture(): CliIO & { out_: string[]; err_: string[] } {
  const out_: string[] = [];
  const err_: string[] = [];
  return { out_, err_, out: (t) => out_.push(t), err: (t) => err_.push(t) };
}

describe("hello", () => {
  test("prints hello world and exits 0", async () => {
    const io = capture();
    expect(await helloCommand.run([], commandContext(io))).toBe(0);
    expect(io.out_).toEqual(["hello world"]);
  });

  test.each([["--help"], ["-h"]])("%s prints usage", async (flag) => {
    const io = capture();
    expect(await helloCommand.run([flag], commandContext(io))).toBe(0);
    expect(io.out_.join("\n")).toContain("USAGE\n  shipwright hello [OPTIONS]");
  });

  test.each([["--version"], ["-v"]])("%s prints the version", async (flag) => {
    const io = capture();
    expect(await helloCommand.run([flag], commandContext(io))).toBe(0);
    expect(io.out_).toEqual(["4.0.0"]);
  });

  test("unknown option errors to stderr, prints usage, exits 1", async () => {
    const io = capture();
    expect(await helloCommand.run(["--invalid"], commandContext(io))).toBe(1);
    expect(io.err_).toEqual(["✗ Unknown option: --invalid"]);
    expect(io.out_.join("\n")).toContain("USAGE");
  });
});
