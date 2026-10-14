---
paths:
  - ".github/workflows/**"
---
No `${{ }}` expression of any kind inside a `run:` script (#8533). Pass values through the step's
`env:` block and reference `"$VAR"`, or use the `$GITHUB_*` built-ins (`$GITHUB_REPOSITORY`,
`$GITHUB_SHA`, `$GITHUB_REF_NAME`, …). The same applies to `actions/github-script` `script:` bodies.
`bun run arch` flags untrusted expressions (issue, PR, comment and step-output text); keep the rest
out by review. Never pass `--dangerously-skip-permissions` or `bypassPermissions` to an agent (F9).
Pin new actions to a version tag.
