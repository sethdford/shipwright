# shellcheck shell=bash
# lib/env-cache.sh — bash callers of the environment cache (ADR-0020). Sourced; sets no options.
#
# The work lives in TypeScript (`shipwright env hydrate`): read the repository's recipe, restore a
# cached environment (node_modules, .venv, ...) into a fresh checkout or build and save one. Every
# function here is best effort: callers add `|| true`, and a missing Bun or CLI is a quiet skip.
#
#   sw_env_hydrate ROOT DIR [--ref REF] [--restore-only] [--quiet] [--json]
#   test_sandbox_hydrate ROOT DIR        # restore only: never runs setup on agent-edited lockfiles
#
# SW_ENV_CACHE=0 disables it (default off under SHIPWRIGHT_TEST_MODE=1, on otherwise).
# SW_BUN and SW_TS_CLI override the Bun binary and the CLI entry point (as in safety-gates.sh).
[[ -n "${_SW_ENV_CACHE_LOADED:-}" ]] && return 0
_SW_ENV_CACHE_LOADED=1
_SW_ENV_CACHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _sw_env_cache_enabled — 0 when hydration should run.
_sw_env_cache_enabled() {
    local default=1
    [[ "${SHIPWRIGHT_TEST_MODE:-}" == "1" ]] && default=0
    [[ "${SW_ENV_CACHE:-$default}" != "0" ]]
}

# sw_env_hydrate ROOT DIR [args...] — make DIR (a checkout of ROOT's repository) ready to build and
# test. Returns the CLI's status (0 hit/built/skipped, 1 setup failed, 2 usage); 0 when disabled
# or when Bun or the CLI is missing.
sw_env_hydrate() {
    _sw_env_cache_enabled || return 0
    if [[ $# -lt 2 || -z "$1" || -z "$2" ]]; then
        echo "usage: sw_env_hydrate ROOT DIR [args...]" >&2
        return 2
    fi
    local root="$1" dir="$2"
    shift 2
    local bun_bin="${SW_BUN:-bun}"
    local cli="${SW_TS_CLI:-$(cd "${_SW_ENV_CACHE_DIR}/../.." && pwd)/src/cli.ts}"
    if ! command -v "$bun_bin" >/dev/null 2>&1; then
        echo "env cache: ${bun_bin} not found, skipping hydrate" >&2
        return 0
    fi
    if [[ ! -f "$cli" ]]; then
        echo "env cache: ${cli} not found, skipping hydrate" >&2
        return 0
    fi
    local rc=0
    "$bun_bin" "$cli" env hydrate --root "$root" --dir "$dir" "$@" || rc=$?
    return "$rc"
}

# test_sandbox_hydrate ROOT DIR — restore a cached environment into DIR, never build one. The test
# sandbox calls it outside its jail, before running an agent's tests.
test_sandbox_hydrate() {
    if [[ $# -lt 2 ]]; then
        echo "usage: test_sandbox_hydrate ROOT DIR" >&2
        return 2
    fi
    sw_env_hydrate "$1" "$2" --restore-only
}
