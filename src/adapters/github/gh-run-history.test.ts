import { expect, test } from "bun:test";
import { FakeProcessRunner } from "../../testing/fake-process-runner";
import { GhRunHistory, toRunRecord } from "./gh-run-history";

const ghRun = (status: string, conclusion: string | null) => ({
  databaseId: 38554676028,
  status,
  conclusion,
  createdAt: "2026-10-14T11:10:10Z",
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
    "databaseId,status,conclusion,createdAt,updatedAt",
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

test.each([["cancelled"], ["skipped"], ["neutral"], ["action_required"], ["stale"]])(
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
