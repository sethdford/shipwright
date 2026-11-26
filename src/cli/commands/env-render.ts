import type { HydrateOutcome, InitOutcome, ServiceOutcome } from "../../contexts/platform";
import type { CliIO } from "../command";

const secs = (ms: number) => `${(ms / 1000).toFixed(1)}s`;
const indent = (text: string) =>
  text
    .split("\n")
    .map((l) => `  | ${l}`)
    .join("\n");

const HYDRATE_LINES: Record<HydrateOutcome["status"], string> = {
  hit: "✓ environment restored from cache",
  built: "✓ environment built and cached",
  skipped: "· no cached environment for this checkout (restore-only: nothing ran)",
  "no-recipe": "· no recipe and nothing detectable: nothing to set up",
  invalid: "✗ recipe rejected",
  failed: "✗ environment setup failed",
};

export function renderHydrate(io: CliIO, o: HydrateOutcome, quiet: boolean): void {
  const ok = o.status !== "failed" && o.status !== "invalid";
  const say = ok ? io.out : io.err;
  if (quiet && ok) return;
  const where = o.key ? ` [${o.origin} recipe, key ${o.key.slice(0, 12)}]` : "";
  say(`${HYDRATE_LINES[o.status]}${where} in ${secs(o.durationMs)}`);
  for (const p of o.problems ?? []) say(`  - ${p}`);
  if (o.failure) {
    const how = o.failure.timedOut ? "timed out" : `exited ${o.failure.exitCode}`;
    say(`  command: ${JSON.stringify(o.failure.command)} ${how}`);
    say(indent(o.failure.tail));
  }
  if (o.saveError) io.err(`⚠ built, but the cache could not keep it: ${o.saveError}`);
}

export function renderInit(io: CliIO, o: InitOutcome, wrote: boolean): void {
  for (const a of o.attempts) {
    const line = `attempt ${a.n}: ${a.result}`;
    (a.result === "ready" ? io.out : io.err)(a.detail ? `${line}\n${indent(a.detail)}` : line);
  }
  if (o.error) io.err(`✗ ${o.error}`);
  if (o.costUsd > 0) io.out(`agent cost: $${o.costUsd.toFixed(2)}`);
  if (!o.ready) {
    io.err("✗ no recipe proved out; nothing was written");
    return;
  }
  io.out(`✓ recipe proved in a fresh clone${o.cached ? " and cached" : ""}`);
  for (const f of o.files) io.out(`  ${wrote ? "wrote" : "would write"} ${f.path}`);
  if (wrote) io.out("Review and commit these files; pipelines use the committed recipe.");
}

export function renderServices(io: CliIO, outcomes: readonly ServiceOutcome[]): void {
  if (outcomes.length === 0) io.out("· no services in the recipe");
  for (const s of outcomes) {
    const good = s.status === "ready" || s.status === "stopped" || s.status === "no-stop";
    (good ? io.out : io.err)(`${good ? "✓" : "✗"} ${s.name}: ${s.status}`);
    if (s.failure) io.err(indent(s.failure.tail));
  }
}
