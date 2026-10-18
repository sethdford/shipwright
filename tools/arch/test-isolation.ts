import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, trackedFiles } from "./rule-catalog";

/**
 * Test isolation rule (#8648). Every bash suite (`scripts/*-test.sh`, which includes
 * `scripts/sw-lib-*-test.sh`) must make a reachable call to `sw_test_isolate` before any EXIT trap is
 * set, so a suite run directly cannot reach the developer's tmux server, HOME or process tree:
 * - a reachable `sw_test_isolate` call exists: not inside a heredoc, not after an unconditional
 *   top-level `exit`, and not only inside a function that nothing outside its body calls;
 * - every trap that includes EXIT (or 0) ends with `sw_test_teardown`, because bash keeps one trap per
 *   signal; multi-signal traps (`trap x EXIT INT TERM`) count;
 * - no EXIT trap comes before the reachable isolation call, and no trap resets EXIT.
 * The scanner works on logical lines: continued lines are joined, comments and heredoc bodies are
 * dropped, and quoted text is opaque. Error severity, no baseline.
 */
export const SUITE_GLOBS = ["scripts/*-test.sh", "scripts/sw-lib-*-test.sh"];

interface Logical {
  line: number; // 1-based line of the first physical line
  stripped: string; // comment-free text, quotes intact
  code: string; // comment-free text with quoted strings and ${...} blanked out
}

const HEREDOC = /(?<!<)<<(-?)\s*(['"]?)([A-Za-z_]\w*)\2/;

/** Remove a trailing comment, honouring quotes; `$#` is not a comment. */
function stripComment(s: string): string {
  let q: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q && !(q === '"' && s[i - 1] === "\\")) q = null;
    } else if (c === "'" || c === '"') {
      q = c;
    } else if (c === "#" && (i === 0 || /[\s;&|(]/.test(s[i - 1] ?? ""))) {
      return s.slice(0, i).trimEnd();
    }
  }
  return s;
}

/** Blank quoted strings and ${...} so braces and words inside them do not count as code. */
function codeOf(s: string): string {
  return s
    .replace(/'[^']*'/g, "''")
    .replace(/"(?:\\.|[^"\\])*"/g, '""')
    .replace(/\$\{[^}]*\}/g, "x");
}

/** Split into logical lines, dropping heredoc bodies. */
export function logicalLines(text: string): Logical[] {
  const out: Logical[] = [];
  let heredoc: { end: string; strip: boolean } | null = null;
  let joined = "";
  let joinedAt = 0;
  text.split("\n").forEach((raw, i) => {
    if (heredoc) {
      if ((heredoc.strip ? raw.replace(/^\t+/, "") : raw) === heredoc.end) heredoc = null;
      return;
    }
    if (joined === "") joinedAt = i + 1;
    if (raw.endsWith("\\")) {
      joined += `${raw.slice(0, -1)} `;
      return;
    }
    const full = joined + raw;
    joined = "";
    const stripped = stripComment(full);
    const h = HEREDOC.exec(stripped);
    if (h) heredoc = { end: h[3] ?? "", strip: h[1] === "-" };
    out.push({ line: joinedAt, stripped, code: codeOf(stripped).trim() });
  });
  return out;
}

/** Split a line into words, keeping quotes, so a trap's body can be read. */
function words(s: string): string[] {
  const out: string[] = [];
  let cur = "";
  let q: string | null = null;
  for (const c of s) {
    if (q) {
      cur += c;
      if (c === q) q = null;
    } else if (c === "'" || c === '"') {
      q = c;
      cur += c;
    } else if (/\s/.test(c)) {
      if (cur) out.push(cur);
      cur = "";
    } else {
      cur += c;
    }
  }
  if (cur) out.push(cur);
  return out;
}

/** Split a comment-free line into simple commands at ; & | ( ) outside quotes. */
function commands(s: string): string[] {
  const out: string[] = [];
  let cur = "";
  let q: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i] ?? "";
    if (q) {
      cur += c;
      if (c === q && !(q === '"' && s[i - 1] === "\\")) q = null;
    } else if (c === "'" || c === '"') {
      q = c;
      cur += c;
    } else if (";&|()".includes(c)) {
      out.push(cur);
      cur = "";
    } else {
      cur += c;
    }
  }
  out.push(cur);
  return out;
}

const PREFIXES = new Set([
  "builtin",
  "command",
  "!",
  "then",
  "do",
  "else",
  "elif",
  "if",
  "while",
  "until",
  "time",
  "{",
  "}",
]);
/** Words of a simple command after reserved words and `builtin`/`command` prefixes. */
function invocation(cmd: string): string[] {
  const w = words(cmd);
  let i = 0;
  while (i < w.length && PREFIXES.has(w[i] ?? "")) i++;
  return w.slice(i);
}

