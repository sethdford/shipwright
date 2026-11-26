# Pipeline switches and ablation arms

Every behaviour added by ADR-0010 to ADR-0016 can be turned off or changed with an environment
variable, and most also with a pipeline-config key or a flag. This page lists them with their
defaults and where they are read.

**Why so many switches?** ADR-0009 rule 5: a policy change ships only through a paired ratchet.
To measure a feature, run the same eval cases with the switch at its default and at its control
value, then compare the two results files with `shipwright eval ratchet`. The `off` positions
exist for that measurement, and as escape hatches.

Precedence, where more than one source exists: **flag, then environment, then pipeline config,
then the default.** The pipeline config is the template JSON the run uses (`PIPELINE_CONFIG`: the first of
`templates/pipelines/<name>.json` in Shipwright, in the project, or in `~/.shipwright/pipelines/`).

## Build and verification

| Variable | Values (default first) | Config key / flag | Effect | Read in |
|---|---|---|---|---|
| `SW_ACCEPTANCE` | `enforce`, `warn`, `off` | `acceptance.mode` / `--acceptance <mode>`; `--tdd` = `enforce` | Spec-first acceptance tests before the build (ADR-0015). `enforce`: no proven-red tests after the allowed attempts stops the run, and a failing locked test or tampering fails the test stage. `warn`: report only. `off`: skip the stage (the ablation arm). | `scripts/lib/acceptance-tests.sh` |
| `SW_ACCEPTANCE_COMMAND` | unset | `acceptance.command` | A JSON argv that runs one test file, with `{file}`, `{dir}` or `{stem}`, for example `["bun","test","{file}"]`. Unset: derived from the project's test command when its shape is known. | `scripts/lib/acceptance-tests.sh` |
| (none) | `3` | `acceptance.attempts` | How many times the test writer may try to produce proven-red tests. | `scripts/lib/acceptance-tests.sh` |
| `PIPELINE_ATTEMPTS` | `1` | `defaults.attempts` | 2 to 5 runs the build as a tournament (`shipwright tournament`) when a test command is known. 1, or any value outside 2 to 5, keeps the single build loop. | `scripts/lib/pipeline-stages-build.sh` |
| `PIPELINE_TOURNAMENT_BUDGET_USD` | `15` (the command's default) | | Total model spend cap for one tournament: 80% shared by the attempts, 20% for the rubric, grading and judge. | `scripts/lib/pipeline-stages-build.sh` |
| `PIPELINE_SETUP_CMD` | unset | | Run once in each tournament worktree before the attempt (for example `bun install`). | `scripts/lib/pipeline-stages-build.sh` |
| `SHIPWRIGHT_VERIFIER` | `advisory`, `enforce`, `off` | `shipwright verify score --mode` | Merge verifier before PR creation (ADR-0012). `advisory` never blocks and reports what `enforce` would do. `enforce` blocks on hard stops at once, and on a predicted chance under 20% only when the model is trusted on factory PRs. A verifier that cannot run never blocks. | `scripts/lib/verifier-gate.sh` |
| `SHIPWRIGHT_VERIFIER_CRITIC` | `off`, `on` | | Adds a prompted critic to the verifier (it costs model calls), given the repository model's change-impact section when the model is on. Off by default. | `scripts/lib/verifier-gate.sh` |

## Routing and context

| Variable | Values (default first) | Effect | Read in |
|---|---|---|---|
| `SHIPWRIGHT_ROUTER` | `shadow`, `apply` (or `on`), `off` (or `0`, `false`, `no`) | Adaptive compute router (ADR-0014). `shadow` decides and logs, and changes nothing. `apply` also uses the route's template, model, effort and attempts wherever the caller set none, and exports `PIPELINE_ATTEMPTS` and `PIPELINE_TOURNAMENT_BUDGET_USD`. Any other value is logged as `router.bad_mode` and treated as `shadow`. | `scripts/lib/pipeline-router.sh` |
| `SHIPWRIGHT_REPO_MODEL` | `on`, `off` | Repository world model (ADR-0016). `off` gives no brief, attaches no MCP server, and the plan stage falls back to the grep-based architecture context. | `scripts/lib/repo-model.sh` |
| `SHIPWRIGHT_REPO_MODEL_SEMANTIC` | `off`, `on` | Adds a semantic channel (LSA over the files) to `localize`, `map` and the brief. Off by default; the arm is recorded with each brief. | `scripts/lib/repo-model.sh` |
| `SHIPWRIGHT_GOVERNANCE` | `on`, `off` | Governance pack (ADR-0010): accepted ADRs, policies and standards in the build brief, and the review checklist. Also `--no-governance` on `shipwright governance brief`. | `scripts/lib/governance-brief.sh`, `shipwright governance` |
| `SHIPWRIGHT_LESSONS` | `on`, `off` | Active repository lessons in the build brief. Also `--no-lessons`. | same |
| `SHIPWRIGHT_LESSONS_TRIAL` | unset | Comma-separated proposed lesson ids (`L-0007,L-0008`) treated as active for this run only: the trial arm of the self-improvement loop. Also `--trial`. | same |
| `SW_GOVERNANCE_REF` | unset | The commit the governance documents and lessons are read from. Unset: `origin/<base branch>`, else `<base branch>`. Never the work branch. | `scripts/lib/governance-brief.sh` |

## Trust boundary

| Variable | Values (default first) | Effect | Read in |
|---|---|---|---|
| `SW_PATCH_HANDOFF` | `true`, `false` | Patch handoff (ADR-0011). The build loop, or a whole tournament, runs in a disposable clone with no remote and no GitHub or fleet tokens, and its work is exported, judged and applied as a patch. `false` restores the shared-checkout build. | `scripts/lib/pipeline-stages-build.sh`, `scripts/lib/patch-handoff.sh` |
| `SW_UNTRUSTED_REVIEWED_LABEL` | `shipwright:input-reviewed` | The issue label with which a maintainer lets a refused issue through the injection gate after reading its raw text. | `scripts/lib/untrusted.sh` |

## Dashboard

| Variable | Default | Effect |
|---|---|---|
| `SW_DASHBOARD_HOST` | `127.0.0.1` | Bind address. Anything but loopback is an exposed dashboard: it needs GitHub OAuth and a fleet token. See [dashboard-exposure.md](../dashboard-exposure.md). |
| `DASHBOARD_REPO` | unset | `owner/name`. A GitHub admin of this repository signs in as a dashboard `admin` unless `rbac.json` says otherwise. |
| `SHIPWRIGHT_FLEET_TOKEN`, `SHIPWRIGHT_FLEET_TOKEN_FILE` | unset | The shared secret fleet workers use for presence and claim routes. Required for an exposed dashboard. |

## State and tooling

| Variable | Default | Effect |
|---|---|---|
| `SHIPWRIGHT_STATE_DIR` | `~/.shipwright` | State directory (absolute path). Holds `costs.json`, `events.jsonl`, `routing/decisions.jsonl`, `verifier/model.json`, `repo-model/`, `tournaments/` and more. |
| `SW_BUN` | `bun` | The Bun binary the bash pipeline uses to call TypeScript commands. |
| `SW_TS_CLI` | `<repo>/src/cli.ts` | The TypeScript CLI entry the bash pipeline calls. |
| `SHIPWRIGHT_BENCH_BIN` | `<repo>/scripts/sw` | The `shipwright` binary the benchmark's `shipwright` arm runs. |
| `SW_LEGACY_MODEL_ROUTING` | unset | `true` turns on the older learned model routing in bash. The compute router does not use it. |

## Where the results go

| File | Written by | Read by |
|---|---|---|
| `~/.shipwright/costs.json` | every pipeline run (`cost_record`) | `shipwright cost`, `shipwright scorecard`, the dashboard |
| `~/.shipwright/events.jsonl` | `emit_event` (for example `governance.brief`, `repo_model.brief`, `pr.verifier`, `build.tournament`, `acceptance.failed`, `intake.untrusted_refused`) | the dashboard, `shipwright activity` |
| `~/.shipwright/routing/decisions.jsonl` | `shipwright route decide` and `outcome` | `shipwright route stats`, the dashboard |
| `~/.shipwright/verifier/model.json` | `shipwright verify train` | `shipwright verify score` and `show` |
| `~/.shipwright/repo-model/<hash>.json` | any `shipwright repomodel` query | the same |
| `.claude/pipeline-artifacts/tournament.json` | the build stage in tournament mode | the PR body section, the dashboard |
| bench `DIR/results.jsonl` and `report.*` | `shipwright bench run` and `report` | `shipwright bench export-eval` |
