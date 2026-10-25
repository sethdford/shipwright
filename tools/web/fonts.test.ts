import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..", "..");
const DASHBOARD_FONTS = join(ROOT, "dashboard/public/fonts");
const fontsCss = readFileSync(join(DASHBOARD_FONTS, "fonts.css"), "utf8");

test("dashboard fonts.css only declares local woff2 files that exist", () => {
  const urls = [...fontsCss.matchAll(/url\("([^"]+)"\)/g)].map((m) => m[1]);
  expect(urls.length).toBeGreaterThan(0);
  for (const url of urls) {
    expect(url.startsWith("/fonts/")).toBe(true);
    expect(url.endsWith(".woff2")).toBe(true);
    expect(existsSync(join(DASHBOARD_FONTS, url.slice("/fonts/".length)))).toBe(true);
  }
});

test("dashboard never declares Instrument Serif", () => {
  expect(fontsCss).not.toContain('font-family: "Instrument Serif"');
});

test("every dashboard font file has its OFL licence and sources listed", () => {
  for (const file of ["plus-jakarta-sans-latin-var.woff2", "jetbrains-mono-latin-var.woff2"]) {
    expect(existsSync(join(DASHBOARD_FONTS, file))).toBe(true);
  }
  const sources = readFileSync(join(DASHBOARD_FONTS, "SOURCES.md"), "utf8");
  expect(sources).toContain("plus-jakarta-sans-latin-var.woff2");
  expect(sources).toContain("jetbrains-mono-latin-var.woff2");
  expect(readFileSync(join(DASHBOARD_FONTS, "OFL-PlusJakartaSans.txt"), "utf8")).toContain(
    "SIL OPEN FONT LICENSE",
  );
  expect(readFileSync(join(DASHBOARD_FONTS, "OFL-JetBrainsMono.txt"), "utf8")).toContain(
    "SIL OPEN FONT LICENSE",
  );
});
