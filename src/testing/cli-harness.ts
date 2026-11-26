import type { CliIO, CommandContext } from "../cli/command";
import type { RepoDocs } from "../contexts/governance";
import type { RoutingPorts } from "../contexts/intelligence";
import type { SafetyPorts } from "../contexts/orchestration";
import type { QualityPorts } from "../contexts/quality";
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
  ports: {
    readonly repoDocs?: RepoDocs;
    readonly quality?: QualityPorts;
    readonly routing?: RoutingPorts;
  } = {},
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
    repoDocs: () => {
      if (!ports.repoDocs) throw new Error("this command was not given repository documents");
      return ports.repoDocs;
    },
    quality: () => {
      if (!ports.quality) throw new Error("this command was not given quality ports");
      return ports.quality;
    },
    routing: () => {
      if (!ports.routing) throw new Error("this command was not given routing ports");
      return ports.routing;
    },
  };
}
