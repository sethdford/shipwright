import type { CliIO, CommandContext } from "../cli/command";
import type { DeliveryPorts } from "../contexts/delivery";
import type { RepoDocs } from "../contexts/governance";
import type { SafetyPorts } from "../contexts/orchestration";
import type { QualityPorts, VerifierPorts } from "../contexts/quality";
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

/** A getter that returns `value`, or throws naming what the command was not given. */
function given<T>(value: T | undefined, what: string): () => T {
  return () => {
    if (value === undefined) throw new Error(`this command was not given ${what}`);
    return value;
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
    readonly verifier?: VerifierPorts;
    readonly delivery?: DeliveryPorts;
  } = {},
): CommandContext {
  return {
    io,
    version: "4.0.0",
    env,
    safety: given(safety, "safety ports"),
    files: given(files, "a file reader"),
    repoDocs: given(ports.repoDocs, "repository documents"),
    quality: given(ports.quality, "quality ports"),
    verifier: given(ports.verifier, "verifier ports"),
    delivery: given(ports.delivery, "delivery ports"),
  };
}
