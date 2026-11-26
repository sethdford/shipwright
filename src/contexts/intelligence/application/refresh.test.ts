import { describe, expect, test } from "bun:test";
import { fakeRepoPorts } from "../../../testing/repo-model-fixture";
import { refreshModel } from "./refresh";

const FILES = {
  "src/a.ts": "export function alpha() {}\n",
  "src/b.ts": 'import { alpha } from "./a";\nexport function beta() { alpha(); }\n',
  "README.md": "# not source\n",
  "node_modules/x/index.js": "module.exports = 1;\n",
};

describe("refreshModel", () => {
  test("the first build reads every source file and skips the rest", async () => {
    const { tree, ports } = fakeRepoPorts(FILES, "src/ @core\n");
    const r = await refreshModel(ports, "/repo");
    if (!r.ok) throw new Error(r.error.message);
    expect(r.value.model.files.map((f) => f.path)).toEqual(["src/a.ts", "src/b.ts"]);
    expect(r.value.stats).toMatchObject({ files: 2, extracted: 2, skipped: 3 });
    expect(r.value.model.codeowners).toBe("src/ @core\n");
    expect(tree.saved?.files).toHaveLength(2);
  });

  test("a second refresh reads nothing; an edit re-reads only that file", async () => {
    const { tree, ports } = fakeRepoPorts(FILES);
    await refreshModel(ports, "/repo");
    tree.reads.length = 0;
    const again = await refreshModel(ports, "/repo");
    expect(again.ok && again.value).toMatchObject({
      changed: false,
      stats: { extracted: 0, reused: 2 },
    });
    expect(tree.reads).toEqual([]);

    tree.texts.set("src/a.ts", "export function alpha() {}\nexport function gamma() {}\n");
    tree.mtimes.set("src/a.ts", 2);
    const edited = await refreshModel(ports, "/repo");
    if (!edited.ok) throw new Error(edited.error.message);
    expect(tree.reads).toEqual(["src/a.ts"]);
    expect(edited.value.stats.extracted).toBe(1);
    expect(edited.value.model.files[0]?.symbols.map((s) => s.name)).toEqual(["alpha", "gamma"]);
  });

  test("a touched but unchanged file is not extracted again; a deleted file is removed", async () => {
    const { tree, ports } = fakeRepoPorts(FILES);
    await refreshModel(ports, "/repo");
    tree.mtimes.set("src/b.ts", 9);
    tree.texts.delete("src/a.ts");
    const r = await refreshModel(ports, "/repo");
    if (!r.ok) throw new Error(r.error.message);
    expect(r.value.stats).toMatchObject({ extracted: 0, removed: 1, files: 1 });
    expect(tree.saved?.files[0]?.mtimeMs).toBe(9);
  });

  test("authorship is read once per commit, and a stored model of another extractor version is rebuilt", async () => {
    const { tree, ports } = fakeRepoPorts(FILES);
    await refreshModel(ports, "/repo");
    tree.mtimes.set("src/a.ts", 5);
    tree.texts.set("src/a.ts", "export function other() {}\n");
    await refreshModel(ports, "/repo");
    expect(tree.authorshipCalls).toBe(1);
    if (tree.saved) tree.saved = { ...tree.saved, extractor: -1 };
    const r = await refreshModel(ports, "/repo");
    expect(r.ok && r.value.stats.extracted).toBe(2);
  });
});
