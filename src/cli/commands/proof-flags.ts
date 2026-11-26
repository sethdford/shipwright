import type { ProofMode } from "../../contexts/quality";

export type ProofFormat = "text" | "json" | "markdown";

export interface ProofFlags {
  readonly base: string;
  readonly mode: ProofMode;
  readonly publish: boolean;
  readonly label: string;
  readonly outDir: string | null;
  readonly video: boolean;
  readonly format: ProofFormat;
}

type Mutable = { -readonly [K in keyof ProofFlags]: ProofFlags[K] };
type Patch = Partial<Mutable> | string;

const REF = /^[A-Za-z0-9._/@^~-]{1,200}$/;
const LABEL = /^[A-Za-z0-9._/-]{1,100}$/;

export function proofModeOf(v: string | undefined): ProofMode | null {
  const m = (v ?? "").trim().toLowerCase();
  if (m === "") return "advisory";
  return m === "off" || m === "advisory" || m === "enforce" ? m : null;
}

const VALUED: Record<string, (v: string) => Patch> = {
  "--base": (v) => (REF.test(v) && !v.startsWith("-") ? { base: v } : "--base is not a git ref"),
  "--mode": (v) => {
    const m = proofModeOf(v);
    return m === null ? "--mode must be off, advisory or enforce" : { mode: m };
  },
  "--label": (v) => (LABEL.test(v) ? { label: v } : "--label: letters, digits, . _ / - only"),
  "--out": (v) => (v.trim() === "" ? "--out must be a directory" : { outDir: v }),
  "--format": (v) =>
    v === "text" || v === "json" || v === "markdown"
      ? { format: v }
      : "--format must be text, json or markdown",
};

const SWITCHES: Record<string, Partial<Mutable>> = {
  "--publish": { publish: true },
  "--no-publish": { publish: false },
  "--no-video": { video: false },
};

/** Parses `proof run|plan` options. `envMode` is SHIPWRIGHT_PROOF, the default for --mode. */
export function parseProofFlags(
  args: readonly string[],
  envMode: string | undefined,
): ProofFlags | string {
  const mode = proofModeOf(envMode);
  if (mode === null) return "SHIPWRIGHT_PROOF must be off, advisory or enforce";
  const flags: Mutable = {
    base: "origin/main",
    mode,
    publish: false,
    label: "local",
    outDir: null,
    video: true,
    format: "text",
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    const toggle = SWITCHES[arg];
    if (toggle) {
      Object.assign(flags, toggle);
      continue;
    }
    const parse = VALUED[arg];
    if (!parse) return `unknown option ${arg}`;
    const value = args[++i];
    if (value === undefined) return `${arg} needs a value`;
    const patch = parse(value);
    if (typeof patch === "string") return patch;
    Object.assign(flags, patch);
  }
  return flags;
}
