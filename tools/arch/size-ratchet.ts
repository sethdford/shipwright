import { join, resolve } from "node:path";
import { Glob } from "bun";
import ts from "typescript";

export const FILE_LIMIT = 300;
export const FUNCTION_LIMIT = 40;
const ROOT = resolve(import.meta.dir, "../..");
const BASELINE = join(ROOT, "tools/arch/arch-baseline.json");

export interface Measurement {
  readonly file: string;
  readonly fileLines: number;
  readonly functions: { id: string; lines: number }[];
}
export interface Baseline {
  readonly files: Record<string, number>;
  readonly functions: Record<string, number>;
}

function propName(name: ts.PropertyName | ts.BindingName): string | undefined {
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) {
    return name.text;
  }
  if (ts.isPrivateIdentifier(name)) return name.text;
  if (ts.isComputedPropertyName(name)) return `[${name.expression.getText()}]`;
  return undefined;
}

/** Name given to the value by its parent: `const x = ...` or `{ x: ... }`. */
function bindingName(node: ts.Node): string | undefined {
  const parent = node.parent;
  if (parent && (ts.isVariableDeclaration(parent) || ts.isPropertyAssignment(parent))) {
    return propName(parent.name);
  }
  return undefined;
}

function calleeName(call: ts.CallExpression | ts.NewExpression): string {
  const e = call.expression;
  if (ts.isIdentifier(e)) return e.text;
  if (ts.isPropertyAccessExpression(e)) return e.name.text;
  return "call";
}

function nameOf(node: ts.Node): string {
  if (ts.isConstructorDeclaration(node)) return "constructor";
  const own = (node as { name?: ts.PropertyName }).name;
  const ownName = own ? propName(own) : undefined;
  if (ownName !== undefined) {
    if (ts.isGetAccessorDeclaration(node)) return `get:${ownName}`;
    if (ts.isSetAccessorDeclaration(node)) return `set:${ownName}`;
    return ownName;
  }
  const bound = bindingName(node);
  if (bound !== undefined) return bound;
  const parent = node.parent;
  if (parent && (ts.isCallExpression(parent) || ts.isNewExpression(parent))) {
    const index = parent.arguments?.indexOf(node as ts.Expression) ?? -1;
    if (index >= 0) return `<${calleeName(parent)}-arg${index}>`;
  }
  return "anon";
}

/**
 * Ids are `file#Scope.name` (classes, object literals and enclosing functions are scopes;
 * accessors are `get:x`/`set:x`; callbacks are `<callee-argN>`). A repeat of the same id within a
 * file gets `#2`, `#3` in source order as a last resort. An outer function's size includes the
 * lines of the functions nested inside it.
 */
export function measure(file: string, text: string): Measurement {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const functions: { id: string; lines: number }[] = [];
  const seen = new Map<string, number>();
  const lineOf = (pos: number) => sf.getLineAndCharacterOfPosition(pos).line;
  const visit = (node: ts.Node, scope: readonly string[]): void => {
    let inner = scope;
    if (ts.isFunctionLike(node) && "body" in node && node.body) {
      const name = nameOf(node);
      const qualified = [...scope, name].join(".");
      const n = (seen.get(qualified) ?? 0) + 1;
      seen.set(qualified, n);
      const start = lineOf(node.getStart());
      functions.push({
        id: `${file}#${qualified}${n > 1 ? `#${n}` : ""}`,
        lines: lineOf(node.getEnd()) - start + 1,
      });
      inner = [...scope, name];
    } else if (ts.isClassLike(node)) {
      inner = [...scope, node.name?.text ?? bindingName(node) ?? "anon"];
    } else if (ts.isObjectLiteralExpression(node)) {
      const bound = bindingName(node);
      if (bound !== undefined) inner = [...scope, bound];
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
  if (size > base) {
    return [`${id} grew to ${size} lines (baseline ${base}). Baselined code may only shrink.`];
  }
  if (size <= limit) return [`remove baseline entry ${id} (now ${size} lines, within the limit)`];
  return size < base ? [`tighten baseline ${id} to ${size}`] : [];
}

function stale(known: ReadonlySet<string>, entries: Record<string, number>): string[] {
  return Object.keys(entries)
    .filter((id) => !known.has(id))
    .map((id) => `remove stale baseline entry ${id}`);
}

/** The baseline is a ratchet: over-budget code may only shrink, and entries must track reality. */
export function checkBudgets(ms: readonly Measurement[], baseline: Baseline): string[] {
  const problems = ms.flatMap((m) => [
    ...over(m.file, m.fileLines, FILE_LIMIT, baseline.files[m.file], "files"),
    ...m.functions.flatMap((f) =>
      over(f.id, f.lines, FUNCTION_LIMIT, baseline.functions[f.id], "functions"),
    ),
  ]);
  return [
    ...problems,
    ...stale(new Set(ms.map((m) => m.file)), baseline.files),
    ...stale(new Set(ms.flatMap((m) => m.functions.map((f) => f.id))), baseline.functions),
  ];
}

function nextEntries(
  current: Record<string, number>,
  existing: Record<string, number> | undefined,
  errors: string[],
): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [id, size] of Object.entries(current)) {
    const base = existing?.[id];
    if (existing && base === undefined) {
      errors.push(`refusing to baseline new violation ${id} (${size} lines)`);
    } else if (base !== undefined && size > base) {
      errors.push(`refusing to raise baseline ${id} from ${base} to ${size}`);
    } else out[id] = size;
  }
  return out;
}

/** With no existing baseline, records everything over budget. Otherwise it may only tighten or prune. */
export function nextBaseline(
  ms: readonly Measurement[],
  existing: Baseline | undefined,
): { baseline: Baseline } | { errors: string[] } {
  const files: Record<string, number> = {};
  const functions: Record<string, number> = {};
  for (const m of ms) {
    if (m.fileLines > FILE_LIMIT) files[m.file] = m.fileLines;
    for (const f of m.functions) if (f.lines > FUNCTION_LIMIT) functions[f.id] = f.lines;
  }
  const errors: string[] = [];
  const baseline = {
    files: nextEntries(files, existing?.files, errors),
    functions: nextEntries(functions, existing?.functions, errors),
  };
  return errors.length > 0 ? { errors } : { baseline };
}

async function measureAll(): Promise<Measurement[]> {
  const out: Measurement[] = [];
  for await (const file of new Glob("src/**/*.ts").scan(ROOT)) {
    if (file.endsWith(".test.ts")) continue;
    out.push(measure(file, await Bun.file(join(ROOT, file)).text()));
  }
  return out.sort((a, b) => a.file.localeCompare(b.file));
}

if (import.meta.main) {
  const ms = await measureAll();
  const baselineFile = Bun.file(BASELINE);
  const existing = (await baselineFile.exists())
    ? ((await baselineFile.json()) as Baseline)
    : undefined;
  if (Bun.argv.includes("--write-baseline")) {
    const next = nextBaseline(ms, existing);
    if ("errors" in next) {
      for (const e of next.errors) console.error(`F7 ${e}`);
      process.exit(1);
    }
    await Bun.write(BASELINE, `${JSON.stringify(next.baseline, null, 2)}\n`);
  } else {
    if (!existing) {
      console.error("F7 baseline missing. Run: bun tools/arch/size-ratchet.ts --write-baseline");
      process.exit(1);
    }
    const problems = checkBudgets(ms, existing);
    for (const p of problems) console.error(`F7 ${p}`);
    process.exit(problems.length ? 1 : 0);
  }
}
