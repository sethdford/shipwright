#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-detection test — Unit tests for detection fns   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-detection Tests"

setup_test_env "sw-lib-pipeline-detection-test"
trap cleanup_test_env EXIT

mock_git
mock_gh
mock_claude

# Source the lib (needs PROJECT_ROOT set)
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
_PIPELINE_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-detection.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_test_cmd
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_test_cmd"

# Node.js project with npm
mkdir -p "$PROJECT_ROOT"
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest --coverage"}}
JSON
result=$(detect_test_cmd)
assert_eq "Node.js project defaults to npm test" "npm test" "$result"

# Node.js with pnpm lock
touch "$PROJECT_ROOT/pnpm-lock.yaml"
result=$(detect_test_cmd)
assert_eq "pnpm lockfile detected" "pnpm test" "$result"
rm -f "$PROJECT_ROOT/pnpm-lock.yaml"

# Node.js with yarn lock
touch "$PROJECT_ROOT/yarn.lock"
result=$(detect_test_cmd)
assert_eq "yarn lockfile detected" "yarn test" "$result"
rm -f "$PROJECT_ROOT/yarn.lock"

# Node.js with bun lock
touch "$PROJECT_ROOT/bun.lockb"
result=$(detect_test_cmd)
assert_eq "bun lockfile detected" "bun test" "$result"
rm -f "$PROJECT_ROOT/bun.lockb"

# No test script in package.json
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"start":"node index.js"}}
JSON
rm -f "$PROJECT_ROOT/Cargo.toml" "$PROJECT_ROOT/go.mod" "$PROJECT_ROOT/Gemfile" "$PROJECT_ROOT/pom.xml" "$PROJECT_ROOT/build.gradle" "$PROJECT_ROOT/build.gradle.kts" "$PROJECT_ROOT/Makefile"
result=$(detect_test_cmd)
assert_eq "package.json without test script returns empty" "" "$result"

# "no test specified" placeholder
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}
JSON
result=$(detect_test_cmd)
assert_eq "npm 'no test specified' returns empty" "" "$result"
rm -f "$PROJECT_ROOT/package.json"

# Python with pyproject.toml + pytest
cat > "$PROJECT_ROOT/pyproject.toml" <<'TOML'
[tool.pytest.ini_options]
testpaths = ["tests"]
TOML
result=$(detect_test_cmd)
assert_eq "Python pyproject.toml with pytest" "pytest" "$result"
rm -f "$PROJECT_ROOT/pyproject.toml"

# Python with setup.py + tests dir
cat > "$PROJECT_ROOT/setup.py" <<'PY'
from setuptools import setup
PY
mkdir -p "$PROJECT_ROOT/tests"
result=$(detect_test_cmd)
assert_eq "Python setup.py + tests dir" "pytest" "$result"
rm -f "$PROJECT_ROOT/setup.py"
rm -rf "$PROJECT_ROOT/tests"

# Rust
cat > "$PROJECT_ROOT/Cargo.toml" <<'TOML'
[package]
name = "test"
TOML
result=$(detect_test_cmd)
assert_eq "Rust project" "cargo test" "$result"
rm -f "$PROJECT_ROOT/Cargo.toml"

# Go
cat > "$PROJECT_ROOT/go.mod" <<'GO'
module example.com/test
GO
result=$(detect_test_cmd)
assert_eq "Go project" "go test ./..." "$result"
rm -f "$PROJECT_ROOT/go.mod"

# Ruby with rspec
cat > "$PROJECT_ROOT/Gemfile" <<'RUBY'
gem 'rspec'
RUBY
result=$(detect_test_cmd)
assert_eq "Ruby with rspec" "bundle exec rspec" "$result"

# Ruby without rspec
cat > "$PROJECT_ROOT/Gemfile" <<'RUBY'
gem 'rails'
RUBY
result=$(detect_test_cmd)
assert_eq "Ruby without rspec" "bundle exec rake test" "$result"
rm -f "$PROJECT_ROOT/Gemfile"

