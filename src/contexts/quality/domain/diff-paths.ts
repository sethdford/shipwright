/**
 * Paths in unified diff headers. Pure. Git C-quotes a path with special or non-ASCII characters
 * (`"b/caf\303\251.txt"`) and may end a `---`/`+++` path with a tab; both are undone here.
 */
const ESCAPES: Readonly<Record<string, string>> = {
  n: "\n",
  t: "\t",
  r: "\r",
  '"': '"',
  "\\": "\\",
  a: "\x07",
  b: "\b",
  f: "\f",
  v: "\v",
};

function unquote(q: string): string {
  const bytes: number[] = [];
  const enc = new TextEncoder();
  for (let i = 1; i < q.length - 1; i++) {
    const c = q[i] as string;
    if (c !== "\\") {
      bytes.push(...enc.encode(c));
      continue;
    }
    const oct = /^[0-7]{3}/.exec(q.slice(i + 1));
    if (oct) {
      bytes.push(Number.parseInt(oct[0], 8));
      i += 3;
    } else {
      const next = q[i + 1] ?? "";
      bytes.push(...enc.encode(ESCAPES[next] ?? next));
      i += 1;
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}

/** The repository path in a `--- a/x` or `+++ b/x` header value; null for `/dev/null`. */
export function headerPath(raw: string): string | null {
  const v = raw.replace(/\t.*$/, "").trimEnd();
  if (v === "/dev/null") return null;
  const path = v.startsWith('"') && v.endsWith('"') && v.length >= 2 ? unquote(v) : v;
  return path.replace(/^[ab]\//, "");
}
