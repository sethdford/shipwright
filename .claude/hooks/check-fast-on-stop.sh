#!/usr/bin/env bash
# Stop hook: block "done" while bun run check:fast fails. Allows the stop on the retry so it can't loop.
set -uo pipefail
input=$(cat)
if [[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" == "true" ]]; then
  exit 0
fi
# No Bun (e.g. a bash-only checkout): nothing to check, never block the stop.
command -v bun >/dev/null 2>&1 || exit 0
cd "$(git rev-parse --show-toplevel)" || exit 0
if output=$(bun run check:fast 2>&1); then
  exit 0
fi
# Exit 2 blocks the stop and feeds stderr back to Claude (documented Stop-hook contract).
printf 'bun run check:fast failed. Fix it before finishing:\n%s\n' "$(printf '%s' "$output" | tail -40)" >&2
exit 2
