# Shipwright Policy Configuration

**Location:** `config/policy.json` (repo) or `~/.shipwright/policy.json` (user override)

All tunable policy — timeouts, limits, thresholds — should live in policy config. Scripts may still have in-code defaults for backwards compatibility but should prefer policy when present. Adaptive/learned values (e.g. from `~/.shipwright/adaptive-*.json`, optimization outputs) override policy when available.

## Why centralize policy?

- **AGI-level self-improvement:** Strategic agent and platform-refactor scans can suggest moving more values here instead of hardcoding.
- **Single place to tune:** Daemon, pipeline, quality, strategic, and sweep behavior can be adjusted without editing scripts.
- **Clean architecture:** Policy is data, not code; easier to validate, document, and evolve.

## Schema (high level)

| Section     | Purpose                                                                                                                                                 |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `daemon`    | Poll interval, health timeouts per stage, auto-scale/optimize/stale-reaper intervals, stale thresholds, `stale_timeout_multiplier`, `stale_state_hours` |
| `pipeline`  | Max iterations, coverage/quality gate thresholds, memory baseline fallbacks, `max_cycles_convergence_cap`                                               |
| `quality`   | Coverage and gate score thresholds, `audit_weights` (test_pass, coverage, security, etc.)                                                               |
| `strategic` | Max issues per cycle, cooldown, overlap threshold, strategy line limit                                                                                  |
| `sweep`     | Cron interval, stuck threshold, retry template and iteration caps                                                                                       |
| `hygiene`   | Artifact age for cleanup                                                                                                                                |
| `recruit`   | Agent recruitment: self_tune, match thresholds, model, promote thresholds                                                                               |
| `riskTierRules`, `mergePolicy`, `docsDriftRules`, `evidence`, `harnessGapPolicy`, `codeReviewAgent` | Code Factory contract: risk tiers, merge policy, docs drift rules, evidence specs, harness-gap SLAs, review agent settings |
| `decision`  | Decision engine tiers (not yet listed in `policy.schema.json`)                                                                                          |

## Usage

- **From bash:** Prefer `jq` to read values, e.g. `jq -r '.daemon.poll_interval_seconds // 60' config/policy.json`.
- **Override:** If `~/.shipwright/policy.json` exists, `scripts/lib/policy.sh` reads it instead of the repo `config/policy.json` (it replaces the file; it does not merge).
- **Adaptive overrides:** Daemon/pipeline already use learned timeouts and iteration counts when present; those continue to override policy.

## Schema

- **config/policy.schema.json** — JSON Schema (draft-07) for policy. Validate in CI with `jq empty config/policy.json`; optional full validation with `ajv validate -s config/policy.schema.json -d config/policy.json`.

## Roadmap

- ~~Add `scripts/lib/policy.sh`~~ (done)
- ~~Migrate daemon/pipeline/quality/strategic/hygiene defaults to read from policy~~ (done)
- Strategic agent can recommend issues like "Move more tunables to config/policy.json."
- Add the `decision` section to `policy.schema.json`: the schema sets `additionalProperties: false`, so full validation currently rejects `config/policy.json`.
