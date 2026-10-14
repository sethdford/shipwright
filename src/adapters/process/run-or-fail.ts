import type { ProcessRequest, ProcessResult, ProcessRunner } from "../../shared/kernel/ports";

/**
 * Runs a request, converting a runner rejection (e.g. the executable does not exist) into a
 * 127 result so adapters can classify it like any other failure instead of rejecting.
 */
export async function runOrFail(
  runner: ProcessRunner,
  request: ProcessRequest,
): Promise<ProcessResult> {
  try {
    return await runner.run(request);
  } catch (e) {
    const errorMessage = e instanceof Error ? e.message : String(e);
    return {
      exitCode: 127,
      stdout: "",
      stderr: `${request.argv[0]}: ${errorMessage}`,
      timedOut: false,
    };
  }
}
