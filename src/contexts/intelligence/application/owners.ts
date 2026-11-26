import { globMatch } from "../../governance";
import type { AuthorStat } from "../domain/model";

export interface OwnerRule {
  readonly pattern: string;
  readonly owners: readonly string[];
}

/** CODEOWNERS lines in file order; comments and blank lines dropped. */
export function parseCodeowners(text: string): OwnerRule[] {
  const rules: OwnerRule[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.replace(/(^|\s)#.*$/, "").trim();
    if (line.length === 0) continue;
    const [pattern, ...owners] = line.split(/\s+/);
    if (pattern) rules.push({ pattern, owners });
  }
  return rules;
}

/** A CODEOWNERS pattern as repository globs (gitignore rules: unanchored names match at any depth). */
function globsOf(pattern: string): string[] {
  const anchored = pattern.startsWith("/") || pattern.slice(0, -1).includes("/");
  const p = pattern.replace(/^\//, "");
  const base = anchored ? p : `**/${p}`;
  if (p.endsWith("/")) return [`${base}**`];
  return [base, `${base}/**`];
}

/** The owners of a path: the last matching rule wins, as GitHub reads the file. */
export function ownersOf(rules: readonly OwnerRule[], path: string): readonly string[] {
  for (let i = rules.length - 1; i >= 0; i -= 1) {
    const rule = rules[i];
    if (rule && globsOf(rule.pattern).some((g) => globMatch(g, path))) return rule.owners;
  }
  return [];
}

export interface Ownership {
  readonly owners: readonly string[];
  readonly authors: readonly AuthorStat[];
}

export function ownershipOf(
  rules: readonly OwnerRule[],
  authors: Readonly<Record<string, readonly AuthorStat[]>>,
  path: string,
): Ownership {
  return { owners: ownersOf(rules, path), authors: (authors[path] ?? []).slice(0, 3) };
}