# Maven
touch "$PROJECT_ROOT/pom.xml"
result=$(detect_test_cmd)
assert_eq "Maven project" "mvn test" "$result"
rm -f "$PROJECT_ROOT/pom.xml"

# Gradle
touch "$PROJECT_ROOT/build.gradle"
result=$(detect_test_cmd)
assert_eq "Gradle project" "./gradlew test" "$result"
rm -f "$PROJECT_ROOT/build.gradle"

# Gradle Kotlin DSL
touch "$PROJECT_ROOT/build.gradle.kts"
result=$(detect_test_cmd)
assert_eq "Gradle Kotlin DSL project" "./gradlew test" "$result"
rm -f "$PROJECT_ROOT/build.gradle.kts"

# Makefile with test target
cat > "$PROJECT_ROOT/Makefile" <<'MAKE'
test:
	echo "running tests"
MAKE
result=$(detect_test_cmd)
assert_eq "Makefile with test target" "make test" "$result"
rm -f "$PROJECT_ROOT/Makefile"

# Empty project
result=$(detect_test_cmd)
assert_eq "Empty project returns empty" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_project_lang
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_project_lang"

# TypeScript
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"devDependencies":{"typescript":"^5.0"}}
JSON
result=$(detect_project_lang)
assert_eq "TypeScript detected" "typescript" "$result"

# Next.js
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"dependencies":{"next":"^14.0"}}
JSON
result=$(detect_project_lang)
assert_eq "Next.js detected" "nextjs" "$result"

# React
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"dependencies":{"react":"^18.0"}}
JSON
result=$(detect_project_lang)
assert_eq "React detected" "react" "$result"

# Plain Node.js
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"dependencies":{"express":"^4.0"}}
JSON
result=$(detect_project_lang)
assert_eq "Node.js detected" "nodejs" "$result"
rm -f "$PROJECT_ROOT/package.json"

# Rust
cat > "$PROJECT_ROOT/Cargo.toml" <<'TOML'
[package]
name = "test"
TOML
result=$(detect_project_lang)
assert_eq "Rust lang detected" "rust" "$result"
rm -f "$PROJECT_ROOT/Cargo.toml"

# Go
cat > "$PROJECT_ROOT/go.mod" <<'GO'
module example.com/test
GO
result=$(detect_project_lang)
assert_eq "Go lang detected" "go" "$result"
rm -f "$PROJECT_ROOT/go.mod"

# Python
cat > "$PROJECT_ROOT/requirements.txt" <<'PY'
flask==2.0
PY
result=$(detect_project_lang)
assert_eq "Python detected" "python" "$result"
rm -f "$PROJECT_ROOT/requirements.txt"

# Ruby
cat > "$PROJECT_ROOT/Gemfile" <<'RUBY'
gem 'rails'
RUBY
result=$(detect_project_lang)
assert_eq "Ruby detected" "ruby" "$result"
rm -f "$PROJECT_ROOT/Gemfile"

# Java
touch "$PROJECT_ROOT/pom.xml"
result=$(detect_project_lang)
assert_eq "Java detected" "java" "$result"
rm -f "$PROJECT_ROOT/pom.xml"

# Unknown
result=$(detect_project_lang)
assert_eq "Unknown for empty project" "unknown" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_task_type (keyword fallback only — no Claude available)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_task_type"

assert_eq "Bug from 'fix' keyword" "bug" "$(detect_task_type "Fix the broken login")"
assert_eq "Bug from 'crash' keyword" "bug" "$(detect_task_type "App crashes on startup")"
assert_eq "Refactor keyword" "refactor" "$(detect_task_type "Refactor the database layer")"
assert_eq "Testing keyword" "testing" "$(detect_task_type "Add test coverage for auth")"
assert_eq "Security keyword" "security" "$(detect_task_type "Security audit for API")"
assert_eq "Docs keyword" "docs" "$(detect_task_type "Update the README guide")"
assert_eq "DevOps keyword" "devops" "$(detect_task_type "Setup CI pipeline")"
assert_eq "Migration keyword" "migration" "$(detect_task_type "Database migration for users")"
assert_eq "Architecture keyword" "architecture" "$(detect_task_type "Design new architecture RFC")"
assert_eq "Feature default" "feature" "$(detect_task_type "Add user profile page")"

