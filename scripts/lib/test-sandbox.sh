#!/usr/bin/env bash
# test-sandbox.sh — agent-written code and tests never run in the trusted checkout (ADR-0011).
#
# Patch handoff (patch-handoff.sh) keeps the build agent out of the trusted checkout, but the
# pipeline still ran the result there: the test stage, the acceptance gate (verify-red and
# verify-green), holdout and mutation runs, and the quality checks all executed agent-written code
# with the trusted checkout as the working directory. A test file could rewrite .git/config or a
# hook, edit the acceptance lock in ~/.shipwright, or plant files the PR stage would then deliver.
#
# Now every such run gets a sandbox:
#   1. test_sandbox_open    a disposable clone of the trusted checkout at HEAD (no remote, no
#                           credentials, made by handoff_prepare), plus the checkout's uncommitted
#                           work (exported by handoff_export, so the trusted .git is only read) and
#                           copies of ignored dependency directories (node_modules, .venv, ...),
#                           copy-on-write where the filesystem allows (APFS clonefile, reflink).
#   2. test_sandbox_jail    runs a command under an OS write jail: it may write only inside its
#                           sandbox, its private TMPDIR and package-manager caches (/tmp itself is
#                           read-only: TMPDIR points into the sandbox). macOS uses
#                           sandbox-exec, Linux uses bubblewrap. sw_test_gate_env jails every test
#                           command while SW_TEST_JAIL names a sandbox, so callers that are not bash
#                           (`shipwright acceptance`, through test-gate-exec.sh) are jailed too.
#   3. test_sandbox_close   removes it. Nothing in it is ever applied back: only exit codes and logs
#                           cross back, as data.
#
# Mode (SW_TEST_SANDBOX):
#   auto   (default) the clone always; the OS jail when this machine can start one, else a
#          warning and the event test.sandbox_unjailed.
#   jail   the clone and the OS jail, or the run fails (fail closed).
#   clone  the clone only.
#   off    the old behavior: tests run in the trusted checkout.
#
# Knobs: SW_TEST_SANDBOX_DEPS (space-separated directory names copied when git ignores them;
# empty copies none), SW_TEST_SANDBOX_WRITABLE (extra writable paths, colon-separated; for example
# /tmp for a tool that ignores TMPDIR).
#
# Scope: the agent's code still runs as the same OS user and may read what that user can read
# (credentials are already stripped from the environment by test-gate-env.sh). The jail stops
# writes outside the sandbox; it does not hide files or block the network.
#
# Bash 3.2 compatible. No `set` here: this file is sourced.
[[ -n "${_TEST_SANDBOX_LOADED:-}" ]] && return 0
_TEST_SANDBOX_LOADED=1

# shellcheck source=lib/patch-handoff.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch-handoff.sh"

SW_TEST_SANDBOX_DEPS_DEFAULT="node_modules .venv venv vendor .bundle"
_TEST_SANDBOX_PREFIX="sw-test-sandbox."

_test_sandbox_err() { printf 'test-sandbox: %s\n' "$*" >&2; }

# test_sandbox_mode — auto | jail | clone | off
test_sandbox_mode() {
    case "${SW_TEST_SANDBOX:-auto}" in
        off|false|0) echo "off" ;;
        clone) echo "clone" ;;
        jail|strict) echo "jail" ;;
        *) echo "auto" ;;
    esac
}

# _test_sandbox_jail_kind — sandbox-exec | bwrap | none (probed once per shell).
_test_sandbox_jail_kind() {
    if [[ -z "${_TEST_SANDBOX_KIND:-}" ]]; then
        _TEST_SANDBOX_KIND="none"
        case "$(uname -s)" in
            Darwin)
                if command -v sandbox-exec >/dev/null 2>&1 \
                    && sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
                    _TEST_SANDBOX_KIND="sandbox-exec"
                fi ;;
            Linux)
                if command -v bwrap >/dev/null 2>&1 \
                    && bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc true >/dev/null 2>&1; then
                    _TEST_SANDBOX_KIND="bwrap"
                fi ;;
        esac
    fi
    printf '%s\n' "$_TEST_SANDBOX_KIND"
}

