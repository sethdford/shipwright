# Head-to-head benchmark

`shipwright bench` runs Shipwright, bare Claude Code and any other agent CLI on the same tasks,
from the same base commit, with the same model and time limit, and grades every run with tests the
agent never saw. Design and trade-offs: [ADR-0013](../adr/0013-head-to-head-benchmark.md).

## Quick start (holdout suite)

```bash
# 1. Mine tasks from merged PRs that close an issue, then keep only fair ones.
shipwright bench mine-holdout --repo sethdford/shipwright --since 2026-10-01 \
  --setup "bun install --frozen-lockfile" > ~/bench/holdout.json
shipwright bench validate --tasks ~/bench/holdout.json --out ~/bench/validate

# 2. See the run count and estimated spend. Nothing runs.
shipwright bench plan --tasks ~/bench/holdout.json --arms docs/benchmark/arms.example.json --trials 3

# 3. Run under a hard budget. Resumable: run it again to continue.
shipwright bench run --tasks ~/bench/holdout.json --arms docs/benchmark/arms.example.json \
  --out ~/bench/results --trials 3 --budget 150

# 4. Report: writes report.md, report.html and report.json into the results directory.
shipwright bench report --tasks ~/bench/holdout.json --arms docs/benchmark/arms.example.json \
  --out ~/bench/results --k 3
```

Set `SHIPWRIGHT_BENCH_BIN` to benchmark an installed Shipwright (for example `$(command -v shipwright)`)
instead of this checkout's `scripts/sw`. Stop the daemon while a benchmark runs: Shipwright's spend is read from the cost ledger for each
run's time window. Drop tasks that `validate` marks ✗ from the manifest before running.

## SWE-bench Verified

```bash
# Export the dataset once (needs the `datasets` package).
python -c "from datasets import load_dataset; load_dataset('princeton-nlp/SWE-bench_Verified', split='test').to_json('verified.jsonl')"
shipwright bench sample-swebench --from verified.jsonl --n 50 --seed 1 > ~/bench/swe50.json

shipwright bench run --tasks ~/bench/swe50.json --arms docs/benchmark/arms.example.json \
  --out ~/bench/swe --budget 300
# Grade each arm with the official harness (Docker), then import its report.
shipwright bench export-swebench --out ~/bench/swe --arm claude-code
python -m swebench.harness.run_evaluation --dataset_name princeton-nlp/SWE-bench_Verified \
  --predictions_path ~/bench/swe/predictions-claude-code-t1.jsonl --run_id claude-code-t1
shipwright bench import-swebench --out ~/bench/swe --arm claude-code \
  --report claude-code.claude-code-t1.json
```

## Arms file

```json
{ "baseline": "claude-code",
  "arms": [
    { "id": "claude-code", "kind": "claude-code", "model": "opus", "estimateUsd": 2.5 },
    { "id": "shipwright-k3", "kind": "shipwright", "model": "opus", "attempts": 3,
      "estimateUsd": 12, "timeoutMin": 120 },
    { "id": "aider", "kind": "command", "model": "opus", "estimateUsd": 2,
      "argv": ["aider", "--yes-always", "--model", "{model}", "--message-file", "{problem_file}"] }
  ] }
```

`estimateUsd` only drives `plan` and the budget stop; reported spend is what the report shows.
`env` takes `SHIPWRIGHT_*` and `PIPELINE_*` variables, for ablations such as
`{"SHIPWRIGHT_LESSONS": "off"}` or a lesson trial `{"SHIPWRIGHT_LESSONS_TRIAL": "L-0007"}`.
`bench export-eval --arm ID` then feeds `shipwright eval ratchet`.

## What the numbers mean

- **Resolve rate**: graded runs whose hidden tests all passed. Errors, timeouts and empty patches
  count as unresolved. The interval is a 95% Wilson interval.
- **pass^k**: the chance that k runs of the same task all pass (needs `--trials` ≥ k).
- **$ per resolved**: reported spend ÷ resolved runs, shown only when every run reported spend.
- **Paired comparison**: per task, wins, losses and ties against the baseline arm, with an exact
  two-sided sign test. With 30 tasks, 21 wins to 9 losses is roughly p = 0.04.

## Publishing rules

Publish the manifest name, task count, seed, arms file, model ids, dates and the full
`report.json`. Never publish a holdout manifest (it leaks the oracle). Report holdout results only
for tasks filed after the model's training cutoff, and say which cutoff you used.

## Paired A/B of one feature (repository model)

`arms.repo-model-ab.json` runs the same Shipwright three ways: the repository model off (the control),
on, and on with its semantic channel (ADR-0016). Run it on the holdout suite, then compare each arm to the
control in the report, or export both and apply the ratchet:

```bash
shipwright bench run --tasks ~/bench/holdout.json --arms docs/benchmark/arms.repo-model-ab.json \
  --out ~/bench/repo-model --trials 3 --budget 600
shipwright bench report --tasks ~/bench/holdout.json --arms docs/benchmark/arms.repo-model-ab.json \
  --out ~/bench/repo-model --k 3
shipwright bench export-eval --out ~/bench/repo-model --arm sw-model-off
shipwright bench export-eval --out ~/bench/repo-model --arm sw-model-on
shipwright eval ratchet --incumbent <off export> --candidate <on export> --k 3
```

Run the cheap localization check first; it needs no model spend:
`shipwright repomodel eval --export` with `SHIPWRIGHT_REPO_MODEL_SEMANTIC` off and on.