# ═══════════════════════════════════════════════════════════════════════════════
# branch_prefix_for_type (fallback paths — no git branches)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "branch_prefix_for_type"

assert_eq "Bug prefix" "fix" "$(branch_prefix_for_type bug)"
assert_eq "Refactor prefix" "refactor" "$(branch_prefix_for_type refactor)"
assert_eq "Testing prefix" "test" "$(branch_prefix_for_type testing)"
assert_eq "Security prefix" "security" "$(branch_prefix_for_type security)"
assert_eq "Docs prefix" "docs" "$(branch_prefix_for_type docs)"
assert_eq "DevOps prefix" "ci" "$(branch_prefix_for_type devops)"
assert_eq "Migration prefix" "migrate" "$(branch_prefix_for_type migration)"
assert_eq "Architecture prefix" "arch" "$(branch_prefix_for_type architecture)"
assert_eq "Feature prefix (default)" "feat" "$(branch_prefix_for_type feature)"
assert_eq "Unknown type defaults to feat" "feat" "$(branch_prefix_for_type something_else)"

# ═══════════════════════════════════════════════════════════════════════════════
# template_for_type
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "template_for_type"

assert_eq "Bug template" "bug-fix" "$(template_for_type bug)"
assert_eq "Refactor template" "refactor" "$(template_for_type refactor)"
assert_eq "Testing template" "testing" "$(template_for_type testing)"
assert_eq "Security template" "security-audit" "$(template_for_type security)"
assert_eq "Docs template" "documentation" "$(template_for_type docs)"
assert_eq "DevOps template" "devops" "$(template_for_type devops)"
assert_eq "Migration template" "migration" "$(template_for_type migration)"
assert_eq "Architecture template" "architecture" "$(template_for_type architecture)"
assert_eq "Feature template" "feature-dev" "$(template_for_type feature)"
assert_eq "Unknown template" "feature-dev" "$(template_for_type other)"

# ═══════════════════════════════════════════════════════════════════════════════
# _detect_package_manager
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_detect_package_manager"

