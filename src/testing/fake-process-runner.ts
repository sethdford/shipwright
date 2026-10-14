import type { ProcessRequest, ProcessResult, ProcessRunner } from "../shared/kernel/ports";

export interface ScriptedCall {
  readonly prefix: readonly string[];
  readonly result: Omit<ProcessResult, "timedOut"> & { readonly timedOut?: boolean };
}

export class FakeProcessRunner implements ProcessRunner {
  readonly calls: ProcessRequest[] = [];

  constructor(private readonly script: readonly ScriptedCall[]) {}

  async run(request: ProcessRequest): Promise<ProcessResult> {
    this.calls.push(request);
    const match = this.script.find((s) => s.prefix.every((part, i) => request.argv[i] === part));
    if (!match) throw new Error(`unscripted command: ${request.argv.join(" ")}`);
    return { timedOut: false, ...match.result };
  }
}
