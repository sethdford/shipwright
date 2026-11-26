import { describe, expect, test } from "bun:test";
import { extractFacts, symbolsOf } from "./extract";

const names = (lang: Parameters<typeof symbolsOf>[0], text: string) =>
  symbolsOf(lang, text).map(
    (s) => `${s.kind}:${s.container ? `${s.container}.` : ""}${s.name}${s.exported ? "" : "-"}`,
  );

describe("symbolsOf", () => {
  test("TypeScript: functions, classes with methods, interfaces, types, enums, arrow consts", () => {
    const ts = [
      "/** Decides the budget. */",
      "export function evaluateBudget(a: number): boolean {",
      "  return a > 0;",
      "}",
      "export class RepoSession {",
      "  async current(): Promise<number> {",
      "    if (x) {",
      "    }",
      "  }",
      "}",
      "interface Port {",
      "}",
      "export type Id = string;",
      "export enum Kind { A }",
      "const helper = async (x: number) => x;",
      "export const LIMIT = 3;",
    ].join("\n");
    expect(names("ts", ts)).toEqual([
      "function:evaluateBudget",
      "class:RepoSession",
      "method:RepoSession.current-",
      "interface:Port-",
      "type:Id",
      "enum:Kind",
      "function:helper-",
      "const:LIMIT",
    ]);
    expect(symbolsOf("ts", ts)[0]?.doc).toBe("Decides the budget.");
  });

  test("Python: methods get their class, private names are not exported", () => {
    const py =
      "class Budget:\n    def check(self):\n        pass\n\ndef _helper():\n    pass\nMAX_CAP = 3\n";
    expect(names("py", py)).toEqual([
      "class:Budget",
      "method:Budget.check",
      "function:_helper-",
      "const:MAX_CAP",
    ]);
  });

  test("Go: receivers become containers, capitalized names are exported", () => {
    const go = "type Store struct {}\nfunc (s *Store) Save() error {\n}\nfunc helper() {}\n";
    expect(names("go", go)).toEqual(["struct:Store", "method:Store.Save", "function:helper-"]);
  });

  test("Rust: impl blocks give methods a container and are not symbols", () => {
    const rs = "pub struct Model;\nimpl Model {\n    pub fn refresh(&self) {}\n}\nfn local() {}\n";
    expect(names("rs", rs)).toEqual(["struct:Model", "method:Model.refresh", "function:local-"]);
  });

  test("bash: both function syntaxes, with the comment above as the doc", () => {
    const sh =
      "# Prints the brief.\nrepo_model_brief() {\n  :\n}\nfunction _private_one {\n  :\n}\n";
    const syms = symbolsOf("sh", sh);
    expect(names("sh", sh)).toEqual(["function:repo_model_brief", "function:_private_one-"]);
    expect(syms[0]?.doc).toBe("Prints the brief.");
  });

  test("Java and Ruby", () => {
    expect(names("java", "public class Cart {\n  public int total(int a) {\n  }\n}\n")).toEqual([
      "class:Cart",
      "method:Cart.total",
    ]);
    expect(names("rb", "class Cart\n  def total\n  end\nend\n")).toEqual([
      "class:Cart",
      "method:Cart.total",
    ]);
  });
});

describe("extractFacts", () => {
  test("refs leave out keywords, short words and the file's own definitions", () => {
    const facts = extractFacts(
      "src/a.ts",
      'import { b } from "./b";\nexport function own() { return callOther(b); }\n',
    );
    expect(facts.imports).toEqual(["./b"]);
    expect(facts.refs).toContain("callOther");
    expect(facts.refs).not.toContain("own");
    expect(facts.refs).not.toContain("return");
    expect(facts.lang).toBe("ts");
  });
});
