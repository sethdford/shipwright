/** A validation outcome: a value, or the reason the input was rejected. */
export type Parsed<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly reason: string };

export const accept = <T>(value: T): Parsed<T> => ({ ok: true, value });
export const reject = <T>(reason: string): Parsed<T> => ({ ok: false, reason });

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** An argv list: a non-empty array of non-empty strings. */
export function isArgv(value: unknown): value is readonly string[] {
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.every((v) => typeof v === "string" && v.length > 0)
  );
}

export function isArgvList(value: unknown): value is readonly (readonly string[])[] {
  return Array.isArray(value) && value.every(isArgv);
}
