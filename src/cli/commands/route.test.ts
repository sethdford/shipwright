import { expect, test } from "bun:test";
import type { RoutingLog, RoutingPorts, RoutingRecord } from "../../contexts/intelligence";
import { ok } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { routeCommand } from "./route";

function setup(env: Record<string, string> = {}, files: Record<string, string> = {}) {
  const records: RoutingRecord[] = [];
  const log: RoutingLog = {
    read: async () => ok(records),
    append: async (r) => {
      records.push(r);
      return ok(undefined);
    },
  };
  const routing: RoutingPorts = { log, now: () => Date.UTC(2026, 10, 26) };
  const io = captureIO();
  const ctx = commandContext(io, undefined, env, new FakeFileReader(files), { routing });
  return { io, ctx, records };
}

test("decide --json prints the decision and logs it", async () => {
  const { io, ctx, records } = setup();
  const code = await routeCommand.run(
    ["decide", "--goal", "docs: fix typo", "--issue", "5", "--json"],
    ctx,
  );
  expect(code).toBe(0);
  const d = JSON.parse(io.outLines[0] ?? "{}");
  expect(d).toMatchObject({
    kind: "decision",
    issue: 5,
    mode: "shadow",
    applied: { model: "sonnet" },
  });
  expect(records).toHaveLength(1);
});

test("decide reads gh issue JSON with label objects, and SHIPWRIGHT_ROUTER sets the mode", async () => {
  const issue = JSON.stringify({ title: "Add thing", body: "", labels: [{ name: "size/L" }] });
  const { io, ctx } = setup({ SHIPWRIGHT_ROUTER: "apply" }, { "/i.json": issue });
  expect(await routeCommand.run(["decide", "--issue-json", "/i.json", "--json"], ctx)).toBe(0);
  const d = JSON.parse(io.outLines[0] ?? "{}");
  expect(d.mode).toBe("apply");
  expect(d.applied.attempts).toBe(3);
});

test("decide prints a readable route by default", async () => {
  const { io, ctx } = setup();
  expect(
    await routeCommand.run(["decide", "--goal", "docs: fix typo", "--remaining-usd", "0"], ctx),
  ).toBe(0);
  expect(io.outLines[0]).toContain("trivial");
  expect(io.outLines.join("\n")).toContain("action: defer");
});

test("bad input is a usage error", async () => {
  for (const args of [
    ["decide"],
    ["decide", "--goal", "x", "--issue-json", "/f"],
    ["decide", "--goal", "x", "--mode", "off"],
    ["decide", "--goal", "x", "--effort", "max"],
    ["decide", "--goal", "x", "--attempts", "0"],
    ["outcome", "--decision", "a", "--result", "maybe"],
    ["outcome", "--result", "success"],
    ["stats", "--bogus"],
    ["nope"],
  ]) {
    const { ctx } = setup();
    expect(await routeCommand.run(args, ctx)).toBe(2);
  }
});

test("outcome then stats", async () => {
  const { io, ctx } = setup();
  await routeCommand.run(["decide", "--goal", "docs: fix typo", "--json"], ctx);
  const id = JSON.parse(io.outLines[0] ?? "{}").id as string;
  expect(
    await routeCommand.run(
      ["outcome", "--decision", id, "--result", "success", "--cost-usd", "1.5", "--pr", "9"],
      ctx,
    ),
  ).toBe(0);
  expect(
    await routeCommand.run(["outcome", "--decision", "missing", "--result", "success"], ctx),
  ).toBe(1);
  expect(await routeCommand.run(["stats", "--json"], ctx)).toBe(0);
  const s = JSON.parse(io.outLines.at(-1) ?? "{}");
  expect(s.runs).toBe(1);
  expect(s.tiers[0]).toMatchObject({ tier: "trivial", costPerSuccessUsd: 1.5 });
});
