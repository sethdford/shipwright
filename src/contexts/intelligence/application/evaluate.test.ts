import { expect, test } from "bun:test";
import { err, ok } from "../../../shared/kernel/result";
import type { RepoModel } from "../domain/model";
import type { HistorySource, RepoModelPorts } from "../ports";
import { evaluateLocalization } from "./evaluate";

const P1 = "1".repeat(40);
const P2 = "2".repeat(40);

// Two snapshots of a repository, one per parent commit; the history names what each PR changed.
const TREES: Record<string, Record<string, string>> = {
  [`/wt/${P1}`]: {
    "src/budget.ts": "export function evaluateBudget(spent: number) {\n  return spent;\n}\n",
    "src/tmux.ts": "export function openPane(name: string) {\n  return name;\n}\n",
  },
  [`/wt/${P2}`]: {
    "src/budget.ts": "export function evaluateBudget(spent: number) {\n  return spent;\n}\n",
    "src/tmux.ts": "export function openPane(name: string) {\n  return name;\n}\n",
  },
};

function ports(log: string[]): RepoModelPorts {
  const saved = new Map<string, RepoModel>();
  const history: HistorySource = {
    commits: async () =>
      ok([
        {
          sha: "a".repeat(40),
          parent: P1,
          subject: "fix: the budget is ignored (#1)",
          body: "",
          files: ["src/budget.ts"],
        },
        {
          sha: "b".repeat(40),
          parent: P2,
          subject: "feat: split a tmux pane (#2)",
          body: "",
          files: ["src/tmux.ts", "src/new.ts"],
        },
        {
          sha: "c".repeat(40),
          parent: P2,
          subject: "docs: auto-sync",
          body: "",
          files: ["README.md"],
        },
      ]),
    checkout: async (_root, rev) => {
      log.push(`checkout ${rev.slice(0, 1)}`);
      return ok(`/wt/${rev}`);
    },
    release: async () => {
      log.push("release");
    },
  };
  return {
    now: () => "2026-11-26T00:00:00Z",
    history,
    source: {
      list: async (root) =>
        ok(
          Object.entries(TREES[root] ?? {}).map(([path, t]) => ({
            path,
            size: t.length,
            mtimeMs: 1,
          })),
        ),
      read: async (root, path) => {
        const t = TREES[root]?.[path];
        return t === undefined ? err({ kind: "not_found", message: path }) : ok(t);
      },
      head: async () => "abc",
      authorship: async () => ok({}),
    },
    store: {
      load: async (root) => saved.get(root),
      save: async (m) => {
        saved.set(m.root, m);
        return ok(undefined);
      },
    },
  };
}

test("each PR is localized on its parent's model, and the scratch checkout is released", async () => {
  const log: string[] = [];
  const r = await evaluateLocalization(ports(log), {
    root: "/repo",
    ref: "HEAD",
    commits: 10,
    semantic: false,
  });
  if (!r.ok) throw new Error(r.error.message);
  expect(r.value.results.map((c) => [c.task, c.firstHit, c.findable])).toEqual([
    ["fix: the budget is ignored (#1)", 1, ["src/budget.ts"]],
    ["feat: split a tmux pane (#2)", 1, ["src/tmux.ts"]],
  ]);
  expect(r.value.summary.acc1).toBe(1);
  expect(log).toEqual(["checkout 1", "checkout 2", "release"]);
});

test("no history source is an error, not a crash", async () => {
  const { history: _, ...rest } = ports([]);
  const r = await evaluateLocalization(rest, {
    root: "/repo",
    ref: "HEAD",
    commits: 1,
    semantic: false,
  });
  expect(r.ok).toBe(false);
});
