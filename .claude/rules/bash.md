---
paths:
  - "scripts/**/*.sh"
---
Bash 3.2: no `declare -A`, `mapfile`/`readarray`, `${var,,}`/`${var^^}`, `|&`, negative indexes.
Under `set -euo pipefail`: `grep -c … || true` then `${n:-0}`; `while read …; done < <(cmd)` (not
`cmd | while`); atomic writes via temp file + `mv`; JSON only with `jq --arg`; `local` only inside
functions; `cd` in helpers only in a subshell. Check `$NO_GITHUB` in GitHub features.
Never `eval` or build a command string from issue, PR or model text; pass arguments as an array.
Prefer porting a command to TypeScript over large bash changes.
