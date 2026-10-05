# Pre-build Toolchain Checks

The intake stage checks the **target project's** toolchain before it changes anything. It runs before the issue is assigned or labelled and before the branch is created. A missing runtime or an unmet engine requirement therefore fails within seconds, instead of after a paid build loop has started.

Shipwright's own prerequisites (`git`, `jq`, `gh`, `claude`) are not checked here. `preflight_checks()` in `scripts/lib/pipeline-util.sh` handles those.

- Implementation: `scripts/lib/prebuild-check.sh`
- Tests: `scripts/sw-lib-prebuild-check-test.sh`

## What is checked

| Language (from `detect_project_lang`) | Checks                                                                                                                                                                                             |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| typescript, nodejs, react, nextjs     | `node` on PATH; Node version vs `engines.node` → `.nvmrc` → `.node-version`; package manager implied by the lockfile; `node_modules` present; `npm ls --depth=0` problems (npm only, time-bounded) |
| rust                                  | `cargo`                                                                                                                                                                                            |
| go                                    | `go`                                                                                                                                                                                               |
| python                                | `python3` or `python`                                                                                                                                                                              |
| ruby                                  | `ruby`; `bundle` when a `Gemfile` exists                                                                                                                                                           |
| java                                  | `java`; `mvn` for `pom.xml` without `mvnw`; `gradle` for `build.gradle*` without `gradlew`                                                                                                         |
| unknown                               | nothing                                                                                                                                                                                            |

The check only observes. It never installs anything and makes no network calls, so it behaves the same with `--local` / `NO_GITHUB=1`.

## Findings

| id                    | Severity | Meaning                                                                                              |
| --------------------- | -------- | ---------------------------------------------------------------------------------------------------- |
| `runtime_missing`     | critical | Language runtime not on PATH                                                                         |
| `engine_mismatch`     | critical | Installed Node definitely does not meet the declared range                                           |
| `pkg_manager_missing` | critical | The lockfile requires pnpm/yarn/bun (or Gemfile/pom/gradle needs its tool), but that tool is missing |
| `deps_not_installed`  | warning  | `node_modules` missing; expected on a fresh clone                                                    |
| `deps_inconsistent`   | warning  | `npm ls` reports missing or invalid packages                                                         |
| `engine_unparseable`  | info     | The range is outside the supported grammar, so it can't be judged                                    |
| `lockfile_missing`    | info     | `package.json` has no lockfile                                                                       |
| `check_timeout`       | info     | `npm ls` exceeded its budget, or no `timeout` binary exists                                          |

The engine grammar supports these forms, and `||` unions of them:

- `>=X[.Y[.Z]]`
- `^X[.Y[.Z]]`
- `~X.Y[.Z]`
- `X`
- `X.x`
- `X.Y.x`
- `X.Y.Z`

Anything else, such as `>=18 <21`, hyphen ranges or `lts/*`, produces `engine_unparseable` and never blocks.

Every critical and warning finding carries a `remedy`, which is printed alongside it.

## Configuration

These settings use the normal config chain (`SHIPWRIGHT_*` env → `.claude/daemon-config.json` → `config/policy.json` → `config/defaults.json`):

| Key                                       | Env override                                         | Default   | Meaning                                                                      |
| ----------------------------------------- | ---------------------------------------------------- | --------- | ---------------------------------------------------------------------------- |
| `pipeline.prebuild.mode`                  | `SHIPWRIGHT_PIPELINE_PREBUILD_MODE`                  | `enforce` | `off` skips; `warn` never blocks; `enforce` blocks only on critical findings |
| `pipeline.prebuild.check_timeout_seconds` | `SHIPWRIGHT_PIPELINE_PREBUILD_CHECK_TIMEOUT_SECONDS` | `5`       | Budget for `npm ls`                                                          |
| `pipeline.prebuild.deps_check`            | `SHIPWRIGHT_PIPELINE_PREBUILD_DEPS_CHECK`            | `true`    | Run `npm ls` when `node_modules` exists                                      |

```json
{ "pipeline": { "prebuild": { "mode": "warn" } } }
```

## Outputs

- **Artifact.** `.claude/pipeline-artifacts/prebuild-check.json` is written atomically. It is not written when the mode is `off`.

  ```json
  {
    "version": 1,
    "mode": "enforce",
    "language": "nodejs",
    "status": "pass|warn|fail",
    "duration_ms": 0,
    "findings": [
      { "id": "...", "severity": "...", "message": "...", "remedy": "..." }
    ]
  }
  ```

- **`intake.json`.** Gains a `prebuild_status` field.
- **Progress comment.** The GitHub progress comment shows an `**Environment:**` line listing the critical and warning ids whenever the status is not `pass`.
- **Events.** `prebuild_check.completed` (status and the count of each severity) or `prebuild_check.failed` (the critical ids).
- **Hard-fail marker.** On a hard failure, intake logs `PREBUILD_ENV_ERROR: <ids>` and fails. The daemon classifies this as `environment_error` and does **not** retry it, because a retry can't install a toolchain.

## Recovering

1. Read the `✗ Prebuild: … — fix: …` lines, or `prebuild-check.json`.
2. Apply the remedy, for example `corepack enable pnpm` or `nvm install '>=20'`.
3. Run `shipwright pipeline resume`.

To proceed anyway, set `SHIPWRIGHT_PIPELINE_PREBUILD_MODE=warn`.

The check never blocks on its own internal errors. If it can't create a temp file or write the artifact, it warns and lets intake continue.

## Limits

- Only `PROJECT_ROOT` is checked. Individual workspace packages in a monorepo are not.
- On a host with no `timeout`/`gtimeout` binary, such as stock macOS, the `npm ls` scan is skipped rather than run unbounded.
