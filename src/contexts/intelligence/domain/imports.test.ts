import { describe, expect, test } from "bun:test";
import { importsOf, joinPath, resolveImport } from "./imports";

const files = new Set([
  "src/a.ts",
  "src/b/index.ts",
  "src/c.ts",
  "pkg/mod/util.py",
  "pkg/mod/__init__.py",
  "scripts/sw-loop.sh",
  "scripts/lib/compat.sh",
  "src/lib.rs",
  "src/model.rs",
]);

describe("importsOf", () => {
  test("bash: source and dot, after && and with variables", () => {
    const sh =
      '[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"\n. "$DIR/x.sh"\n';
    expect(importsOf("sh", sh)).toEqual(["$SCRIPT_DIR/lib/compat.sh", "$DIR/x.sh"]);
  });

  test("python relative and absolute; ruby require_relative gets ./", () => {
    expect(importsOf("py", "from . import x\nfrom .util import y\nimport os.path\n")).toEqual([
      ".",
      ".util",
      "os.path",
    ]);
    expect(importsOf("rb", 'require_relative "cart"\n')).toEqual(["./cart"]);
  });
});

describe("resolveImport", () => {
  test("TypeScript: relative specifiers with extensions, index files and .js suffixes", () => {
    expect(resolveImport("ts", "src/a.ts", "./b", files)).toBe("src/b/index.ts");
    expect(resolveImport("ts", "src/a.ts", "./c.js", files)).toBe("src/c.ts");
    expect(resolveImport("ts", "src/a.ts", "node:fs", files)).toBeUndefined();
  });

  test("Python: relative and dotted absolute imports", () => {
    expect(resolveImport("py", "pkg/mod/__init__.py", ".util", files)).toBe("pkg/mod/util.py");
    expect(resolveImport("py", "x.py", "mod.util", files)).toBe("pkg/mod/util.py");
  });

  test("bash: variable prefixes are dropped and the rest resolves near the file", () => {
    expect(resolveImport("sh", "scripts/sw-loop.sh", "$SCRIPT_DIR/lib/compat.sh", files)).toBe(
      "scripts/lib/compat.sh",
    );
  });

  test("Rust: mod declarations", () => {
    expect(resolveImport("rs", "src/lib.rs", "model", files)).toBe("src/model.rs");
  });

  test("joinPath never climbs above the root", () => {
    expect(joinPath("a/b", "../c")).toBe("a/c");
    expect(joinPath("", "../x")).toBeUndefined();
  });
});
