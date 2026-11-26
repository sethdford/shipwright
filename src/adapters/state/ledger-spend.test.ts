import { expect, test } from "bun:test";
import { err, ok } from "../../shared/kernel/result";
import { LedgerSpend } from "./ledger-spend";

const entries = [
  { costUsd: 1, atEpochS: 100 },
  { costUsd: 2, atEpochS: 200 },
  { costUsd: 4, atEpochS: 300 },
];

test("sums spend inside the window", async () => {
  const ledger = { read: async () => ok({ budget: null, entries, present: true }) };
  expect(await new LedgerSpend(ledger).between(150_000, 300_000)).toEqual({ ok: true, value: 6 });
});

test("no cost file is unknown spend, not zero", async () => {
  const ledger = { read: async () => ok({ budget: null, entries: [], present: false }) };
  expect(await new LedgerSpend(ledger).between(0, 1)).toEqual({ ok: true, value: null });
});

test("an unreadable ledger is an error", async () => {
  const ledger = { read: async () => err({ kind: "failed" as const, message: "bad" }) };
  expect((await new LedgerSpend(ledger).between(0, 1)).ok).toBe(false);
});
