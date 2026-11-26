import { canonicalJson, type EnvRecipe } from "./env-recipe";

/** Everything that decides whether a cached environment fits a checkout (ADR-0020). */
export interface KeyInput {
  readonly recipe: EnvRecipe;
  /** Content digest of each key file in the checkout, null when the file is missing. */
  readonly keyFiles: Readonly<Record<string, string | null>>;
  /** Trimmed stdout of each fingerprint command, in recipe order. */
  readonly fingerprints: readonly string[];
  readonly os: string;
  readonly arch: string;
}

/** Bump when the cache layout or key material changes, so old entries are never restored. */
export const KEY_SCHEMA = 1;

/**
 * The text whose digest is the cache key. Only fields that change what setup produces go in:
 * the smoke and test commands and the services do not, so editing them keeps the cache warm.
 */
export function keyMaterial(input: KeyInput): string {
  const { recipe } = input;
  return canonicalJson({
    schema: KEY_SCHEMA,
    setup: recipe.setup,
    cache: recipe.cache,
    env: recipe.env,
    keyFiles: input.keyFiles,
    fingerprints: input.fingerprints,
    os: input.os,
    arch: input.arch,
  });
}

/** Cache keys are lowercase hex; shorter forms are a prefix of the digest. */
export const KEY_LENGTH = 32;
export function isCacheKey(s: string): boolean {
  return new RegExp(`^[0-9a-f]{${KEY_LENGTH}}$`).test(s);
}
