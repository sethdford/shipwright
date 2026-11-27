// Reads the files behind the Quality tab. Read-only, no subprocesses: every source is a file that a
// shipwright command or the bash pipeline already writes. Missing or unreadable files read as
// empty, so the tab shows what exists and says what to run for the rest.
import { existsSync, readFileSync, statSync } from "fs";
import { join } from "path";
import { buildQualitySummary, parseJsonLines, type QualitySummary } from "./quality.js";

/** Largest tail of events.jsonl the tab reads, so a long-lived log cannot stall the server. */
const MAX_EVENT_BYTES = 4 * 1024 * 1024;

export interface QualityPaths {
  eventsFile: string;
  routingLog: string;
  verifierModel: string;
  scorecardFile: string;
}

/** Paths for a home directory and an optional SHIPWRIGHT_STATE_DIR (TypeScript commands use it). */
export function qualityPaths(home: string, stateDir?: string): QualityPaths {
  const legacy = join(home, ".shipwright");
  const state = stateDir && stateDir.startsWith("/") ? stateDir : legacy;
  return {
    eventsFile: join(legacy, "events.jsonl"),
    routingLog: join(state, "routing", "decisions.jsonl"),
    verifierModel: join(state, "verifier", "model.json"),
    scorecardFile: join(state, "scorecard.json"),
  };
}

function readText(path: string, maxBytes?: number): string {
  try {
    if (!existsSync(path)) return "";
    const text = readFileSync(path, "utf-8");
    if (maxBytes === undefined || text.length <= maxBytes) return text;
    const tail = text.slice(text.length - maxBytes);
    return tail.slice(tail.indexOf("\n") + 1);
  } catch {
    return "";
  }
}

function readJson(path: string): unknown {
  const text = readText(path);
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function mtimeIso(path: string): string | null {
  try {
    return existsSync(path) ? statSync(path).mtime.toISOString() : null;
  } catch {
    return null;
  }
}

export function loadQualitySummary(
  paths: QualityPaths,
  windowDays: number,
  nowMs: number = Date.now(),
): QualitySummary {
  return buildQualitySummary({
    nowMs,
    windowDays,
    events: parseJsonLines(readText(paths.eventsFile, MAX_EVENT_BYTES)),
    routing: parseJsonLines(readText(paths.routingLog)),
    verifierModel: readJson(paths.verifierModel),
    scorecard: readJson(paths.scorecardFile),
    scorecardSavedAt: mtimeIso(paths.scorecardFile),
  });
}

/** Window in days from a query value: 1 to 365, default 30. */
export function parseWindowDays(value: string | null): number {
  const n = value === null ? NaN : Number(value);
  return Number.isInteger(n) && n >= 1 && n <= 365 ? n : 30;
}
