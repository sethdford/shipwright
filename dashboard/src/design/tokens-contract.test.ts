import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { colourRoles, themes } from "./tokens";
import type { ColourRole, Theme } from "./tokens";
import { contrastRatio, parseOklch } from "./oklch";
import { cssVarName, renderTokensCss } from "./tokens-css";

// Pairs checked in both themes (spec 5.2 and 7). Text and status colours are
// used as text, so they need 4.5:1. Borders and other UI boundaries need 3:1.
const TEXT_ON_SURFACE: Array<[ColourRole, ColourRole]> = [
  ["text1", "bg0"],
  ["text1", "bg1"],
  ["text1", "bg2"],
  ["text2", "bg0"],
  ["text2", "bg1"],
  ["text2", "bg2"],
  ["text3", "bg0"],
  ["text3", "bg1"],
  ["text3", "bg2"],
  ["accent", "bg0"],
  ["accent", "bg1"],
  ["accent", "bg2"],
  ["ok", "bg0"],
  ["ok", "bg1"],
  ["ok", "bg2"],
  ["warn", "bg0"],
  ["warn", "bg1"],
  ["warn", "bg2"],
  ["danger", "bg0"],
  ["danger", "bg1"],
  ["danger", "bg2"],
  ["info", "bg0"],
  ["info", "bg1"],
  ["info", "bg2"],
  ["accentInk", "accent"],
];

const UI_BOUNDARY: Array<[ColourRole, ColourRole]> = [
  ["line", "bg0"],
  ["line", "bg1"],
];

const THEMES: Theme[] = ["dark", "light"];

// Paths are from the repo root, where bun run dashboard:test and CI both run.
const TOKENS_CSS = resolve(process.cwd(), "dashboard/public/tokens.css");
const WEBSITE_TOKENS_CSS = resolve(process.cwd(), "website/src/styles/tokens.css");

describe("OKLCH parsing", () => {
  it("parses L, C and hue", () => {
    expect(parseOklch("oklch(0.82 0.13 215)")).toEqual({ l: 0.82, c: 0.13, h: 215 });
  });

  it("rejects anything that is not an opaque oklch() colour", () => {
    expect(() => parseOklch("#00d4ff")).toThrow();
    expect(() => parseOklch("oklch(0 0 0 / 0.3)")).toThrow();
  });
});

describe("WCAG contrast", () => {
  it("is 21:1 for black on white and 1:1 for a colour on itself", () => {
    expect(contrastRatio("oklch(1 0 0)", "oklch(0 0 0)")).toBeCloseTo(21, 0);
    expect(contrastRatio("oklch(0.5 0.1 200)", "oklch(0.5 0.1 200)")).toBeCloseTo(1, 5);
  });
});

describe("token contract", () => {
  it("defines every colour role in both themes", () => {
    for (const theme of THEMES) {
      for (const role of colourRoles) {
        expect(themes[theme][role], `${theme}.${role}`).toMatch(/^oklch\(/);
      }
    }
  });

  for (const theme of THEMES) {
    describe(`${theme} theme contrast`, () => {
      it.each(TEXT_ON_SURFACE)("%s on %s meets 4.5:1", (fg, bg) => {
        const ratio = contrastRatio(themes[theme][fg], themes[theme][bg]);
        expect(ratio, `${fg} on ${bg} is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
      });

      it.each(UI_BOUNDARY)("%s on %s meets 3:1", (fg, bg) => {
        const ratio = contrastRatio(themes[theme][fg], themes[theme][bg]);
        expect(ratio, `${fg} on ${bg} is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(3);
      });
    });
  }

  it("keeps the dark-theme targets from spec 5.2", () => {
    const dark = themes.dark;
    expect(contrastRatio(dark.text1, dark.bg0)).toBeGreaterThanOrEqual(15);
    expect(contrastRatio(dark.text2, dark.bg0)).toBeGreaterThanOrEqual(7);
  });
});

describe("generated CSS drift", () => {
  const rendered = renderTokensCss();

  it("dashboard/public/tokens.css matches the generator output", () => {
    expect(readFileSync(TOKENS_CSS, "utf8")).toBe(rendered);
  });

  it("website/src/styles/tokens.css matches the generator output", () => {
    expect(readFileSync(WEBSITE_TOKENS_CSS, "utf8")).toBe(rendered);
  });

  it("declares every colour role for both themes", () => {
    for (const role of colourRoles) {
      expect(rendered).toContain(`${cssVarName(role)}: ${themes.dark[role]};`);
      expect(rendered).toContain(`${cssVarName(role)}: ${themes.light[role]};`);
    }
  });
});
