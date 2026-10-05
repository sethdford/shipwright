# ADR-0007: Split sw-memory.sh into Capture, Query, and Aggregation Modules

**Date**: 2026-10-05  
**Status**: ACCEPTED  
**Issue**: #7690  
**Authors**: Claude Haiku 4.5

## Context

`scripts/sw-memory.sh` had grown to 2241 lines with approximately 40 functions grouped into three distinct responsibilities:

1. **Capture**: Recording pipeline learnings, failure patterns, design decisions, metrics
2. **Query**: Searching memory, semantic injection, ranked pattern retrieval
3. **Aggregation**: A/B testing, global rollup, DORA metrics, pattern decay

This monolithic structure made the script difficult to maintain, test, and reason about. Function dependencies crossed between groups, creating implicit coupling. Testing individual functions required sourcing the entire 2241-line module.

## Decision

Split `scripts/sw-memory.sh` into focused modules following the pattern established by the `sw-loop.sh` decomposition:

### New Module Structure

- **`scripts/lib/memory-common.sh`** (89 lines)
  - Shared constants: `MEMORY_DIR`, `GLOBAL_MEMORY`
  - Shared utilities: `repo_hash()`, `_memory_content_hash()`, embedding functions
  - Sourced by all other memory modules

- **`scripts/lib/memory-capture.sh`** (669 lines)
  - `memory_capture_pipeline()` — record completion, failure, success
  - `memory_capture_failure()` — extract patterns from failures
  - `memory_record_fix_outcome()`, `memory_track_fix()` — fix tracking
  - `memory_record_pattern()`, `memory_record_decision()`, `memory_record_metric()` — direct recording

- **`scripts/lib/memory-query.sh`** (532 lines)
  - `memory_ranked_search()`, `memory_semantic_search()` — search operations
  - `memory_inject_goal_context()` — goal-specific context injection
  - `memory_query_fix_for_error()` — retrieve fixes for known errors
  - `memory_closed_loop_inject()` — closed-loop learning injection

- **`scripts/lib/memory-aggregate.sh`** (492 lines)
  - `_memory_aggregate_global()` — promote frequent patterns to global memory
  - `memory_ab_assign_group()`, `memory_ab_record_result()` — A/B testing
  - `memory_dora_baseline()`, `memory_update_metrics()` — DORA metrics
  - Pattern decay and stale entry removal

- **`scripts/lib/memory-admin.sh`** (336 lines)
  - `memory_show()`, `memory_search()` — user-facing CLI
  - `memory_forget()` — reset memory
  - `memory_export()`, `memory_import()` — persistence

- **`scripts/sw-memory.sh`** (168 lines, down from 2241)
  - Thin dispatcher: CLI routing to module commands
  - Bootstrap and module loader with guards
  - Help and version information
  - Maintains backwards-compatibility with `bash sw-memory.sh <cmd>` callers

### Key Design Principles

**Backwards Compatibility**: All existing behaviors preserved:

- `bash sw-memory.sh <cmd>` callers continue to work byte-for-byte
- Sourcing `sw-memory.sh` still defines every function (modules sourced transitively)
- Help output is identical to the baseline
- `sw-memory-test.sh` passes unmodified (22/22 tests)

**Double-Source Guards**: Each module uses the pattern:

```bash
[[ -n "${_MODULE_NAME_LOADED:-}" ]] && return
_MODULE_NAME_LOADED=1
```

This allows safe re-sourcing without re-executing initialization code.

**No Self-Contained Headers**: Modules do NOT include:

- `set -euo pipefail` (inherited from dispatcher)
- `VERSION` variable (defined only in `sw-memory.sh`)
- Standalone test blocks

**Bash 3.2 Compatibility**: No `declare -A`, `readarray`, `${var,,}`, or `${var^^}`

## Alternatives Considered

1. **Top-level `sw-memory-*.sh` files** (rejected)
   - Would clutter the command namespace (auto-listed in docs)
   - Breaks convention established by `sw-loop.sh` decomposition

2. **Three-file split (no common module)** (rejected)
   - Led to code duplication across modules
   - Harder to maintain shared constants and utilities

3. **Lazy-loading modules** (rejected)
   - Adds complexity for minimal performance gain
   - Makes testing harder (guards prevent re-initialization)

## Consequences

### Positive

- Each module now ≤ 800 lines, much easier to reason about and test
- Clear separation of concerns: capture/query/aggregate are isolated
- Adding new memory features no longer requires modifying 2000+ line file
- Reduced sourcing overhead when importing only specific modules
- Memory tests can now mock dependencies per module

### Neutral

- Requires sourcing 5 files instead of 1 (negligible CPU cost, files are small)
- Slightly more complex filesystem structure (`lib/` subdir)

### Negative

- `sw-upgrade.sh` must now copy lib files (already handles loop libs, just apply same pattern)
- A/B testing and pattern decay functions still cross module boundaries (acceptable coupling)

## Validation

- All 22 existing `sw-memory-test.sh` tests pass unmodified
- New `sw-lib-memory-modules-test.sh` verifies module structure, line counts, Bash compatibility
- `shipwright memory <cmd>` output byte-identical to baseline
- Full test suite passes: `npm test`

## Implementation Notes

1. **Module Load Order**: Common must load first, then capture/query/aggregate/admin can load in any order
2. **Guard Variables**: Set in each module to prevent double-initialization
3. **Dispatcher Pattern**: `sw-memory.sh` routes commands by parsing `$1` and delegating to modules
4. **File Locations**: All modules in `scripts/lib/` per CLAUDE.md convention for shared libraries
5. **Upgrade Manifest**: Added all 5 files to `sw-upgrade.sh` manifest for installation

## Related

- Similar split applied to `sw-loop.sh` in prior work (lib/loop-*.sh pattern)
- Constitutional AI rules for code organization in `config/code-constitution.json`
- CLAUDE.md section "Architecture" updated to document new module structure