const unquote = (w: string): string => (/^(['"]).*\1$/s.test(w) ? w.slice(1, -1) : w);
const BLOCK_OPEN = /^(if|while|until|for|select)\b|^case\b/;
const BLOCK_CLOSE = /^(fi|done|esac)\b/;
const FN_HEADER =
  /^(?:function\s+([A-Za-z_][\w.-]*)\s*(?:\(\s*\))?|([A-Za-z_][\w.-]*)\s*\(\s*\))\s*(\{)?/;

export function findIsolationViolations(file: string, text: string): string[] {
  const lines = logicalLines(text);
  const out: string[] = [];
  const fns: { name: string; start: number; end: number }[] = [];
  const stack: { name: string; level: number; start: number }[] = [];
  let depth = 0;
  let blocks = 0;
  let exitAt: number | null = null;
  const isolates: { line: number; fn: string | null }[] = [];
  const traps: { line: number; body: string; signals: string[]; reset: boolean }[] = [];

  let pendingFn: string | null = null; // a function header whose `{` is on a later line
  for (const l of lines) {
    const header = FN_HEADER.exec(l.code);
    if (header) pendingFn = header[1] ?? header[2] ?? null;
    if (stack.length === 0 && blocks === 0 && exitAt === null && /^exit\b/.test(l.code))
      exitAt = l.line;
    for (const cmd of commands(l.stripped)) {
      const inv = invocation(cmd);
      if (inv[0] === "sw_test_isolate")
        isolates.push({ line: l.line, fn: stack.at(-1)?.name ?? null });
      if (inv[0] === "trap") {
        const body = inv[1] ?? "";
        const signals = inv
          .slice(2)
          .map((x) => unquote(x).toUpperCase().replace(/^SIG/, ""))
          .map((x) => (x === "0" ? "EXIT" : x));
        traps.push({ line: l.line, body: unquote(body), signals, reset: body === "-" });
      }
    }
    for (const c of l.code.matchAll(/(?:^|[\s;(])([{}])(?=$|[\s;)])/g)) {
      if (c[1] === "{") {
        depth++;
        if (pendingFn !== null) {
          stack.push({ name: pendingFn, level: depth, start: l.line });
          pendingFn = null;
        }
      } else {
        const top = stack.at(-1);
        if (top && top.level === depth) {
          fns.push({ name: top.name, start: top.start, end: l.line });
          stack.pop();
        }
        depth--;
      }
    }
    if (BLOCK_CLOSE.test(l.code) && !BLOCK_OPEN.test(l.code)) blocks = Math.max(0, blocks - 1);
    else if (BLOCK_OPEN.test(l.code) && !/\b(fi|done|esac)\s*$/.test(l.code)) blocks++;
  }

  const reachable = isolates.filter((c) => {
    if (exitAt !== null && c.line > exitAt) return false;
    if (c.fn === null) return true;
    // Inside a function: reachable only if something outside that function's body calls it.
    const name = c.fn;
    const body = fns.filter((f) => f.name === name);
    return lines.some((l) => {
      if (body.some((f) => l.line >= f.start && l.line <= f.end)) return false;
      return new RegExp(`(^|[\\s;&|(])${name.replace(/[.-]/g, "\\$&")}(?=$|[\\s;&|)])`).test(
        l.code,
      );
    });
  });

  if (isolates.length === 0) {
    out.push(
      `TEST-ISOLATION ${file} — add \`sw_test_isolate\` on its own line right after the harness is sourced (#8648).`,
    );
  } else if (reachable.length === 0) {
    out.push(
      `TEST-ISOLATION ${file}:${isolates[0]?.line ?? 1} — \`sw_test_isolate\` is unreachable (heredoc, after a top-level exit, or in an uncalled function); move it to top level (#8648).`,
    );
  }
  const firstIsolate = reachable[0]?.line ?? Number.POSITIVE_INFINITY;
  for (const t of traps) {
    if (!t.signals.includes("EXIT")) continue;
    if (t.reset) {
      out.push(
        `TEST-ISOLATION ${file}:${t.line} — do not reset the EXIT trap; end it with \`; sw_test_teardown\` (#8648).`,
      );
      continue;
    }
    if (!/(^|[\s;&|(])sw_test_teardown(?=$|[\s;&|)])/.test(t.body)) {
      out.push(
        `TEST-ISOLATION ${file}:${t.line} — EXIT trap must end with the teardown: trap '<cleanup>; sw_test_teardown' EXIT (#8648).`,
      );
    }
    if (t.line < firstIsolate) {
      out.push(
        `TEST-ISOLATION ${file}:${t.line} — move \`sw_test_isolate\` above this EXIT trap so the trap is not replaced (#8648).`,
      );
    }
  }
  return out;
}

export async function scan(root = ROOT): Promise<string[]> {
  const files = (await trackedFiles(root)).filter((f) =>
    SUITE_GLOBS.some((g) => new Bun.Glob(g).match(f)),
  );
  return files.flatMap((f) => findIsolationViolations(f, readFileSync(join(root, f), "utf8")));
}

if (import.meta.main) {
  const found = await scan();
  for (const f of found) console.error(f);
  process.exit(found.length ? 1 : 0);
}
