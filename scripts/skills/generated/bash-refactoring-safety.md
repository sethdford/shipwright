## Bash Monolith Decomposition & Refactoring Safety

When splitting a large shell script (>1000 lines) into sourced lib modules, three mistakes cause silent failures:

### 1. Circular Dependency Trap
**Problem**: Module A sources module B, which sources module A (direct or indirect). Bash silently re-executes initialization code, corrupts variables.

**Prevention**:
- Map module dependencies upfront (draw a DAG).
- Each function has ONE owner module; never duplicate across modules.
- Source order in orchestrator must be topological (leaf modules first).
- Add guard clauses: `[[ -n "${_lib_loop_iteration_loaded:-}" ]] && return` at module start.

### 2. Variable Scope & Mutation
**Problem**: Helper functions in new modules assume globals exist (set by orchestrator). When sourced independently for testing, globals are undefined.

**Prevention**:
- Every function must declare its dependencies as comments: `# requires: global_var, _internal_state`
- Prefix internal module state with `_<module>_` (e.g., `_loop_iteration_counter`)
- Test modules in isolation first (source only the lib module, not orchestrator)

### 3. Bash 3.2 Incompatibility in New Code
**Problem**: Developers use `declare -A` (associative arrays, bash 4.0+) in new lib modules; scripts fail on macOS (bash 3.2).

**Prevention**:
- Add pre-commit hook check: grep for bash 4.0+ syntax in new lib files
- Use `[[ $(bash --version | head -1) == "GNU bash, version 3.2" ]] && echo incompatible`
- Approved alternatives for bash 3.2:
  - No: `${var,,}` (lowercase) → Yes: `echo "$var" | tr A-Z a-z`
  - No: `readarray` → Yes: `while read line; done < file`
  - No: `declare -A assoc` (maps) → Yes: use `eval` with namespaced vars or flat files (line-based)

### 4. Test Parity Across Monolith → Modular Split
**Problem**: Old monolithic test runs all functions together; modular tests run each function in isolation. Edge cases like "state leakage between iterations" only show in integrated tests.

**Prevention**:
- Keep original monolithic test file unchanged (sw-loop-test.sh) and passing
- New modular test files test each module in isolation
- Add integration test file (sw-lib-loop-integration-test.sh) that sources all modules and runs end-to-end scenarios
- Integration test must cover: loop across 3+ iterations, session restart, error recovery

### 5. Sourcing vs. Subshell Behavior
**Problem**: Sourced modules run in parent shell (inherit/mutate globals); subshells don't. `( cd dir && cmd )` subshell loses state; sourced `source dir/lib.sh` doesn't.

**Prevention**:
- Be explicit: sourced modules CAN mutate caller state → document what they mutate
- If you need to isolate execution, spawn a new `bash -c` subshell explicitly, not via sourcing
- Test: write a function in the new module that mutates a global, verify it stays mutated after sourcing

### Checklist for sw-loop.sh → scripts/lib/loop-* decomposition

- [ ] Dependency DAG drawn and validated (no cycles)
- [ ] Each function owns one module only
- [ ] Guard clauses in each module to prevent double-sourcing
- [ ] All globals and internal state prefixed correctly
- [ ] grep -r for bash 4.0+ syntax in new lib files (exit 1 if found)
- [ ] Original sw-loop-test.sh passes unchanged (backward compatibility)
- [ ] Each new lib module has isolated unit test (sw-lib-loop-*-test.sh)
- [ ] Integration test runs end-to-end loop scenarios with all modules
- [ ] Source order in sw-loop.sh orchestrator matches dependency order
- [ ] Pre-commit hook rejects new lib files with bash 4.0+ syntax
