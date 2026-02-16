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
