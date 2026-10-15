import { expect, test } from "bun:test";
import { findGateOrder, isGatedBy } from "./workflow-gate-order";

const gates = (id: string, mode = "notice") => `      - id: ${id}
        uses: ./.github/actions/safety-gates
        with:
          retry: "0"
          github-token: x
          on-refusal: ${mode}
`;
const dispatch = (cond: string | null) => `      - id: d
${cond === null ? "" : `        if: ${cond}\n`}        uses: ./.github/actions/dispatch-pipeline
        with:
          issue: "1"
          github-token: x
`;
const wf = (steps: string, on = "on:\n  issues:\n    types: [labeled]\n") =>
  `name: t\n${on}jobs:\n  job:\n    runs-on: ubuntu-latest\n    steps:\n${steps}`;
const GOOD = "steps.g.outputs.allowed == 'true'";

test("a notice-mode gate's later steps must carry the strict allowed term", () => {
  const ok = wf(
    gates("g") +
      `      - name: state
        if: ${GOOD}
        run: echo
      - name: dispatch
        if: ${GOOD} && steps.state.outputs.state == 'ready'
        run: echo
`,
  );
  expect(findGateOrder("a.yml", ok)).toEqual([]);
  const bare = wf(gates("g") + "      - name: leak\n        run: echo leaked\n");
  expect(findGateOrder("a.yml", bare).join("\n")).toContain("leak");
});

test("a notice-mode gate needs an id", () => {
  const noId = wf(`      - uses: ./.github/actions/safety-gates
        with:
          retry: "0"
          on-refusal: notice
`);
  expect(findGateOrder("a.yml", noId).join("\n")).toContain("needs an id");
});

test("fail-mode gates impose no ordering rule on other steps", () => {
  expect(
    findGateOrder("a.yml", wf(gates("g", "fail") + "      - name: after\n        run: echo\n")),
  ).toEqual([]);
});

test("dispatch-pipeline needs a gates step with an id earlier in the job", () => {
  expect(findGateOrder("a.yml", wf(dispatch(GOOD))).join("\n")).toContain(
    "needs a gates step with an id",
  );
});

test("dispatch-pipeline with no if: is not gated", () => {
  expect(findGateOrder("a.yml", wf(gates("g", "fail") + dispatch(null))).join("\n")).toContain(
    "must be gated",
  );
});

test("reviewer mutation: dispatch with if: always() after a fail-mode gate is caught", () => {
  expect(
    findGateOrder("a.yml", wf(gates("g", "fail") + dispatch("always()"))).join("\n"),
  ).toContain("must be gated");
});

test("reviewer mutation: dispatch with if: failure() after a fail-mode gate is caught", () => {
  expect(
    findGateOrder("a.yml", wf(gates("g", "fail") + dispatch("failure()"))).join("\n"),
  ).toContain("must be gated");
});

test("reviewer mutation: `need || x` is caught, in both rules", () => {
  expect(
    findGateOrder("a.yml", wf(gates("g", "fail") + dispatch(`${GOOD} || always()`))),
  ).not.toEqual([]);
  expect(
    findGateOrder(
      "a.yml",
      wf(gates("g") + `      - name: x\n        if: ${GOOD} || true\n        run: echo\n`),
    ),
  ).not.toEqual([]);
});

test("reviewer mutation: `!(need)` is caught, in both rules", () => {
  expect(findGateOrder("a.yml", wf(gates("g", "fail") + dispatch(`!(${GOOD})`)))).not.toEqual([]);
  expect(
    findGateOrder(
      "a.yml",
      wf(gates("g") + `      - name: x\n        if: "!(${GOOD})"\n        run: echo\n`),
    ),
  ).not.toEqual([]);
});

test("cancelled() and a negated term are caught; != is not negation", () => {
  expect(isGatedBy(`${GOOD} && cancelled()`, "g")).toBe(false);
  expect(isGatedBy(`${GOOD} && !steps.x.outputs.y`, "g")).toBe(false);
  expect(isGatedBy(`${GOOD} && steps.x.outputs.state != 'ready'`, "g")).toBe(true);
});

test("the exact term, &&-joined, is accepted", () => {
  expect(isGatedBy(GOOD, "g")).toBe(true);
  expect(isGatedBy(`steps.state.outputs.state == 'ready' && ${GOOD}`, "g")).toBe(true);
  expect(isGatedBy(`steps.g.outputs.allowed == 'false'`, "g")).toBe(false);
  expect(isGatedBy(`steps.other.outputs.allowed == 'true'`, "g")).toBe(false);
  expect(isGatedBy("", "g")).toBe(false);
});

test("shipwright-pipeline.yml: on: must be exactly workflow_dispatch", () => {
  const p = ".github/workflows/shipwright-pipeline.yml";
  expect(findGateOrder(p, wf("      - run: echo\n", "on:\n  workflow_dispatch: {}\n"))).toEqual([]);
  expect(findGateOrder(p, wf("      - run: echo\n")).join("\n")).toContain("on: must be exactly");
  expect(
    findGateOrder(
      p,
      wf("      - run: echo\n", "on:\n  workflow_dispatch: {}\n  issues:\n    types: [labeled]\n"),
    ).length,
  ).toBe(1);
  expect(findGateOrder(".github/workflows/other.yml", wf("      - run: echo\n"))).toEqual([]);
});
