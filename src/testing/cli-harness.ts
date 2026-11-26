import type { CliIO, CommandContext } from "../cli/command";
import type { DeliveryPorts } from "../contexts/delivery";
import type { RepoDocs } from "../contexts/governance";
import type { LineChannel, RepoModelPorts, RoutingPorts } from "../contexts/intelligence";
import type { SafetyPorts } from "../contexts/orchestration";
import type { AcceptancePorts } from "../contexts/planning";
import type { BenchFactory, QualityPorts, VerifierPorts } from "../contexts/quality";
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

/** A getter that throws unless the test supplied the dependency. */
function given<T>(value: T | undefined, what: string): () => T {
  return () => {
    if (value === undefined) throw new Error(`this command was not given ${what}`);
    return value;
  };
}

/** A command context. Each port getter throws unless the test gave it (commands that use none need none). */
export function commandContext(
  io: CliIO,
  safety?: SafetyPorts,
  env: Readonly<Record<string, string | undefined>> = {},
  files?: FileReader,
  ports: {
    readonly repoDocs?: RepoDocs;
    readonly quality?: QualityPorts;
    readonly routing?: RoutingPorts;
    readonly bench?: BenchFactory;
    readonly verifier?: VerifierPorts;
    readonly delivery?: DeliveryPorts;
    readonly repoModel?: RepoModelPorts;
    readonly stdio?: LineChannel;
    readonly acceptance?: (root?: string) => AcceptancePorts;
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
    delivery: given(ports.delivery, "delivery ports"),
    bench: given(ports.bench, "bench ports"),
    verifier: given(ports.verifier, "verifier ports"),
    routing: given(ports.routing, "routing ports"),
    repoModel: given(ports.repoModel, "repository model ports"),
    stdio: given(ports.stdio, "a stdio channel"),
    acceptance: (root) => given(ports.acceptance, "acceptance ports")()(root),
  };
}
