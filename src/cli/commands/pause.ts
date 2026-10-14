import { pause, readPause, resume, sanitizeReason } from "../../contexts/orchestration";
import type { Command } from "../command";
import { adapterFailure, allowNoGithub, isHelp, isHelpRequest, usageError } from "../shared";

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
  shipwright paused --gate [--no-github]

DESCRIPTION
  For humans: exits 0 when dispatch is paused (local flag or shipwright:pause label), 1 when
  it is not. Fails closed: bad arguments or an unreadable flag or label report paused (exit 0).
  For scripts use --gate, where exit 0 means NOT paused and anything else (paused, unreadable,
  bad arguments, a missing shipwright) is non-zero, so a failure can never read as "go".

OPTIONS
  --gate        Gate form: exit 0 only when it is safe to dispatch
  --no-github   Check only the local flag (warns on stderr). Refused on GitHub Actions
                (GITHUB_ACTIONS set to anything but empty or "false"): exit 2 with --gate,
                0 (paused, fail closed) without it

EXAMPLES
  shipwright paused --gate && dispatch_next_issue`;

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
    const option = args.find((a) => a.startsWith("--"));
    if (option) return usageError(io, pauseUsage, `Unknown option: ${option}`);
    const reason = sanitizeReason(args.join(" ").trim()) || "paused with shipwright pause";
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
    const ports = safety();
    const had = await ports.pauseFlag.read();
    if (!had.ok) return adapterFailure(io, "resume", had.error);
    const r = await resume(ports);
    if (!r.ok) return adapterFailure(io, "resume", r.error);
    io.out(had.value ? "✓ local pause flag cleared" : "✓ no local pause flag was set");
    io.out("  A shipwright:pause label on any open issue still pauses dispatch everywhere.");
    return 0;
  },
};

export const pausedCommand: Command = {
  name: "paused",
  aliases: [],
  summary: "Exit 0 when dispatch is paused (flag or label), 1 when not",
  usage: pausedUsage,
  async run(args, { io, safety, env }) {
    if (isHelpRequest(args)) {
      io.out(pausedUsage);
      return 0;
    }
    const gate = args.includes("--gate");
    const github = !args.includes("--no-github");
    if (args.some((a) => a !== "--no-github" && a !== "--gate")) {
      // Gate form: usage error is non-zero (2). Human form fails closed (0 = paused).
      usageError(io, pausedUsage, `Unknown arguments: ${args.join(" ")}`);
      return gate ? 2 : 0;
    }
    if (!github && !allowNoGithub(io, pausedUsage, env, "shipwright:pause label")) {
      return gate ? 2 : 0;
    }
    try {
      const r = await readPause(safety(), { github });
      if (!r.ok) {
        adapterFailure(io, "pause", r.error);
        return gate ? 1 : 0; // fail closed: an unknown pause state counts as paused
      }
      const { paused, reasons } = r.value;
      if (gate) {
        io.out(paused ? `paused: ${reasons.join("; ")}` : "not paused");
        return paused ? 1 : 0;
      }
      io.out(paused ? `paused: ${reasons.join("; ")}` : "not paused");
      return paused ? 0 : 1;
    } catch (e) {
      io.err(`✗ pause: cannot verify: ${e instanceof Error ? e.message : String(e)}`);
      return gate ? 1 : 0;
    }
  },
};
