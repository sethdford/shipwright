import { describe, expect, test } from "bun:test";
import type { AdapterError } from "../../../shared/kernel/ports";
import { err, ok, type Result } from "../../../shared/kernel/result";
import type { DocSource, RepoDocs } from "../ports";
import { briefInputs, loadGuidance } from "./guidance";

class MapDocs implements RepoDocs {
  readonly reads: string[] = [];
  constructor(
    private readonly files: Readonly<Record<string, string>>,
    private readonly broken: readonly string[] = [],
  ) {}
  async list(
    _s: DocSource,
    prefixes: readonly string[],
  ): Promise<Result<readonly string[], AdapterError>> {
    return ok(Object.keys(this.files).filter((p) => prefixes.some((x) => p.startsWith(x))));
  }
  async read(_s: DocSource, path: string): Promise<Result<string, AdapterError>> {
    this.reads.push(path);
    if (this.broken.includes(path)) return err({ kind: "failed", message: "disk" });
    const text = this.files[path];
    return text === undefined ? err({ kind: "not_found", message: path }) : ok(text);
  }
}

const FILES = {
  "docs/adr/0001-bun.md": "# 0001. Bun\n\nStatus: accepted\n\n## Decision\nUse Bun.\n",
  "docs/adr/README.md": "index",
  ".shipwright/lessons/L-0001.md":
    "---\nid: L-0001\nstatus: active\n---\nCreate the temp dir first.\n",
  ".shipwright/lessons/README.md": "how to write a lesson",
};

describe("loadGuidance", () => {
  test("parses documents and lessons and skips README files", async () => {
    const repo = new MapDocs(FILES);
    const g = await loadGuidance(repo, { root: "." });
    if (!g.ok) throw new Error(g.error.message);
    expect(g.value.docs.map((d) => d.id)).toEqual(["ADR-0001"]);
    expect(g.value.lessons.map((l) => l.id)).toEqual(["L-0001"]);
    expect(repo.reads).not.toContain("docs/adr/README.md");
  });

  test("fails closed when a listed file cannot be read", async () => {
    const g = await loadGuidance(new MapDocs(FILES, ["docs/adr/0001-bun.md"]), { root: "." });
    expect(g.ok).toBe(false);
    if (!g.ok) expect(g.error.message).toContain("docs/adr/0001-bun.md");
  });
});

describe("briefInputs", () => {
  test("each ablation switch removes only its own half", async () => {
    const g = await loadGuidance(new MapDocs(FILES), { root: "." });
    if (!g.ok) throw new Error(g.error.message);
    const context = { text: "", paths: [] };
    const noLessons = briefInputs(g.value, { lessons: false, governance: true, context });
    expect([noLessons.docs.length, noLessons.lessons.length]).toEqual([1, 0]);
    const noDocs = briefInputs(g.value, { lessons: true, governance: false, context });
    expect([noDocs.docs.length, noDocs.lessons.length]).toEqual([0, 1]);
  });
});
