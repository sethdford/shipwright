import {
  extractFacts,
  type FileEntry,
  type RepoModel,
  type RepoModelPorts,
} from "../contexts/intelligence";
import { err, ok } from "../shared/kernel/result";

const TEST_RE = /(\.test\.|(^|\/)tests?\/|-test\.sh$|test_[^/]+\.py$)/;

/** A repository model built from file texts, for intelligence tests (no file system, no git). */
export function modelOf(
  files: Readonly<Record<string, string>>,
  extra: Partial<RepoModel> = {},
): RepoModel {
  const entries: FileEntry[] = Object.entries(files)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([path, text]) => ({
      ...extractFacts(path, text),
      path,
      hash: path,
      size: text.length,
      mtimeMs: 1,
      test: TEST_RE.test(path),
    }));
  return {
    schema: 1,
    extractor: 1,
    root: "/repo",
    builtAt: "2026-11-26T00:00:00Z",
    head: "abc",
    codeowners: "",
    authors: {},
    files: entries,
    ...extra,
  };
}

export interface FakeTree {
  /** path → text; change a text and bump `mtimes` to simulate an edit. */
  readonly texts: Map<string, string>;
  readonly mtimes: Map<string, number>;
  readonly reads: string[];
  saved: RepoModel | undefined;
  authorshipCalls: number;
}

/** In-memory repository model ports over a file map; counts reads so tests can see what a refresh re-read. */
export function fakeRepoPorts(files: Readonly<Record<string, string>>, codeowners = "") {
  const tree: FakeTree = {
    texts: new Map(Object.entries(files)),
    mtimes: new Map(Object.keys(files).map((p) => [p, 1] as const)),
    reads: [],
    saved: undefined,
    authorshipCalls: 0,
  };
  if (codeowners) tree.texts.set(".github/CODEOWNERS", codeowners);
  return { tree, ports: portsOver(tree) };
}

function portsOver(tree: FakeTree): RepoModelPorts {
  return {
    now: () => "2026-11-26T00:00:00Z",
    source: {
      list: async () =>
        ok(
          [...tree.texts.entries()].map(([path, t]) => ({
            path,
            size: t.length,
            mtimeMs: tree.mtimes.get(path) ?? 1,
          })),
        ),
      read: async (_root, path) => {
        tree.reads.push(path);
        const t = tree.texts.get(path);
        return t === undefined ? err({ kind: "not_found", message: path }) : ok(t);
      },
      head: async () => "abc",
      authorship: async () => {
        tree.authorshipCalls += 1;
        return ok({ "src/budget.ts": [{ name: "Ada", commits: 3, last: "2026-11-20" }] });
      },
    },
    store: {
      load: async () => tree.saved,
      save: async (m) => {
        tree.saved = m;
        return ok(undefined);
      },
    },
  };
}
