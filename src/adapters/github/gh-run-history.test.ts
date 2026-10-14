import { expect, test } from "bun:test";
import { evaluateBreaker } from "../../contexts/orchestration";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhRunHistory, toRunRecord } from "./gh-run-history";

const ghRun = (status: string, conclusion: string | null) => ({
  databaseId: 38554676028,
  status,
  conclusion,
  createdAt: "2026-10-14T11:10:10Z",
  startedAt: "2026-10-14T11:10:10Z",
  updatedAt: "2026-10-14T11:11:36Z",
});

test("lists pipeline runs with argv only and maps them to run records", async () => {
  const stdout = JSON.stringify([ghRun("completed", "failure"), ghRun("in_progress", "")]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh", "run", "list"], result: { exitCode: 0, stdout, stderr: "" } },
  ]);
  const r = await new GhRunHistory(runner).recentRuns(50);
  expect(runner.calls[0]?.argv).toEqual([
    "gh",
    "run",
    "list",
    "--workflow",
    "shipwright-pipeline.yml",
    "--limit",
    "50",
    "--json",
    "databaseId,status,conclusion,createdAt,startedAt,updatedAt",
  ]);
  expect(r).toEqual({
    ok: true,
    value: [
      {
        id: "38554676028",
        startedAt: Date.parse("2026-10-14T11:10:10Z"),
        finished: { at: Date.parse("2026-10-14T11:11:36Z"), outcome: "failure" },
      },
      { id: "38554676028", startedAt: Date.parse("2026-10-14T11:10:10Z"), finished: null },
    ],
  });
});

test.each([
  ["success", "success"],
  ["failure", "failure"],
  ["timed_out", "failure"],
  ["startup_failure", "failure"],
])("conclusion %p counts as %p", (conclusion, outcome) => {
  expect(toRunRecord(ghRun("completed", conclusion))?.finished?.outcome).toBe(outcome as never);
});

test("conclusion cancelled is kept as a cancelled outcome", () => {
  expect(toRunRecord(ghRun("completed", "cancelled"))?.finished?.outcome).toBe("cancelled");
});

test.each([["skipped"], ["neutral"], ["action_required"], ["stale"]])(
  "conclusion %p is not counted",
  (conclusion) => {
    expect(toRunRecord(ghRun("completed", conclusion))).toBeNull();
  },
);

test.each([["queued"], ["in_progress"], ["waiting"], ["pending"]])(
  "status %p is an active run",
  (status) => {
    expect(toRunRecord(ghRun(status, null))?.finished).toBeNull();
  },
);

test("a gh failure is returned, classified", async () => {
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 1, stdout: "", stderr: "HTTP 401: Bad credentials" } },
  ]);
  const r = await new GhRunHistory(runner).recentRuns(50);
  expect(!r.ok && r.error.kind).toBe("auth");
});

test("a re-run's attempt start time is used, and a zero start falls back to createdAt", () => {
  const rerun = { ...ghRun("completed", "success"), startedAt: "2026-10-14T12:00:00Z" };
  expect(toRunRecord(rerun)?.startedAt).toBe(Date.parse("2026-10-14T12:00:00Z"));
  const queued = { ...ghRun("queued", null), startedAt: "0001-01-01T00:00:00Z" };
  expect(toRunRecord(queued)?.startedAt).toBe(Date.parse("2026-10-14T11:10:10Z"));
});

test("a run created before the cool-down but re-started after it is the probe", () => {
  const t = (iso: string) => Date.parse(iso);
  const failed = (id: number, end: string) => ({
    ...ghRun("completed", "failure"),
    databaseId: id,
    createdAt: end,
    startedAt: end,
    updatedAt: end,
  });
  const opened = [1, 2, 3, 4, 5].map((i) => failed(i, `2026-10-14T10:0${i}:00Z`)); // opens 10:05
  const probe = {
    ...ghRun("completed", "success"),
    databaseId: 9,
    createdAt: "2026-10-14T10:20:00Z", // before the cool-down ends (10:35)
    startedAt: "2026-10-14T10:40:00Z", // re-run attempt after it
    updatedAt: "2026-10-14T10:50:00Z",
  };
  const records = [...opened, probe].map((r) => toRunRecord(r));
  const runs = records.filter((r) => r !== null);
  expect(evaluateBreaker(runs, t("2026-10-14T11:00:00Z"))).toMatchObject({ kind: "closed" });
});

test("a waiting probe older than the cool-down no longer blocks dispatch", () => {
  const t = (iso: string) => Date.parse(iso);
  const opened = [1, 2, 3, 4, 5].map((i) => ({
    ...ghRun("completed", "failure"),
    databaseId: i,
    createdAt: `2026-10-14T10:0${i}:00Z`,
    startedAt: `2026-10-14T10:0${i}:00Z`,
    updatedAt: `2026-10-14T10:0${i}:00Z`,
  }));
  const waiting = {
    ...ghRun("waiting", null),
    databaseId: 9,
    createdAt: "2026-10-14T10:40:00Z",
    startedAt: "2026-10-14T10:40:00Z",
  };
  const runs = [...opened, waiting].map((r) => toRunRecord(r)).filter((r) => r !== null);
  expect(evaluateBreaker(runs, t("2026-10-14T11:00:00Z"))).toMatchObject({ probing: true });
  expect(evaluateBreaker(runs, t("2026-10-14T11:10:01Z"))).toMatchObject({ probing: false });
});

test.each([[0], [-1], [1.5], [Number.NaN], [Number.MAX_SAFE_INTEGER + 1]])(
  "limit %p is rejected without calling gh",
  async (limit) => {
    const runner = new FakeProcessRunner([]);
    const r = await new GhRunHistory(runner).recentRuns(limit);
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.error.kind).toBe("failed");
      expect(r.error.message).toContain("invalid limit");
    }
    expect(runner.calls).toHaveLength(0);
  },
);

test("a negative or fractional databaseId is rejected", async () => {
  const bad = JSON.stringify([{ ...ghRun("completed", "success"), databaseId: -1 }]);
  const runner = new FakeProcessRunner([
    { prefix: ["gh"], result: { exitCode: 0, stdout: bad, stderr: "" } },
  ]);
  expect((await new GhRunHistory(runner).recentRuns(5)).ok).toBe(false);
});
