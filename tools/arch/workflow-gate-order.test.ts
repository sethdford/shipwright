import { expect, test } from "bun:test";
import { findGateOrder } from "./workflow-gate-order";

const gates = (id: string, mode = "notice") => `      - id: ${id}
        uses: ./.github/actions/safety-gates
        with:
          retry: "0"
          github-token: x
          on-refusal: ${mode}
`;
const wf = (steps: string, on = "on:\n  issues:\n    types: [labeled]\n") =>
  `name: t\n${on}jobs:\n  job:\n    runs-on: ubuntu-latest\n    steps:\n${steps}`;

test("steps after a notice-mode gate must be conditioned on its allowed output", () => {
  const ok = wf(
    gates("gates") +
      `      - name: state
        if: steps.gates.outputs.allowed == 'true'
        run: echo
      - name: dispatch
        if: steps.gates.outputs.allowed == 'true' && steps.state.outputs.state == 'ready'
        run: echo
`,
  );
  expect(findGateOrder("a.yml", ok)).toEqual([]);
  const bad = wf(gates("gates") + "      - name: leak\n        run: echo leaked\n");
  const found = findGateOrder("a.yml", bad);
  expect(found.length).toBe(1);
  expect(found[0]).toContain("leak");
});

test("a notice-mode gate needs an id", () => {
  const noId = wf(`      - uses: ./.github/actions/safety-gates
        with:
          retry: "0"
          on-refusal: notice
`);
  expect(findGateOrder("a.yml", noId).join("\n")).toContain("needs an id");
});

test("fail-mode gates impose no ordering rule", () => {
  const fail = wf(gates("gates", "fail") + "      - name: after\n        run: echo\n");
  expect(findGateOrder("a.yml", fail)).toEqual([]);
});

test("dispatch-pipeline needs the gates earlier in the same job", () => {
  const dispatch = `      - id: d
        uses: ./.github/actions/dispatch-pipeline
        with:
          issue: "1"
          github-token: x
`;
  expect(findGateOrder("a.yml", wf(dispatch)).join("\n")).toContain("needs the gates earlier");
  expect(findGateOrder("a.yml", wf(gates("g", "fail") + dispatch))).toEqual([]);
});

test("shipwright-pipeline.yml: on: must be exactly workflow_dispatch", () => {
  const dispatchOnly = wf("      - run: echo\n", "on:\n  workflow_dispatch: {}\n");
  expect(findGateOrder(".github/workflows/shipwright-pipeline.yml", dispatchOnly)).toEqual([]);
  const labeled = wf("      - run: echo\n");
  expect(findGateOrder(".github/workflows/shipwright-pipeline.yml", labeled).join("\n")).toContain(
    "on: must be exactly workflow_dispatch",
  );
  const both = wf(
    "      - run: echo\n",
    "on:\n  workflow_dispatch: {}\n  issues:\n    types: [labeled]\n",
  );
  expect(findGateOrder(".github/workflows/shipwright-pipeline.yml", both).length).toBe(1);
  // Other workflows may use any trigger.
  expect(findGateOrder(".github/workflows/other.yml", labeled)).toEqual([]);
});
