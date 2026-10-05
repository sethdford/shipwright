## Bash Script Modularization: Splitting Monoliths into Focused Modules

When decomposing large bash scripts (1500+ lines), follow this pattern used successfully in sw-loop.sh:

### 1. Module Boundaries
- **Identify cohesive responsibilities**: Group related functions (e.g., pattern capture logic, query/lookup logic, aggregation/stats logic)
- **Minimize cross-module dependencies**: Each module should own its data and transformations; prefer passing JSON/stdout over shared state
- **Keep CLI dispatcher thin**: The parent script routes commands to submodules; logic stays in the modules, not the dispatcher

### 2. Shared State & Functions
- **Extract common utilities early**: Logging, JSON parsing, file operations go to a `lib/` directory sourced by all modules
- **Namespace function names**: Prefix functions by module (`memory_capture_*`, `memory_query_*`) to avoid collisions when all are sourced
- **Avoid global state**: Use function arguments and return values; globals are hard to trace across modules

### 3. Bash 3.2 Compatibility (Hard Constraint)
- **No associative arrays** (`declare -A`) — use flat JSON or multiple parallel arrays if needed
- **No `readarray`** — use `while read` loops
- **No parameter expansion** like `${var,,}` (lowercase) — use `tr '[A-Z]' '[a-z]'`
- **Test on bash 3.2**: CI should verify `bash --version` reports 3.2.x compatibility

### 4. Test Harness Updates
- **Keep test structure**: Old test suite should pass with minimal changes (sourcing updates only)
- **Source new modules**: Instead of sourcing monolith, source CLI dispatcher which sources submodules
- **Test module boundaries**: Add tests that verify each module works in isolation (unit tests) and together (integration tests)
- **Mock cross-module calls**: When testing one module, mock its dependencies on others to isolate failures

### 5. CLI Dispatcher Pattern
```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION=<from-parent>

source "$(dirname "$0")/lib/memory-common.sh"  # Shared utilities
source "$(dirname "$0")/sw-memory-capture.sh"  # Capture module
source "$(dirname "$0")/sw-memory-query.sh"    # Query module
source "$(dirname "$0")/sw-memory-aggregate.sh" # Aggregate module

case "$1" in
  capture)    memory_capture_"${2:-}" "${@:3}" ;;
  query)      memory_query_"${2:-}" "${@:3}" ;;
  aggregate)  memory_aggregate_"${2:-}" "${@:3}" ;;
  show)       memory_query_show "${@:2}" ;;  # Backwards compat
  *)          echo "Unknown command: $1" >&2; exit 1 ;;
esac
```

### 6. Version & Documentation
- **Keep VERSION in dispatcher**: Single source of truth for `shipwright memory --version`
- **Update CLAUDE.md**: Document the new module structure and responsibilities in the Architecture section
- **Preserve command help**: `shipwright memory --help` must list all subcommands; delegate to modules if needed

### 7. Performance & Debugging
- **Lazy loading** (if performance-critical): Source modules only when their commands are invoked
- **Trace mode**: Add `SW_TRACE=1 shipwright memory ...` to see which module executed which function
- **Benchmarks**: Compare memory lookup/aggregation speed before/after split; if slower, profile and optimize at module boundaries

### 8. Common Pitfalls
- **Circular sourcing**: Module A sources Module B sources Module A → sourcing loop. Use explicit exports or a lib file only.
- **Subshell bugs**: `cmd | while read` in a module runs in a subshell; variables modified in the loop are lost. Use `while read; done < <(cmd)`.
- **Atomic file writes**: If modules write shared state (e.g., pattern files), use atomic writes (tmp file + mv) to avoid corruption.
- **Test isolation**: If tests modify shared files (memory patterns), clean them up after each test so modules don't interfere.

### Validation Checklist
- All `shipwright memory <cmd>` routes correctly to the right module
- Existing test suite passes (sw-memory-test.sh) with only sourcing changes
- No module exceeds 800 lines (excluding tests and comments)
- Bash 3.2 compatibility verified (no modern syntax)
- Performance regression < 5% on typical operations (lookup, aggregation)
- Module interfaces documented (function signatures, expected inputs/outputs)
