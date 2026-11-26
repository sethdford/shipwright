import {
  type AcceptanceManifest,
  MANIFEST_LIMITS,
  parseManifest,
  untracedCriteria,
} from "./manifest";

/**
 * The test writer answers in text: one fenced block per file, labelled with its path, and one
 * block labelled `acceptance.json`. Nothing is written unless the whole answer is valid, so a
 * half-good answer never leaves stray files in the repository.
 */
export interface FileBlock {
  readonly path: string;
  readonly content: string;
}

export const MANIFEST_LABEL = "acceptance.json";

const OPEN = /^```([A-Za-z0-9_./-]+)\s*$/;

/** Fenced blocks whose label looks like a path (contains "/" or "."). Unlabelled blocks are prose. */
export function extractBlocks(text: string): readonly FileBlock[] {
  const blocks: FileBlock[] = [];
  let path: string | null = null;
  let lines: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (path === null) {
      const m = OPEN.exec(line);
      const label = m?.[1];
      if (label && (label.includes("/") || label.includes("."))) {
        path = label;
        lines = [];
      }
    } else if (/^```\s*$/.test(line)) {
      blocks.push({ path, content: `${lines.join("\n")}\n` });
      path = null;
    } else {
      lines.push(line);
    }
  }
  return blocks;
}

export type ParsedAnswer =
  | {
      readonly ok: true;
      readonly manifest: AcceptanceManifest;
      readonly manifestJson: string;
      readonly files: readonly FileBlock[];
    }
  | { readonly ok: false; readonly problems: readonly string[] };

/** Splits the answer into the manifest and the test files, and checks that they agree. */
export function parseAnswer(text: string): ParsedAnswer {
  const blocks = extractBlocks(text);
  const manifests = blocks.filter((b) => b.path === MANIFEST_LABEL);
  if (manifests.length !== 1) {
    return {
      ok: false,
      problems: [`expected exactly one \`\`\`${MANIFEST_LABEL} block, found ${manifests.length}`],
    };
  }
  const manifestJson = manifests[0]?.content ?? "";
  const parsed = parseManifest(manifestJson);
  if (!parsed.ok) return parsed;
  const files = blocks.filter((b) => b.path !== MANIFEST_LABEL);
  const problems = fileProblems(parsed.manifest, files);
  if (problems.length > 0) return { ok: false, problems };
  return { ok: true, manifest: parsed.manifest, manifestJson, files };
}

function fileProblems(manifest: AcceptanceManifest, files: readonly FileBlock[]): string[] {
  if (manifest.kind === "not_testable") {
    return files.length > 0 ? ["not_testable answers must not include test files"] : [];
  }
  const problems: string[] = [];
  const byPath = new Map<string, FileBlock>();
  for (const f of files) {
    if (byPath.has(f.path)) problems.push(`${f.path}: given twice`);
    byPath.set(f.path, f);
  }
  const listed = new Set(manifest.tests.map((t) => t.path));
  for (const f of files) {
    if (!listed.has(f.path))
      problems.push(`${f.path}: file is not listed in acceptance.json tests`);
    if (f.content.length > MANIFEST_LIMITS.fileBytes) problems.push(`${f.path}: file is too large`);
  }
  for (const t of manifest.tests) {
    const file = byPath.get(t.path);
    if (!file) {
      problems.push(`${t.path}: listed in acceptance.json but no file block was given`);
      continue;
    }
    for (const c of untracedCriteria(t, file.content)) {
      problems.push(`${t.path}: claims ${c} but never mentions it (put the id in the test title)`);
    }
  }
  return problems;
}
