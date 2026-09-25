#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright project-detect test — Unit tests for project detection       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Project Detect Tests"

setup_test_env "sw-project-detect-test"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/project-detect.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

# Create a Node.js project structure
create_nodejs_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/package.json" <<'EOF'
{
  "name": "test-app",
  "version": "1.0.0",
  "description": "Test app",
  "main": "index.js",
  "scripts": {
    "test": "jest",
    "build": "next build",
    "dev": "next dev"
  },
  "dependencies": {
    "next": "^14.0.0",
    "react": "^18.0.0",
    "jest": "^29.0.0"
  }
}
EOF
}

# Create a Python project structure
create_python_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/pyproject.toml" <<'EOF'
[project]
name = "test-app"
version = "1.0.0"

[build-system]
requires = ["setuptools"]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
    mkdir -p "$dir/tests"
    cat > "$dir/tests/test_example.py" <<'EOF'
def test_example():
    assert True
EOF
}

# Create a Go project structure
create_golang_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/go.mod" <<'EOF'
module github.com/example/app

go 1.21

require github.com/gin-gonic/gin v1.9.0
EOF
}

# Create a Rust project structure
create_rust_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/Cargo.toml" <<'EOF'
[package]
name = "test-app"
version = "0.1.0"
edition = "2021"

[dependencies]
actix-web = "4"
EOF
}

# Create a Ruby Rails project
create_ruby_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/Gemfile" <<'EOF'
source 'https://rubygems.org'

gem 'rails', '~> 7.0'
gem 'rspec-rails'
EOF
}

# Create a Java/Maven project
create_java_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/pom.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project>
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.example</groupId>
    <artifactId>test-app</artifactId>
    <version>1.0.0</version>
    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
    </dependencies>
</project>
EOF
}

# Create a small bash project
create_bash_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/test.sh" <<'EOF'
#!/bin/bash
echo "Hello"
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_type with Node.js
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_type — Node.js"

test_proj="$TEST_TEMP_DIR/nodejs-project"
create_nodejs_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects nodejs type" "$result" ".type" "nodejs"
assert_json_key "Detects next framework" "$result" ".framework" "next"
assert_json_key "Detects npm build tool" "$result" ".build_tool" "npm"
assert_json_key "Detects jest test runner" "$result" ".test_runner" "jest"

# ─── Test: project_detect_type with Python ───────────────────────────────────
print_test_section "project_detect_type — Python"

test_proj="$TEST_TEMP_DIR/python-project"
create_python_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects python type" "$result" ".type" "python"
assert_json_key "Detects pip build tool" "$result" ".build_tool" "pip"
assert_json_key "Detects pytest runner" "$result" ".test_runner" "pytest"

# ─── Test: project_detect_type with Golang ────────────────────────────────────
print_test_section "project_detect_type — Golang"

test_proj="$TEST_TEMP_DIR/golang-project"
create_golang_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects golang type" "$result" ".type" "golang"
assert_json_key "Detects gin framework" "$result" ".framework" "gin"
assert_json_key "Detects go build tool" "$result" ".build_tool" "go"

# ─── Test: project_detect_type with Rust ──────────────────────────────────────
print_test_section "project_detect_type — Rust"

test_proj="$TEST_TEMP_DIR/rust-project"
create_rust_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects rust type" "$result" ".type" "rust"
assert_json_key "Detects actix-web framework" "$result" ".framework" "actix-web"
assert_json_key "Detects cargo build tool" "$result" ".build_tool" "cargo"

# ─── Test: project_detect_type with Ruby ──────────────────────────────────────
print_test_section "project_detect_type — Ruby"

test_proj="$TEST_TEMP_DIR/ruby-project"
create_ruby_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects ruby type" "$result" ".type" "ruby"
assert_json_key "Detects bundler build tool" "$result" ".build_tool" "bundler"

# ─── Test: project_detect_type with Java ──────────────────────────────────────
print_test_section "project_detect_type — Java"

test_proj="$TEST_TEMP_DIR/java-project"
create_java_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects java type" "$result" ".type" "java"
assert_json_key "Detects maven build tool" "$result" ".build_tool" "maven"

# ─── Test: project_detect_type with Bash ──────────────────────────────────────
print_test_section "project_detect_type — Bash"

test_proj="$TEST_TEMP_DIR/bash-project"
create_bash_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects bash type" "$result" ".type" "bash"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_test_cmd
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_test_cmd — Node.js"

test_proj="$TEST_TEMP_DIR/nodejs-tests"
create_nodejs_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "nodejs")

assert_eq "Node.js test command" "npm test" "$result"

# ─── Test: project_detect_test_cmd with Python ────────────────────────────────
print_test_section "project_detect_test_cmd — Python"

test_proj="$TEST_TEMP_DIR/python-tests"
create_python_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "python")

assert_eq "Python test command" "pytest" "$result"

# ─── Test: project_detect_test_cmd with Rust ──────────────────────────────────
print_test_section "project_detect_test_cmd — Rust"

test_proj="$TEST_TEMP_DIR/rust-tests"
create_rust_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "rust")

assert_eq "Rust test command" "cargo test" "$result"

# ─── Test: project_detect_test_cmd with Go ────────────────────────────────────
print_test_section "project_detect_test_cmd — Golang"