# _test_sandbox_valid DIR — 0 when DIR is a sandbox made by test_sandbox_open.
_test_sandbox_valid() {
    local dir="$1" parent
    [[ -n "$dir" && "$dir" == /* && "${dir##*/}" == "repo" && -d "$dir" ]] || return 1
    parent="${dir%/repo}"
    [[ "${parent##*/}" == "${_TEST_SANDBOX_PREFIX}"* && -d "$parent/tmp" ]]
}

# _test_sandbox_cow_copy SRC DST — copy a directory tree, copy-on-write when possible.
_test_sandbox_cow_copy() {
    local src="$1" dst="$2"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        cp -cpPR "$src" "$dst" 2>/dev/null && return 0
        rm -rf "$dst"
        cp -pPR "$src" "$dst"
        return
    fi
    cp -pPR --reflink=auto "$src" "$dst" 2>/dev/null && return 0
    rm -rf "$dst"
    cp -pPR "$src" "$dst"
}

# _test_sandbox_copy_deps ROOT DIR — copy the ignored dependency directories of ROOT into DIR.
_test_sandbox_copy_deps() {
    local root="$1" dir="$2" list path name
    list=" ${SW_TEST_SANDBOX_DEPS-$SW_TEST_SANDBOX_DEPS_DEFAULT} "
    [[ -n "${list// /}" ]] || return 0
    while IFS= read -r -d '' path; do
        path="${path%/}"
        name="${path##*/}"
        [[ "$list" == *" $name "* ]] || continue
        case "/$path/" in */../*|*/./*|/.git/*|/.claude/*) continue ;; esac
        [[ -d "$root/$path" && ! -L "$root/$path" && ! -e "$dir/$path" ]] || continue
        mkdir -p "$(dirname "$dir/$path")" || return 1
        _test_sandbox_cow_copy "$root/$path" "$dir/$path" \
            || { _test_sandbox_err "could not copy $path"; return 1; }
    done < <(_handoff_in "$root" ls-files -z --others --ignored --exclude-standard --directory)
}

# test_sandbox_open TRUSTED — prints the path of a new sandbox: TRUSTED at HEAD plus its
# uncommitted work and dependency directories. Returns 1 (and leaves nothing behind) on failure.
test_sandbox_open() {
    local trusted="$1" root base work rc=0
    root=$(cd "$trusted" 2>/dev/null && pwd -P) || { _test_sandbox_err "no checkout: $trusted"; return 1; }
    base=$(_handoff_in "$root" rev-parse --verify HEAD 2>/dev/null) \
        || { _test_sandbox_err "$root has no HEAD commit"; return 1; }
    work=$(mktemp -d "${TMPDIR:-/tmp}/${_TEST_SANDBOX_PREFIX}XXXXXX") || return 1
    work=$(cd "$work" && pwd -P) || return 1
    _test_sandbox_fill "$root" "$base" "$work" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        chmod -R u+w "$work" 2>/dev/null || true
        rm -rf "$work"
        return "$rc"
    fi
    if [[ "$(test_sandbox_mode)" == "auto" && "$(_test_sandbox_jail_kind)" == "none" ]] \
        && [[ -z "${_TEST_SANDBOX_WARNED:-}" ]]; then
        _TEST_SANDBOX_WARNED=1
        _test_sandbox_err "no OS write jail on this machine (macOS: sandbox-exec; Linux: bubblewrap); tests run in a disposable clone without it"
        if type emit_event >/dev/null 2>&1; then
            emit_event "test.sandbox_unjailed" "issue=${ISSUE_NUMBER:-0}" 2>/dev/null || true
        fi
    fi
    printf '%s\n' "$work/repo"
}

_test_sandbox_fill() {
    local root="$1" base="$2" work="$3" dir="$3/repo" patch="$3/worktree.patch"
    mkdir -p "$work/tmp" || return 1
    handoff_prepare "$root" "$base" "$dir" || return 1
    # The checkout's uncommitted work (for example acceptance tests not yet committed). Applied
    # with --index (git 2.43 crashes in `apply` without it under --attr-source), then unstaged, so
    # new files stay untracked as they are in the checkout.
    handoff_export "$root" "$base" "$root" "$patch" || return 1
    if [[ -s "$patch" ]]; then
        { _handoff_in "$dir" apply --index --binary --whitespace=nowarn "$patch" \
            && _handoff_in "$dir" reset -q; } \
            || { _test_sandbox_err "could not copy the checkout's uncommitted work"; return 1; }
    fi
    rm -f "$patch" "$patch.moved"
    _test_sandbox_copy_deps "$root" "$dir"
}

# test_sandbox_close DIR — removes a sandbox made by test_sandbox_open. Anything else is left alone.
test_sandbox_close() {
    local dir="${1:-}"
    _test_sandbox_valid "$dir" || return 0
    chmod -R u+w "${dir%/repo}" 2>/dev/null || true
    rm -rf "${dir%/repo}"
}

# _test_sandbox_writable — the paths a jailed command may write besides its sandbox, one per line,
# resolved, existing directories only.
_test_sandbox_writable() {
    local p extra
    local defaults="$HOME/Library/Caches:$HOME/.cache:$HOME/.bun/install/cache:$HOME/.npm:$HOME/.yarn/berry/cache:$HOME/.cargo/registry:$HOME/.cargo/git:$HOME/go/pkg/mod:$HOME/.gradle/caches:$HOME/.m2/repository"
    extra="${SW_TEST_SANDBOX_WRITABLE:-}"
    local IFS=':'
    for p in $defaults $extra; do
        [[ -n "$p" && "$p" == /* && -d "$p" ]] || continue
        (cd "$p" 2>/dev/null && pwd -P) || true
    done
}

# The macOS profile names paths only through parameters, so no path is ever parsed as profile text.
_test_sandbox_profile() {
    local n="$1" i
    printf '%s\n' '(version 1)' '(allow default)' '(deny file-write*)' '(allow file-write*'
    printf '%s\n' '  (subpath (param "SW_WORK"))' \
        '  (regex #"^/private/var/folders/[^/]+/[^/]+/C/")' \
        '  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/dtracehelper")' \
        '  (regex #"^/dev/fd/") (regex #"^/dev/ttys[0-9]+$")'
    for ((i = 0; i < n; i++)); do printf '  (subpath (param "SW_W%d"))\n' "$i"; done
    printf '%s\n' ')'
}

# test_sandbox_jail DIR CMD... — run CMD (in the current directory) under the OS write jail for the
# sandbox DIR. In mode jail, a machine without a jail refuses (126); otherwise CMD runs unjailed.
test_sandbox_jail() {
    local dir="$1"
    shift
    _test_sandbox_valid "$dir" || { _test_sandbox_err "not a test sandbox: $dir"; return 126; }
    local work="${dir%/repo}" kind
    kind=$(_test_sandbox_jail_kind)
    [[ "$(test_sandbox_mode)" == "clone" ]] && kind="none"
    local writable=() p
    while IFS= read -r p; do [[ -n "$p" ]] && writable+=("$p"); done < <(_test_sandbox_writable)
    case "$kind" in
        sandbox-exec)
            local args=(-D "SW_WORK=$work") i=0
            for p in ${writable[@]+"${writable[@]}"}; do args+=(-D "SW_W$i=$p"); i=$((i + 1)); done
            TMPDIR="$work/tmp/" sandbox-exec "${args[@]}" -p "$(_test_sandbox_profile "$i")" "$@"
            ;;
        bwrap)
            local args=(--ro-bind / / --dev /dev --unshare-pid --proc /proc --bind "$work" "$work")
            for p in ${writable[@]+"${writable[@]}"}; do args+=(--bind "$p" "$p"); done
            TMPDIR="$work/tmp" bwrap "${args[@]}" --die-with-parent --chdir "$PWD" -- "$@"
            ;;
        *)
            if [[ "$(test_sandbox_mode)" == "jail" ]]; then
                _test_sandbox_err "SW_TEST_SANDBOX=jail but this machine has no OS write jail; refusing to run tests"
                return 126
            fi
            TMPDIR="$work/tmp" "$@"
            ;;
    esac
}

# test_sandbox_run TRUSTED CMD — runs the shell command string CMD (a configured test command) in
# a fresh sandbox of TRUSTED, jailed and without credentials. Mode off runs it in TRUSTED.
# Fails closed: a sandbox that cannot be prepared returns 1 and CMD does not run.
test_sandbox_run() {
    local trusted="$1" cmd="$2" sb rc=0
    if [[ "$(test_sandbox_mode)" == "off" ]]; then
        (cd "$trusted" && sw_test_gate_run "$cmd")
        return
    fi
    sb=$(test_sandbox_open "$trusted") || { _test_sandbox_err "sandbox could not be prepared; not running: $cmd"; return 1; }
    (cd "$sb" && export SW_TEST_JAIL="$sb" && sw_test_gate_run "$cmd") || rc=$?
    test_sandbox_close "$sb"
    return "$rc"
}
