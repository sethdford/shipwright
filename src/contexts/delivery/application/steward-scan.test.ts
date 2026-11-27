import { expect, test } from "bun:test";
import { FakeSteward } from "../../../testing/fake-steward";
import { scanChange } from "./steward-scan";

test("scanChange scans the diff against the base and reports the verdict", async () => {
  const patch = ["+++ b/src/a.ts", "@@ -0,0 +1,1 @@", "+debugger;"].join("\n");
  const fake = new FakeSteward({ patch });
  const r = await scanChange(fake.ports().change, "origin/dev");
  expect(fake.diffs).toEqual([{ base: "origin/dev", head: undefined }]);
  expect(r.ok && r.value.verdict).toBe("fix");
  expect(r.ok && r.value.findings.map((f) => f.line)).toEqual([1]);
  const clean = await scanChange(new FakeSteward().ports().change, "origin/main");
  expect(clean).toEqual({ ok: true, value: { verdict: "pass", findings: [] } });
  const broken = new FakeSteward({ failing: { diff: { kind: "failed", message: "no ref" } } });
  expect((await scanChange(broken.ports().change, "x")).ok).toBe(false);
});
