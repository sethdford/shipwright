import type { ProcessRequest, ProcessResult, ProcessRunner } from "../shared/kernel/ports";

export interface ScriptedCall {
  readonly prefix: readonly string[];
  readonly result: Omit<ProcessResult, "timedOut"> & { readonly timedOut?: boolean };
}

export class FakeProcessRunner implements ProcessRunner {
  private readonly recorded: ProcessRequest[] = [];

  constructor(private readonly script: readonly ScriptedCall[]) {
    for (const call of script) {
      if (call.prefix.length === 0) {
        throw new Error("empty prefix would match every command");
      }
    }
  }

  get calls(): readonly ProcessRequest[] {
    return this.recorded;
  }

  async run(request: ProcessRequest): Promise<ProcessResult> {
    this.recorded.push(request);
    const match = this.script.find((s) => s.prefix.every((part, i) => request.argv[i] === part));
    if (!match) throw new Error(`unscripted command: ${request.argv.join(" ")}`);
    return { timedOut: false, ...match.result };
  }
}
