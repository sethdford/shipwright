// Writes the OKLCH token CSS to every consumer (dashboard and website).
// Usage: bun tools/web/gen-tokens.ts [--check]
//   --check  exit 1 if a committed CSS file differs from the generator output.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import type { TokenSurface } from "../../dashboard/src/design/tokens-css";
import { renderTokensCss } from "../../dashboard/src/design/tokens-css";

export const REPO_ROOT = resolve(import.meta.dir, "..", "..");

export const TOKEN_CSS_TARGETS: ReadonlyArray<{ path: string; surface: TokenSurface }> = [
  { path: "dashboard/public/tokens.css", surface: "dashboard" },
  { path: "website/src/styles/tokens.css", surface: "website" },
];

export function main(argv: string[]): number {
  const check = argv.includes("--check");
  let stale = false;
  for (const { path: rel, surface } of TOKEN_CSS_TARGETS) {
    const css = renderTokensCss(surface);
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
