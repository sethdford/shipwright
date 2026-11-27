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
# The jail only accepts a test-sandbox directory (<prefix>XXXXXX/repo beside tmp). `env init`
# proves an unreviewed recipe in such a clone, so it runs jailed; a daemon worktree runs a
# committed (reviewed) recipe and is not a sandbox, so it runs with credentials stripped only.
# SW_ENV_REQUIRE_JAIL=1 (set by the executor for agent-written recipes) fails closed: exit 126
# when no jail can run, including when the machine has no OS jail (SW_TEST_SANDBOX=jail).
if [[ "${SW_ENV_REQUIRE_JAIL:-0}" == "1" ]]; then
    export SW_TEST_SANDBOX=jail
    if [[ ! -f "$_SW_ENV_EXEC_DIR/test-sandbox.sh" ]]; then
        echo "env-exec: this recipe is unreviewed and must run in the test sandbox's write jail, which this install does not have; review it and rerun with --no-jail to run it unjailed" >&2
        exit 126
    fi
fi
if [[ "${SW_ENV_NO_JAIL:-0}" != "1" || "${SW_ENV_REQUIRE_JAIL:-0}" == "1" ]] && [[ -f "$_SW_ENV_EXEC_DIR/test-sandbox.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_SW_ENV_EXEC_DIR/test-sandbox.sh"
    if declare -F test_sandbox_jail >/dev/null && declare -F _test_sandbox_valid >/dev/null &&
        _test_sandbox_valid "$PWD"; then
        # The jail binds package caches only if they already exist: create the usual ones first,
        # so a first install on a fresh machine can fill them.
        mkdir -p "$HOME/.npm" "$HOME/.cache" "$HOME/.bun/install/cache" 2>/dev/null || true
        ( sw_test_gate_scrub && test_sandbox_jail "$PWD" "$@" )
        exit $?
    fi
    if [[ "${SW_ENV_REQUIRE_JAIL:-0}" == "1" ]]; then
        echo "env-exec: refusing to run an unreviewed recipe outside a test-sandbox directory ($PWD)" >&2
        exit 126
    fi
fi
sw_test_gate_env "$@"
