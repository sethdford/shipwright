import { describe, expect, test } from "bun:test";
import type { DocSource, RepoDocs } from "../../contexts/governance";
import type { AdapterError } from "../../shared/kernel/ports";
import { err, ok, type Result } from "../../shared/kernel/result";
import { captureIO, commandContext } from "../../testing/cli-harness";
import { FakeFileReader } from "../../testing/fake-file-reader";
import { governanceCommand } from "./governance";
import { parseManifest } from "./governance-learn";

const DOCS: Record<string, string> = {
  ".shipwright/lessons/L-0001.md":
    "---\nid: L-0001\nstatus: active\nkeywords: [mktemp]\n---\n# Old\n\nOld rule.\n",
  ".shipwright/lessons/L-0002.md":
    "---\nid: L-0002\nstatus: proposed\nkeywords: [heartbeat]\n---\n# Trial\n\nCheck the heartbeat.\n",
};

const repo: RepoDocs = {
  async list(
    _s: DocSource,
    prefixes: readonly string[],
  ): Promise<Result<readonly string[], AdapterError>> {
    return ok(Object.keys(DOCS).filter((p) => prefixes.some((x) => p.startsWith(x))));
  },
  async read(_s: DocSource, path: string): Promise<Result<string, AdapterError>> {
    const t = DOCS[path];
    return t === undefined ? err({ kind: "not_found", message: path }) : ok(t);
  },
};

const LOG = "building\nError: mktemp: failed to create directory /x/y\n";
const verdict = (accept: boolean, cases = 14) =>
  JSON.stringify({
    incumbent: "off",
    candidate: "L-0003",
    verdict: {
      accept,
      reason: accept ? "superior" : "inferior",
      cases,
      wins: cases - 3,
      losses: 1,
      ties: 2,
      signTestP: 0.06,
      medianCostRatio: 0.9,
    },
  });

function files(extra: Record<string, string> = {}) {
  return new FakeFileReader({
    "/m.txt": "# runs\nrun-1 /a.log\nrun-2 /b.log\nrun-3 /c.log\n",
    "/a.log": LOG,
    "/b.log": LOG,
    "/c.log": "Error: something else entirely\n",
    "/issue.md": "the heartbeat check is flaky",
    "/reply.json":
      '{"title":"Create the parent dir","rule":"Run mkdir -p on the parent before mktemp.","hypothesis":"Fewer mktemp failures."}',
    "/bad-reply.json": "not json at all",
    "/accept.json": verdict(true),
    "/reject.json": verdict(false),
    "/thin.json": verdict(true, 5),
    ...extra,
  });
}

async function run(args: string[], env: Record<string, string> = {}, f = files()) {
  const io = captureIO();
  const code = await governanceCommand.run(
    args,
    commandContext(io, undefined, env, f, { repoDocs: repo }),
  );
  return { code, out: io.outLines.join("\n"), err: io.errLines.join("\n") };
}

async function reflectedDraft(): Promise<string> {
  const mined = JSON.parse((await run(["mine", "--manifest", "/m.txt", "--json"])).out);
  const draft = mined.drafts[0].markdown as string;
  return (
    await run(
      ["apply-reflection", "--draft", "/d.md", "--reply", "/reply.json"],
      {},
      files({ "/d.md": draft }),
    )
  ).out;
}

describe("governance mine", () => {
  test("drafts one lesson per recurring failure, numbered after the existing ones", async () => {
    const r = await run(["mine", "--manifest", "/m.txt", "--json"]);
    expect(r.code).toBe(0);
    const j = JSON.parse(r.out);
    expect(j.runs).toBe(3);
    expect(j.drafts.map((d: { id: string; count: number }) => [d.id, d.count])).toEqual([
      ["L-0003", 2],
    ]);
    expect(j.drafts[0].markdown).toContain("status: proposed");
  });

  test("--min raises the bar for recurrence", async () => {
    const j = JSON.parse((await run(["mine", "--manifest", "/m.txt", "--min", "3", "--json"])).out);
    expect(j.drafts).toEqual([]);
  });

  test("bad input fails closed", async () => {
    expect((await run(["mine"])).code).toBe(2);
    expect((await run(["mine", "--manifest", "/m.txt", "--min", "0"])).code).toBe(2);
    expect((await run(["mine", "--manifest", "/missing.txt"])).code).toBe(1);
    expect(parseManifest("only-one-field")).toContain("line 1");
  });
});

