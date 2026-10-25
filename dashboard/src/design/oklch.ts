// OKLCH colour maths for the token contract tests. Pure and dependency-free.
// Conversion follows the OKLab reference by Bjorn Ottosson (bottosson.github.io/posts/oklab).

export interface Oklch {
  l: number;
  c: number;
  h: number;
}

const OPAQUE_OKLCH = /^oklch\(\s*(\d*\.?\d+)\s+(\d*\.?\d+)\s+(\d*\.?\d+)\s*\)$/;

export function parseOklch(value: string): Oklch {
  const match = OPAQUE_OKLCH.exec(value.trim());
  if (!match) throw new Error(`Not an opaque oklch() colour: ${value}`);
  return { l: Number(match[1]), c: Number(match[2]), h: Number(match[3]) };
}

function clamp01(v: number): number {
  return Math.min(1, Math.max(0, v));
}

/** Linear-light sRGB channels in [0, 1]. Out-of-gamut values are clamped. */
export function oklchToLinearSrgb({ l, c, h }: Oklch): [number, number, number] {
  const rad = (h * Math.PI) / 180;
  const a = c * Math.cos(rad);
  const b = c * Math.sin(rad);
  const lms1 = l + 0.3963377774 * a + 0.2158037573 * b;
  const lms2 = l - 0.1055613458 * a - 0.0638541728 * b;
  const lms3 = l - 0.0894841775 * a - 1.291485548 * b;
  const L = lms1 ** 3;
  const M = lms2 ** 3;
  const S = lms3 ** 3;
  return [
    clamp01(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
    clamp01(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
    clamp01(-0.0041960863 * L - 0.7034186147 * M + 1.707614701 * S),
  ];
}

/** WCAG 2.x relative luminance. */
export function relativeLuminance(colour: string): number {
  const [r, g, b] = oklchToLinearSrgb(parseOklch(colour));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG 2.x contrast ratio, from 1 to 21. Order of arguments does not matter. */
export function contrastRatio(a: string, b: string): number {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  const [hi, lo] = la >= lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}
