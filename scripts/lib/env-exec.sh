#!/usr/bin/env bash
# lib/env-exec.sh — run one environment-recipe command (an argv, never a string) without
# credentials, inside the test sandbox's write jail where it exists (ADR-0020).
#
#   env-exec.sh <program> [args...]      # cwd = the checkout being made ready
#
# Credentials are stripped as for the test gate (lib/test-gate-env.sh). When lib/test-sandbox.sh
# exists and defines test_sandbox_jail, the command runs under it with the current directory as the
# writable root: setup commands may write the checkout, its ../tmp and the package caches, and use
# the network. SW_ENV_NO_JAIL=1 skips the jail (credentials are still stripped).
set -euo pipefail
_SW_ENV_EXEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-gate-env.sh
source "$_SW_ENV_EXEC_DIR/test-gate-env.sh"
if [[ $# -eq 0 ]]; then
    echo "usage: env-exec.sh <program> [args...]" >&2
    exit 2
fi
if [[ "${SW_ENV_NO_JAIL:-0}" != "1" && -f "$_SW_ENV_EXEC_DIR/test-sandbox.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_SW_ENV_EXEC_DIR/test-sandbox.sh"
    if declare -F test_sandbox_jail >/dev/null; then
        ( sw_test_gate_scrub && test_sandbox_jail "$PWD" "$@" )
        exit $?
    fi
fi
sw_test_gate_env "$@"
