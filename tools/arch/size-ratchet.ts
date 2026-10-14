import { Glob } from "bun";
import ts from "typescript";

export const FILE_LIMIT = 300;
export const FUNCTION_LIMIT = 40;
const BASELINE = "tools/arch/arch-baseline.json";

export interface Measurement {
  readonly file: string;
  readonly fileLines: number;
  readonly functions: { id: string; lines: number }[];
}
export interface Baseline {
  readonly files: Record<string, number>;
  readonly functions: Record<string, number>;
}

function nameOf(node: ts.Node): string {
  if (ts.isConstructorDeclaration(node)) return "constructor";
  const own = (node as { name?: ts.Node }).name;
  if (own && (ts.isIdentifier(own) || ts.isStringLiteral(own) || ts.isPrivateIdentifier(own))) {
    return own.text;
  }
  const parent = node.parent;
  if (parent && ts.isVariableDeclaration(parent) && ts.isIdentifier(parent.name)) {
    return parent.name.text;
  }
  if (parent && ts.isPropertyAssignment(parent) && ts.isIdentifier(parent.name)) {
    return parent.name.text;
  }
  return "anon";
}

/** Ids are `file#Scope.name`; repeats within a file get `#2`, `#3` in source order. */
export function measure(file: string, text: string): Measurement {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const functions: { id: string; lines: number }[] = [];
  const seen = new Map<string, number>();
  const lineOf = (pos: number) => sf.getLineAndCharacterOfPosition(pos).line;
  const visit = (node: ts.Node, scope: readonly string[]): void => {
    let inner = scope;
    if (ts.isFunctionLike(node) && "body" in node && node.body) {
      const qualified = [...scope, nameOf(node)].join(".");
      const n = (seen.get(qualified) ?? 0) + 1;
      seen.set(qualified, n);
      const start = lineOf(node.getStart());
      functions.push({
        id: `${file}#${qualified}${n > 1 ? `#${n}` : ""}`,
        lines: lineOf(node.getEnd()) - start + 1,
      });
      inner = [...scope, nameOf(node)];
    } else if (ts.isClassLike(node)) {
      inner = [...scope, node.name?.text ?? "anon"];
    }
    ts.forEachChild(node, (child) => visit(child, inner));
  };
  visit(sf, []);
  const lines = text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
  return { file, fileLines: lines, functions };
}

function over(
  id: string,
  size: number,
  limit: number,
  base: number | undefined,
  unit: string,
): string[] {
  if (base === undefined) {
    return size > limit
      ? [`${id} is ${size} lines (limit ${limit}). Split it into smaller ${unit}.`]
      : [];
  }
  return size > base
    ? [`${id} grew to ${size} lines (baseline ${base}). Baselined code may only shrink.`]
    : [];
}

export function checkBudgets(ms: readonly Measurement[], baseline: Baseline): string[] {
  return ms.flatMap((m) => [
    ...over(m.file, m.fileLines, FILE_LIMIT, baseline.files[m.file], "files"),
    ...m.functions.flatMap((f) =>
      over(f.id, f.lines, FUNCTION_LIMIT, baseline.functions[f.id], "functions"),
    ),
  ]);
}

async function measureAll(): Promise<Measurement[]> {
  const out: Measurement[] = [];
  for await (const file of new Glob("src/**/*.ts").scan(".")) {
    if (file.endsWith(".test.ts")) continue;
    out.push(measure(file, await Bun.file(file).text()));
  }
  return out.sort((a, b) => a.file.localeCompare(b.file));
}

if (import.meta.main) {
  const ms = await measureAll();
  if (Bun.argv.includes("--write-baseline")) {
    const files = Object.fromEntries(
      ms.filter((m) => m.fileLines > FILE_LIMIT).map((m) => [m.file, m.fileLines]),
    );
    const functions = Object.fromEntries(
      ms
        .flatMap((m) => m.functions)
        .filter((f) => f.lines > FUNCTION_LIMIT)
        .map((f) => [f.id, f.lines]),
    );
    await Bun.write(BASELINE, `${JSON.stringify({ files, functions }, null, 2)}\n`);
  } else {
    const problems = checkBudgets(ms, (await Bun.file(BASELINE).json()) as Baseline);
    for (const p of problems) console.error(`F7 ${p}`);
    process.exit(problems.length ? 1 : 0);
  }
}
