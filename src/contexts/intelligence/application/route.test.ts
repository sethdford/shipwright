import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import type { RoutingRecord } from "../domain/records";
import type { RoutingLog, RoutingPorts } from "../ports";
import { loadRoutingStats, recordOutcome, routeIssue } from "./route";

function memoryLog(initial: RoutingRecord[] = []): RoutingLog & { records: RoutingRecord[] } {
  const records = [...initial];
  return {
    records,
    read: async () => ok(records),
    append: async (r) => {
      records.push(r);
      return ok(undefined);
    },
  };
}

const ports = (log: RoutingLog): RoutingPorts => ({ log, now: () => Date.UTC(2026, 10, 26) });
const issueText = { title: "docs: fix typo", body: "", labels: [] };

test("routeIssue appends the decision with an id and time from the ports", async () => {
  const log = memoryLog();
  const d = await routeIssue(ports(log), { issueText, mode: "shadow", issue: 42, overrides: {} });
  expect(d.ok).toBe(true);
  if (!d.ok) return;
  expect(d.value.id).toMatch(/^rt-[a-z0-9]+-[a-z0-9]+-42$/);
  expect(d.value.at).toBe("2026-11-26T00:00:00.000Z");
  expect(log.records).toEqual([d.value]);
});

test("history in the log escalates the next decision", async () => {
  const log = memoryLog();
  for (let i = 0; i < 3; i++) {
    const d = await routeIssue(ports(log), {
      issueText,
      mode: "shadow",
      issue: i + 1,
      overrides: {},
    });
    if (!d.ok) throw new Error("route failed");
    await recordOutcome(ports(log), {
      decisionId: d.value.id,
      result: "failure",
      failureClass: "execution",
    });
  }
  const next = await routeIssue(ports(log), { issueText, mode: "apply", overrides: {} });
  expect(next.ok && next.value.difficulty.tier).toBe("small");
});

test("an outcome for an unknown decision is refused", async () => {
  const r = await recordOutcome(ports(memoryLog()), { decisionId: "nope", result: "success" });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error.kind).toBe("not_found");
});

test("an unreadable log fails closed and writes nothing", async () => {
  const appended: RoutingRecord[] = [];
  const log: RoutingLog = {
    read: async () => err({ kind: "failed", message: "bad line" }),
    append: async (r) => {
      appended.push(r);
      return ok(undefined);
    },
  };
  expect((await routeIssue(ports(log), { issueText, mode: "shadow", overrides: {} })).ok).toBe(
    false,
  );
  expect((await loadRoutingStats(ports(log))).ok).toBe(false);
  expect(appended).toEqual([]);
});

test("a retry of an issue whose last run hit max_turns moves up a tier on its own", async () => {
  const log = memoryLog();
  const first = await routeIssue(ports(log), { issueText, mode: "apply", issue: 7, overrides: {} });
  if (!first.ok) throw new Error("route failed");
  await recordOutcome(ports(log), {
    decisionId: first.value.id,
    result: "failure",
    failureClass: "max_turns",
  });
  const retry = await routeIssue(ports(log), { issueText, mode: "apply", issue: 7, overrides: {} });
  expect(retry.ok && retry.value.inputs.previousFailure).toBe("max_turns");
  expect(retry.ok && retry.value.difficulty.tier).toBe("small");
  const other = await routeIssue(ports(log), { issueText, mode: "apply", issue: 8, overrides: {} });
  expect(other.ok && other.value.difficulty.tier).toBe("trivial");
});
