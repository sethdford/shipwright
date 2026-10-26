import type { CliIO, CommandContext } from "../cli/command";
import type { SafetyPorts } from "../contexts/orchestration";
import type { FileReader } from "../shared/kernel/ports";

export interface CapturedIO extends CliIO {
  readonly outLines: string[];
  readonly errLines: string[];
}

export function captureIO(): CapturedIO {
  const outLines: string[] = [];
  const errLines: string[] = [];
  return {
    outLines,
    errLines,
    out: (t) => outLines.push(t),
    err: (t) => errLines.push(t),
  };
}

/** A command context. `files()` throws unless a reader is given (commands that read none need none). */
export function commandContext(
  io: CliIO,
  safety?: SafetyPorts,
  env: Readonly<Record<string, string | undefined>> = {},
  files?: FileReader,
): CommandContext {
  return {
    io,
    version: "4.0.0",
    env,
    safety: () => {
      if (!safety) throw new Error("this command was not given safety ports");
      return safety;
    },
    files: () => {
      if (!files) throw new Error("this command was not given a file reader");
      return files;
    },
  };
}
