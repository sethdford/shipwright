// Design System Tokens
// Single source of truth for colors, typography, spacing, shadows, animations, and z-index.
// CSS custom properties mirror these values; Canvas2D code reads from here directly.

export const colors = {
  bg: {
    abyss: "#060a14",
    deep: "#0a1628",
    ocean: "#0d1f3c",
    surface: "#132d56",
    foam: "#1a3a6a",
  },
  accent: {
    cyan: "#00d4ff",
    cyanGlow: "rgba(0, 212, 255, 0.15)",
    cyanDim: "rgba(0, 212, 255, 0.4)",
    purple: "#7c3aed",
    purpleGlow: "rgba(124, 58, 237, 0.15)",
    blue: "#0066ff",
  },
  semantic: {
    success: "#4ade80",
    warning: "#fbbf24",
    error: "#f43f5e",
  },
  text: {
    primary: "#e8ecf4",
    secondary: "#8899b8",
    muted: "#5a6d8a",
  },
} as const;

export const fonts = {
  display: "'Instrument Serif', Georgia, serif",
  body: "'Plus Jakarta Sans', system-ui, sans-serif",
  mono: "'JetBrains Mono', 'SF Mono', monospace",
} as const;

export const typeScale = {
  display: { size: 32, weight: 400, family: fonts.display },
  heading: { size: 24, weight: 400, family: fonts.display },
  title: { size: 20, weight: 600, family: fonts.body },
  body: { size: 14, weight: 400, family: fonts.body },
  caption: { size: 12, weight: 500, family: fonts.body },
  tiny: { size: 11, weight: 400, family: fonts.body },
  mono: { size: 13, weight: 400, family: fonts.mono },
  monoSm: { size: 11, weight: 400, family: fonts.mono },
} as const;

export const spacing: Record<number, number> = {
  0: 0,
  1: 4,
  2: 8,
  3: 12,
  4: 16,
  5: 20,
  6: 24,
  8: 32,
  10: 40,
  12: 48,
  16: 64,
};

export const radius = {
  sm: 4,
  md: 8,
  lg: 12,
  xl: 16,
  full: 9999,
} as const;

export const shadows = {
  glow: {
    cyan: "0 0 20px rgba(0, 212, 255, 0.15)",
    purple: "0 0 20px rgba(124, 58, 237, 0.15)",
    success: "0 0 12px rgba(74, 222, 128, 0.2)",
    error: "0 0 12px rgba(244, 63, 94, 0.2)",
  },
  elevated: "0 8px 32px rgba(0, 0, 0, 0.4)",
} as const;

export const duration = {
  fast: 150,
  base: 300,
  slow: 500,
  glacial: 1000,
} as const;

export const easing = {
  default: "ease",
  smooth: "cubic-bezier(0.4, 0, 0.2, 1)",
  spring: "cubic-bezier(0.34, 1.56, 0.64, 1)",
} as const;

export const zIndex = {
  base: 1,
  dropdown: 10,
  sticky: 20,
  overlay: 30,
  modal: 40,
  toast: 50,
} as const;

export const STAGES = [
  "intake",
  "plan",
  "design",
  "build",
  "test",
  "review",
  "compound_quality",
  "pr",
  "merge",
  "deploy",
  "monitor",
] as const;

export type StageName = (typeof STAGES)[number];

export const STAGE_SHORT: Record<StageName, string> = {
  intake: "INT",
  plan: "PLN",
  design: "DSN",
  build: "BLD",
  test: "TST",
  review: "REV",
  compound_quality: "QA",
  pr: "PR",
  merge: "MRG",
  deploy: "DPL",
  monitor: "MON",
};

export const STAGE_COLORS: string[] = [
  "c-cyan",
  "c-blue",
  "c-purple",
  "c-green",
  "c-amber",
  "c-cyan",
  "c-blue",
  "c-purple",
  "c-green",
  "c-amber",
  "c-cyan",
];

