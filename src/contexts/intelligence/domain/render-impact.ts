import type { ChangeImpact, FileImpact, Listed } from "./impact";

function names(l: Listed): string {
  return `${l.shown.join(", ")}${l.more > 0 ? ` and ${l.more} more` : ""}`;
}

function fileBlock(f: FileImpact): string[] {
  const out = [`- ${f.path}`];
  const pub = f.touched.filter((s) => s.exported).map((s) => s.name);
  const priv = f.touched.filter((s) => !s.exported).map((s) => s.name);
  if (pub.length > 0) out.push(`    edits public: ${pub.slice(0, 8).join(", ")}`);
  if (priv.length > 0) out.push(`    edits internal: ${priv.slice(0, 8).join(", ")}`);
  if (f.dependents.shown.length > 0) out.push(`    imported by: ${names(f.dependents)}`);
  for (const c of f.callers) out.push(`    \`${c.name}\` is used in: ${names(c.files)}`);
  if (f.tests.length > 0) {
    const t = f.tests
      .slice(0, 4)
      .map((x) => `${x.path}${x.inChange ? " (changed)" : ""}`)
      .join(", ");
    out.push(`    tests: ${t}`);
  } else out.push("    tests: none linked");
  return out;
}

/**
 * The review prompt's impact section: for each changed file, the definitions it edits and who outside the
 * change depends on them. Empty when the change touches nothing the model indexes.
 */
export function renderImpact(impact: ChangeImpact): string {
  if (impact.files.length === 0 && impact.orphaned.length === 0) return "";
  const out = [
    "## Change impact (repository model)",
    "",
    "Static analysis of what this diff reaches outside its own lines. Names are matched, not types, so treat",
    "these as places to check, not as proven breakage:",
    "",
  ];
  for (const f of impact.files.slice(0, 15)) out.push(...fileBlock(f));
  if (impact.files.length > 15) out.push(`- … ${impact.files.length - 15} more changed files`);
  for (const o of impact.orphaned)
    out.push(`- DELETED ${o.path} is still imported by: ${names(o.importers)}`);
  if (impact.untested.length > 0)
    out.push(
      "",
      `Changed code with no linked test changed in this diff: ${impact.untested.slice(0, 10).join(", ")}`,
    );
  out.push(
    "",
    "Check that every caller and importer listed above still works with the changed code, and say so when",
    "changed behaviour has no test.",
  );
  return out.join("\n");
}
