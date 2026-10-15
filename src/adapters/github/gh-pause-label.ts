import { z } from "zod";
import { PAUSE_LABEL, type PauseLabel } from "../../contexts/orchestration";
import type { AdapterError, ProcessRunner } from "../../shared/kernel/ports";
import { ok, type Result } from "../../shared/kernel/result";
import { runGhJson } from "./gh-json";

export class GhPauseLabel implements PauseLabel {
  constructor(private readonly runner: ProcessRunner) {}

  async labelled(): Promise<Result<readonly number[], AdapterError>> {
    const argv = ["gh", "issue", "list", "--state", "open", "--label", PAUSE_LABEL];
    const schema = z.array(z.object({ number: z.number() }));
    const r = await runGhJson(this.runner, [...argv, "--limit", "20", "--json", "number"], schema);
    return r.ok ? ok(r.value.map((i) => i.number)) : r;
  }
}