test_proj="$TEST_TEMP_DIR/golang-tests"
create_golang_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "golang")

assert_eq "Go test command" "go test ./..." "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_build_cmd
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_build_cmd — Node.js"

test_proj="$TEST_TEMP_DIR/nodejs-build"
create_nodejs_project "$test_proj"
result=$(project_detect_build_cmd "$test_proj" "nodejs")

assert_eq "Node.js build command" "npm run build" "$result"

# ─── Test: project_detect_build_cmd with Rust ─────────────────────────────────
print_test_section "project_detect_build_cmd — Rust"

test_proj="$TEST_TEMP_DIR/rust-build"
create_rust_project "$test_proj"
result=$(project_detect_build_cmd "$test_proj" "rust")

assert_eq "Rust build command" "cargo build" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_recommend_template
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_recommend_template — Small project"

test_proj="$TEST_TEMP_DIR/small-project"
create_nodejs_project "$test_proj"
result=$(project_recommend_template "$test_proj") || true

# Small project should get "fast" template
assert_json_key "Small project recommends fast" "$result" ".template" "fast"

# ─── Test: project_recommend_template with Docker ────────────────────────────
print_test_section "project_recommend_template — Deployment project"

test_proj="$TEST_TEMP_DIR/deploy-project"
mkdir -p "$test_proj"

# Create Dockerfile first (before detection)
cat > "$test_proj/Dockerfile" <<'EOF'
FROM node:18
WORKDIR /app
COPY . .
RUN npm install
CMD ["npm", "start"]
EOF

# Then create minimal project files
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF

result=$(project_recommend_template "$test_proj") || true

# Project with Dockerfile should get "deployed" template
assert_json_key "Deployment project recommends deployed" "$result" ".template" "deployed"

# ─── Test: project_recommend_template returns JSON with reason ──────────────────
print_test_section "project_recommend_template — JSON structure"

test_proj="$TEST_TEMP_DIR/struct-project"
create_nodejs_project "$test_proj"
result=$(project_recommend_template "$test_proj") || true

assert_contains "Has template field" "$result" '"template":'
assert_contains "Has confidence field" "$result" '"confidence":'
assert_contains "Has reason field" "$result" '"reason":'

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_all
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_all — Full detection"

test_proj="$TEST_TEMP_DIR/full-detect"
create_nodejs_project "$test_proj"

result=$(project_detect_all "$test_proj") || true

assert_contains "Full detection includes type" "$result" '"type":'
assert_contains "Full detection includes framework" "$result" '"framework":'
assert_contains "Full detection includes build_tool" "$result" '"build_tool":'
assert_contains "Full detection includes test_runner" "$result" '"test_runner":'
assert_contains "Full detection includes test_cmd" "$result" '"test_cmd":'
assert_contains "Full detection includes recommended_template" "$result" '"recommended_template":'
assert_contains "Full detection includes cache timestamp" "$result" '"cached_at":'

# ─── Test: project_detect_all caching ──────────────────────────────────────────
print_test_section "project_detect_all — Cache behavior"

test_proj="$TEST_TEMP_DIR/cache-project"
create_nodejs_project "$test_proj"

# First call creates cache
result1=$(project_detect_all "$test_proj")

# Cache file should exist
if [[ -f "$test_proj/.claude/project-detection.json" ]]; then
    assert_pass "Cache file created at .claude/project-detection.json"
else
    assert_fail "Cache file created at .claude/project-detection.json"
fi

# Second call should use cache — sleep past a second boundary so a cache miss
# (fresh cached_at timestamp) can't produce an identical result by accident
sleep 1
result2=$(project_detect_all "$test_proj")

if [[ "$result1" == "$result2" ]]; then
    assert_pass "Cached detection returns same result"
else
    assert_fail "Cached detection returns same result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Edge cases
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Edge cases"

# Project with yarn
test_proj="$TEST_TEMP_DIR/yarn-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF
touch "$test_proj/yarn.lock"
result=$(project_detect_type "$test_proj") || true
assert_json_key "Detects yarn lock" "$result" ".build_tool" "yarn"

# Project with pnpm
test_proj="$TEST_TEMP_DIR/pnpm-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF
touch "$test_proj/pnpm-lock.yaml"
result=$(project_detect_type "$test_proj") || true
assert_json_key "Detects pnpm lock" "$result" ".build_tool" "pnpm"

# Project with multiple frameworks detected (Express)
test_proj="$TEST_TEMP_DIR/express-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "dependencies": {"express": "^4.0"}}
EOF
result=$(project_detect_type "$test_proj") || true
assert_json_key "Detects express framework" "$result" ".framework" "express"

# Project with both Python and Node (Node should win)
test_proj="$TEST_TEMP_DIR/mixed-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test"}
EOF
cat > "$test_proj/requirements.txt" <<'EOF'
requests==2.0
EOF
result=$(project_detect_type "$test_proj") || true
assert_json_key "package.json takes precedence over requirements.txt" "$result" ".type" "nodejs"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Type detection without explicit type parameter
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Auto-detection (type parameter omitted)"

test_proj="$TEST_TEMP_DIR/auto-detect-project"
create_python_project "$test_proj"

# Call without type parameter
result=$(project_detect_test_cmd "$test_proj")

assert_eq "Auto-detect Python test command" "pytest" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