# npm (default)
rm -f "$PROJECT_ROOT"/*.lock "$PROJECT_ROOT"/*.lockb "$PROJECT_ROOT"/*.yaml
result=$(_detect_package_manager "$PROJECT_ROOT")
assert_eq "No lockfile defaults to npm" "npm" "$result"

# pnpm
touch "$PROJECT_ROOT/pnpm-lock.yaml"
result=$(_detect_package_manager "$PROJECT_ROOT")
assert_eq "pnpm-lock.yaml detected" "pnpm" "$result"
rm -f "$PROJECT_ROOT/pnpm-lock.yaml"

# bun
touch "$PROJECT_ROOT/bun.lockb"
result=$(_detect_package_manager "$PROJECT_ROOT")
assert_eq "bun.lockb detected" "bun" "$result"
rm -f "$PROJECT_ROOT/bun.lockb"

# yarn
touch "$PROJECT_ROOT/yarn.lock"
result=$(_detect_package_manager "$PROJECT_ROOT")
assert_eq "yarn.lock detected" "yarn" "$result"
rm -f "$PROJECT_ROOT/yarn.lock"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_test_commands (plural)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "detect_test_commands"

# Single test script returns just primary
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest"}}
JSON
result=$(detect_test_commands)
line_count=$(echo "$result" | wc -l | tr -d ' ')
assert_eq "Single test script returns 1 command" "1" "$line_count"
assert_eq "Primary command is npm test" "npm test" "$(echo "$result" | head -1)"

# Multiple test:* scripts (integration/e2e/system excluded)
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest","test:e2e":"jest --config e2e.config.js","test:unit":"jest --testPathPattern unit","test:smoke":"jest --smoke","test:integration":"bash integration.sh","test:system":"bash system.sh"}}
JSON
result=$(detect_test_commands)
line_count=$(echo "$result" | wc -l | tr -d ' ')
assert_eq "Heavyweight tests filtered: returns 3 commands" "3" "$line_count"
assert_eq "Primary command first" "npm test" "$(echo "$result" | head -1)"
if echo "$result" | grep >/dev/null "npm run test:unit"; then
    assert_pass "test:unit included"
else
    assert_fail "test:unit included"
fi
if echo "$result" | grep >/dev/null "npm run test:smoke"; then
    assert_pass "test:smoke included"
else
    assert_fail "test:smoke included"
fi
# Integration/e2e/system should be excluded
if echo "$result" | grep >/dev/null "npm run test:e2e"; then
    assert_fail "test:e2e excluded (heavyweight)"
else
    assert_pass "test:e2e excluded (heavyweight)"
fi
if echo "$result" | grep >/dev/null "npm run test:integration"; then
    assert_fail "test:integration excluded (heavyweight)"
else
    assert_pass "test:integration excluded (heavyweight)"
fi
if echo "$result" | grep >/dev/null "npm run test:system"; then
    assert_fail "test:system excluded (heavyweight)"
else
    assert_pass "test:system excluded (heavyweight)"
fi

# Subdirectory with package.json (must have node_modules installed)
mkdir -p "$PROJECT_ROOT/dashboard" "$PROJECT_ROOT/dashboard/node_modules"
cat > "$PROJECT_ROOT/dashboard/package.json" <<'JSON'
{"scripts":{"test":"bun test"}}
JSON
touch "$PROJECT_ROOT/dashboard/bun.lockb"
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest"}}
JSON
result=$(detect_test_commands)
if echo "$result" | grep >/dev/null 'cd.*dashboard.*test'; then
    assert_pass "Subdirectory test runner discovered"
else
    assert_fail "Subdirectory test runner discovered" "got: $result"
fi

# Subdirectory with "no test specified" is excluded
cat > "$PROJECT_ROOT/dashboard/package.json" <<'JSON'
{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}
JSON
result=$(detect_test_commands)
if echo "$result" | grep >/dev/null 'dashboard'; then
    assert_fail "Subdirectory with 'no test' excluded"
else
    assert_pass "Subdirectory with 'no test' excluded"
fi

# Cleanup
rm -rf "$PROJECT_ROOT/dashboard"
rm -f "$PROJECT_ROOT/package.json"

# Redundant extra scripts are dropped (#8633). Only the exact cases below are dropped: a --list
# that is a standalone word, the primary's own body (optionally with --jobs/-j), and a chain of
# two or more suites under a primary sw-test-all.sh without --pattern.
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"bash scripts/sw-test-all.sh","test:smoke":"bash scripts/sw-e2e-smoke-test.sh","test:list":"bash scripts/sw-test-all.sh --list","test:fast":"bash scripts/sw-test-all.sh --jobs 4","test:legacy-chain":"bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh && bash scripts/sw-c-test.sh","test:ts":"bun test ./src ./tools"}}
JSON
result=$(detect_test_commands)
assert_eq "sw-test-all repo: keeps primary, smoke and ts only" "npm test
npm run test:smoke
npm run test:ts" "$result"

cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest","test:suites":"jest --list","test:listed":"jest --listTests","test:listen":"node server.js --listen 0 && mocha test/api","test:file":"jest --list-file=x"}}
JSON
result=$(detect_test_commands)
assert_eq "--list standalone dropped; --listTests, --listen, --list-file kept" "npm test
npm run test:listed
npm run test:listen
npm run test:file" "$result"

cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest --config jest.config.js","test:same":"jest --config jest.config.js","test:unit":"jest --config jest.config.js --selectProjects unit"}}
JSON
result=$(detect_test_commands)
assert_eq "identical body dropped; a different body kept" "npm test
npm run test:unit" "$result"

# Generic projects: none of these are duplicates of the primary
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest","test:mocha":"node server.js --listen 0 && mocha test/api","test:smoke":"node test/run.js smoke","test:lint":"bash scripts/check.sh lint","test:vitest":"vitest run --coverage"}}
JSON
result=$(detect_test_commands)
line_count=$(echo "$result" | wc -l | tr -d ' ')
assert_eq "generic projects: no extra script dropped" "5" "$line_count"

# A suite chain under a --pattern primary is not covered by it and stays
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"bash scripts/sw-test-all.sh --pattern loop","test:chain":"bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh"}}
JSON
result=$(detect_test_commands)
if echo "$result" | grep >/dev/null "npm run test:chain"; then
    assert_pass "suite chain kept when the primary uses --pattern"
else
    assert_fail "suite chain kept when the primary uses --pattern" "got: $result"
fi

# A suite chain under a full sw-test-all.sh primary is covered and dropped
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"bash scripts/sw-test-all.sh","test:chain":"bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh"}}
JSON
result=$(detect_test_commands)
assert_eq "suite chain covered by full sw-test-all.sh is dropped" "npm test" "$result"

# Without sw-test-all as primary, a chain of suites is not covered and stays
cat > "$PROJECT_ROOT/package.json" <<'JSON'
{"scripts":{"test":"jest","test:chain":"bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh"}}
JSON
result=$(detect_test_commands)
if echo "$result" | grep >/dev/null "npm run test:chain"; then
    assert_pass "suite chain kept when the primary is not sw-test-all"
else
    assert_fail "suite chain kept when the primary is not sw-test-all" "got: $result"
fi
rm -f "$PROJECT_ROOT/package.json"

# Chain dedupe is per whole segment (#8633 review): every && segment must be exactly one suite
# invocation, with no cd, no other path, no env prefix, no extra command.
_redundant() { if _is_redundant_test_script "$1" "$2"; then echo drop; else echo keep; fi; }
assert_eq "chain of two bare suites is dropped" "drop" "$(_redundant 'bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh' 'bash scripts/sw-test-all.sh')"
assert_eq "--jobs N on the primary is dropped" "drop" "$(_redundant 'bash scripts/sw-test-all.sh -j 4' 'bash scripts/sw-test-all.sh')"
assert_eq "cd prefix on a suite segment is kept" "keep" "$(_redundant 'cd sub && bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh' 'bash scripts/sw-test-all.sh')"
assert_eq "other tree prefix is kept" "keep" "$(_redundant 'bash other/scripts/sw-a-test.sh && bash other/scripts/sw-b-test.sh' 'bash scripts/sw-test-all.sh')"
assert_eq "non-suite segment in the chain is kept" "keep" "$(_redundant 'bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh && bun test' 'bash scripts/sw-test-all.sh')"
assert_eq "env prefix on a suite segment is kept" "keep" "$(_redundant 'SW_EXTRA=1 bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh' 'bash scripts/sw-test-all.sh')"
assert_eq "--list standalone is dropped" "drop" "$(_redundant 'mocha --list' 'jest')"
assert_eq "single suite (smoke) is kept" "keep" "$(_redundant 'bash scripts/sw-e2e-smoke-test.sh' 'bash scripts/sw-test-all.sh')"
assert_eq "chain under --pattern primary is kept" "keep" "$(_redundant 'bash scripts/sw-a-test.sh && bash scripts/sw-b-test.sh' 'bash scripts/sw-test-all.sh --pattern loop')"
assert_eq "|| chain is kept" "keep" "$(_redundant 'bash scripts/sw-a-test.sh || bash scripts/sw-b-test.sh' 'bash scripts/sw-test-all.sh')"
assert_eq "--listen is not --list" "keep" "$(_redundant 'node server.js --listen 0 && mocha test/api' 'jest')"
assert_eq "--list-file is not --list" "keep" "$(_redundant 'jest --list-file=x' 'jest')"
assert_eq "same script with different flags is kept" "keep" "$(_redundant 'jest --config jest.config.js --selectProjects integration-ish' 'jest --config jest.config.js')"
assert_eq "same runner, different script arg is kept" "keep" "$(_redundant 'bash scripts/check.sh lint' 'bash scripts/check.sh test')"

# Empty project returns nothing
result=$(detect_test_commands)
assert_eq "Empty project returns empty" "" "$result"

print_test_results
