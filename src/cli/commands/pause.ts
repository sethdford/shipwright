import { pause, readPause, resume } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, isHelp, usageError } from "../shared";

const pauseUsage = `USAGE
  shipwright pause [REASON...]

DESCRIPTION
  Kill switch (spec §6.2, ADR-0007): sets the local pause flag (~/.shipwright/daemon-pause.flag,
  shared with the bash daemon). No dispatch happens on this machine until \`shipwright resume\`.
  To stop every machine and CI, add the shipwright:pause label to any open issue.

EXAMPLES
  shipwright pause investigating the 2026-10-13 failure loop`;

const resumeUsage = `USAGE
  shipwright resume

DESCRIPTION
  Clears the local pause flag. A shipwright:pause label on an open issue still pauses dispatch.`;

const pausedUsage = `USAGE
  shipwright paused [--no-github]

DESCRIPTION
  Exits 0 when dispatch is paused (local flag or shipwright:pause label), 1 when it is not.
  Fails closed: when the flag or the label cannot be read, it reports paused (exit 0).

OPTIONS
  --no-github   Check only the local flag

EXAMPLES
  shipwright paused || dispatch_next_issue`;

export const pauseCommand: Command = {
  name: "pause",
  aliases: [],
  summary: "Kill switch: pause dispatch on this machine",
  usage: pauseUsage,
  async run(args, { io, safety }) {
    if (isHelp(args[0])) {
      io.out(pauseUsage);
      return 0;
    }
    const reason = args.join(" ").trim() || "paused with shipwright pause";
    const r = await pause(safety(), reason);
    if (!r.ok) return adapterFailure(io, "pause", r.error);
    io.out(`✓ paused: ${reason}`);
    return 0;
  },
};

export const resumeCommand: Command = {
  name: "resume",
  aliases: [],
  summary: "Clear the local pause flag",
  usage: resumeUsage,
  async run(args, { io, safety }) {
    if (isHelp(args[0])) {
      io.out(resumeUsage);
      return 0;
    }
    if (args.length > 0) return usageError(io, resumeUsage, `Unknown arguments: ${args.join(" ")}`);
    const r = await resume(safety());
    if (!r.ok) return adapterFailure(io, "resume", r.error);
    io.out("✓ local pause flag cleared");
    io.out("  A shipwright:pause label on any open issue still pauses dispatch everywhere.");
    return 0;
  },
};

export const pausedCommand: Command = {
  name: "paused",
  aliases: [],
  summary: "Exit 0 when dispatch is paused (flag or label), 1 when not",
  usage: pausedUsage,
  async run(args, { io, safety }) {
    if (isHelp(args[0])) {
      io.out(pausedUsage);
      return 0;
    }
    const github = !args.includes("--no-github");
    if (args.some((a) => a !== "--no-github")) {
      return usageError(io, pausedUsage, `Unknown arguments: ${args.join(" ")}`);
    }
    const r = await readPause(safety(), { github });
    if (!r.ok) {
      adapterFailure(io, "pause", r.error);
      return 0; // fail closed: an unknown pause state counts as paused
    }
    io.out(r.value.paused ? `paused: ${r.value.reasons.join("; ")}` : "not paused");
    return r.value.paused ? 0 : 1;
  },
};
