// Writes the OKLCH token CSS to every consumer (dashboard and website).
// Usage: bun tools/web/gen-tokens.ts [--check]
//   --check  exit 1 if a committed CSS file differs from the generator output.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { renderTokensCss } from "../../dashboard/src/design/tokens-css";

export const REPO_ROOT = resolve(import.meta.dir, "..", "..");

export const TOKEN_CSS_TARGETS = [
  "dashboard/public/tokens.css",
  "website/src/styles/tokens.css",
] as const;

export function main(argv: string[]): number {
  const css = renderTokensCss();
  const check = argv.includes("--check");
  let stale = false;
  for (const rel of TOKEN_CSS_TARGETS) {
    const abs = resolve(REPO_ROOT, rel);
    if (check) {
      const current = existsSync(abs) ? readFileSync(abs, "utf8") : "";
      if (current !== css) {
        console.error(`stale: ${rel} (run bun run web:tokens)`);
        stale = true;
      }
      continue;
    }
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, css);
    console.log(`wrote ${rel}`);
  }
  return stale ? 1 : 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
