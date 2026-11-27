import type { CliIO, CommandContext } from "../cli/command";
import type { DeliveryPorts, StewardPorts } from "../contexts/delivery";
import type { RepoDocs } from "../contexts/governance";
import type { LineChannel, RepoModelPorts, RoutingPorts } from "../contexts/intelligence";
import type { SafetyPorts } from "../contexts/orchestration";
import type { AcceptancePorts } from "../contexts/planning";
import type { EnvPorts } from "../contexts/platform";
import type { BenchFactory, ProofPorts, QualityPorts, VerifierPorts } from "../contexts/quality";
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
    readonly steward?: StewardPorts;
    readonly repoModel?: RepoModelPorts;
    readonly stdio?: LineChannel;
    readonly acceptance?: (root?: string) => AcceptancePorts;
    readonly environments?: EnvPorts;
    readonly proof?: (outDir: string | null) => ProofPorts;
  } = {},
): CommandContext {
  return {
    io,
    version: "4.1.0",
    env,
    safety: given(safety, "safety ports"),
    files: given(files, "a file reader"),
    repoDocs: given(ports.repoDocs, "repository documents"),
    quality: given(ports.quality, "quality ports"),
    delivery: given(ports.delivery, "delivery ports"),
    steward: given(ports.steward, "steward ports"),
    bench: given(ports.bench, "bench ports"),
    verifier: given(ports.verifier, "verifier ports"),
    routing: given(ports.routing, "routing ports"),
    repoModel: given(ports.repoModel, "repository model ports"),
    stdio: given(ports.stdio, "a stdio channel"),
    environments: given(ports.environments, "environment ports"),
    acceptance: (root) => given(ports.acceptance, "acceptance ports")()(root),
    proof: (outDir) => given(ports.proof, "proof ports")()(outDir),
  };
}