export const STAGE_HEX: Record<StageName, string> = {
  intake: "#00d4ff",
  plan: "#0066ff",
  design: "#7c3aed",
  build: "#4ade80",
  test: "#fbbf24",
  review: "#00d4ff",
  compound_quality: "#0066ff",
  pr: "#7c3aed",
  merge: "#4ade80",
  deploy: "#fbbf24",
  monitor: "#00d4ff",
};

// ── OKLCH token contract (spec section 5, T1) ────────────────────────────────
// The source for dashboard/public/tokens.css and website/src/styles/tokens.css,
// rendered by ./tokens-css.ts and written by tools/web/gen-tokens.ts. The hex
// exports above stay for canvas code until T4 retires it; do not add new hex here.

export type Theme = "dark" | "light";

export const colourRoles = [
  "bg0",
  "bg1",
  "bg2",
  "line",
  "text1",
  "text2",
  "text3",
  "accent",
  "accentInk",
  "ok",
  "warn",
  "danger",
  "dangerInk",
  "info",
] as const;

export type ColourRole = (typeof colourRoles)[number];
export type ThemeColours = Record<ColourRole, string>;

// Dark is the default theme. Every pair the contrast test checks is listed in
// dashboard/src/design/tokens-contract.test.ts.
export const themes: Record<Theme, ThemeColours> = {
  dark: {
    bg0: "oklch(0.15 0.015 255)",
    bg1: "oklch(0.19 0.017 255)",
    bg2: "oklch(0.24 0.02 255)",
    line: "oklch(0.55 0.02 255)",
    text1: "oklch(0.96 0.005 255)",
    text2: "oklch(0.79 0.02 255)",
    text3: "oklch(0.67 0.025 255)",
    accent: "oklch(0.82 0.13 215)",
    accentInk: "oklch(0.15 0.015 255)",
    ok: "oklch(0.82 0.16 150)",
    warn: "oklch(0.86 0.15 85)",
    danger: "oklch(0.7 0.19 20)",
    dangerInk: "oklch(0.15 0.015 255)",
    info: "oklch(0.75 0.12 265)",
  },
  light: {
    bg0: "oklch(0.985 0.004 255)",
    bg1: "oklch(1 0 0)",
    bg2: "oklch(0.955 0.008 255)",
    line: "oklch(0.6 0.01 255)",
    text1: "oklch(0.2 0.02 255)",
    text2: "oklch(0.42 0.02 255)",
    text3: "oklch(0.5 0.02 255)",
    accent: "oklch(0.52 0.12 230)",
    accentInk: "oklch(0.99 0 0)",
    ok: "oklch(0.5 0.14 150)",
    warn: "oklch(0.5 0.13 70)",
    danger: "oklch(0.52 0.19 25)",
    dangerInk: "oklch(0.99 0 0)",
    info: "oklch(0.5 0.12 265)",
  },
};

export const elevation = {
  e1: "0 0 0 1px var(--sw-line)",
  e2: "0 1px 2px oklch(0 0 0 / 0.3)",
  e3: "0 12px 32px oklch(0 0 0 / 0.4)",
} as const;

export const sizeScale = {
  caption: "12px",
  body: "14px",
  bodyLarge: "16px",
  section: "20px",
  page: "24px",
  h2: "32px",
  h1: "clamp(48px, 6vw, 64px)",
} as const;

export const lineHeight = {
  body: "1.5",
  heading: "1.2",
  mono: "1.4",
} as const;

export const motion = {
  duration: { fast: "120ms", base: "200ms", slow: "320ms" },
  easing: {
    standard: "cubic-bezier(0.2, 0, 0, 1)",
    emphasized: "cubic-bezier(0.2, 0.8, 0.2, 1)",
  },
  // prefers-reduced-motion: opacity fades stay at 100 ms or less, transforms are removed.
  reduced: { duration: "100ms", travel: "0" },
} as const;
