#!/usr/bin/env bash
# lib/test-gate-exec.sh — run one test command (an argv, never a string) without credentials.
#
#   test-gate-exec.sh <program> [args...]
#
# The executable form of sw_test_gate_env (lib/test-gate-env.sh, #8608) for callers that are not
# bash: `shipwright acceptance` runs each acceptance test file through it.
set -euo pipefail
# shellcheck source=lib/test-gate-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-gate-env.sh"
if [[ $# -eq 0 ]]; then
    echo "usage: test-gate-exec.sh <program> [args...]" >&2
    exit 2
fi
sw_test_gate_env "$@"
