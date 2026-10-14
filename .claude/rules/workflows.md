---
paths:
  - ".github/workflows/**"
---
No `${{ }}` expression of any kind inside a `run:` script (#8533). Pass values through the step's
`env:` block and reference `"$VAR"`, or use the `$GITHUB_*` built-ins (`$GITHUB_REPOSITORY`,
`$GITHUB_SHA`, `$GITHUB_REF_NAME`, …). The same applies to `actions/github-script` `script:` bodies.
`bun run arch` fails on any expression in those places (no allowlist). Never pass `--dangerously-skip-permissions` or `bypassPermissions` to an agent (F9).
Pin new actions to a full commit SHA with the version in a comment (`@<sha> # v2.2.0`).
Gate every dispatch or retry with `.github/actions/safety-gates` (exit 0 is the only "go"), and read
`SHIPWRIGHT-*` markers only through `scripts/ci/bot-comments.sh` / `retry-state.sh`; never pipe,
`||`-default or silence them, and never pass `--no-github` (`bun run arch` checks this; ADR-0007).