describe("governance reflect and apply-reflection", () => {
  test("reflect prints a prompt for a placeholder draft and refuses a finished one", async () => {
    const mined = JSON.parse((await run(["mine", "--manifest", "/m.txt", "--json"])).out);
    const f = files({ "/d.md": mined.drafts[0].markdown });
    const r = await run(["reflect", "--draft", "/d.md"], {}, f);
    expect(r.code).toBe(0);
    expect(r.out).toContain("mktemp");
    const done = await reflectedDraft();
    expect((await run(["reflect", "--draft", "/e.md"], {}, files({ "/e.md": done }))).code).toBe(3);
  });

  test("apply-reflection writes the rule and keeps the lesson proposed", async () => {
    const out = await reflectedDraft();
    expect(out).toContain("Run mkdir -p on the parent before mktemp.");
    expect(out).toContain("status: proposed");
  });

  test("a reply that is not a reflection is rejected", async () => {
    const mined = JSON.parse((await run(["mine", "--manifest", "/m.txt", "--json"])).out);
    const f = files({ "/d.md": mined.drafts[0].markdown });
    expect(
      (await run(["apply-reflection", "--draft", "/d.md", "--reply", "/bad-reply.json"], {}, f))
        .code,
    ).toBe(1);
  });
});

describe("governance promote", () => {
  test("an accepted trial with enough cases activates the lesson", async () => {
    const f = files({ "/d.md": await reflectedDraft() });
    const r = await run(["promote", "--draft", "/d.md", "--verdict", "/accept.json"], {}, f);
    expect(r.code).toBe(0);
    expect(r.out).toContain("status: active");
    expect(r.out).toContain("## Evaluation");
  });

  test("a rejected or thin trial retires it", async () => {
    const f = files({ "/d.md": await reflectedDraft() });
    for (const v of ["/reject.json", "/thin.json"]) {
      const r = await run(["promote", "--draft", "/d.md", "--verdict", v, "--json"], {}, f);
      expect(r.code).toBe(3);
      expect(JSON.parse(r.out).outcome).toBe("retire");
    }
  });

  test("a placeholder draft cannot be promoted", async () => {
    const mined = JSON.parse((await run(["mine", "--manifest", "/m.txt", "--json"])).out);
    const f = files({ "/d.md": mined.drafts[0].markdown });
    expect(
      (await run(["promote", "--draft", "/d.md", "--verdict", "/accept.json"], {}, f)).code,
    ).toBe(2);
  });
});

describe("the trial arm", () => {
  test("a proposed lesson reaches the brief only in its trial", async () => {
    const base = JSON.parse((await run(["brief", "--issue", "/issue.md", "--json"])).out);
    expect(base.lessons.map((l: { id: string }) => l.id)).not.toContain("L-0002");
    const trial = JSON.parse(
      (
        await run(["brief", "--issue", "/issue.md", "--json"], {
          SHIPWRIGHT_LESSONS_TRIAL: "L-0002",
        })
      ).out,
    );
    expect(trial.lessons.map((l: { id: string }) => l.id)).toContain("L-0002");
    const flag = JSON.parse(
      (await run(["brief", "--issue", "/issue.md", "--trial", "L-0002", "--json"])).out,
    );
    expect(flag.lessons.map((l: { id: string }) => l.id)).toContain("L-0002");
  });
});
