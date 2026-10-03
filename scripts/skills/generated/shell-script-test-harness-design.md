## Shell Script Test Harness Design

Shipwright test suites follow a strict pattern for consistency, parallelism, and compatibility. This skill guides creation of new test suites that fit seamlessly into the existing 100+ suite ecosystem.

### Core Pattern

Each test file (`scripts/sw-NAME-test.sh`) implements these elements:

1. **Header**: `#!/bin/bash`, `set -euo pipefail`, VERSION constant, source `scripts/lib/compat.sh`
2. **Mock binaries**: Temporary `$TMPDIR/bin/` directory prepended to PATH; mocks match real command signatures
3. **Test functions**: Named `test_<case>()`, each returns success/failure; no output on success
4. **Counter tracking**: Global `PASS=0 FAIL=0` counters incremented in trap handlers
5. **Output format**: Colored `PASS test_name` / `FAIL test_name` at end; one line per test
6. **Cleanup**: ERR trap calls `cleanup()` which removes `$TMPDIR`; exit code = FAIL count

### Mock Binary Strategy

- Store in `TMPDIR/bin/mockbin.sh` wrapper that routes calls by `$1` to stubbed functions
- Each mock must replicate the real command's exit code and output signature
- Use `echo` to stdout, `echo >&2` to stderr; match exact text if tests depend on it
- Example: `mock_git()` must support `git status --porcelain`, `git log`, `git diff` with real-looking output

### Edge Cases & Failure Paths

For each script being tested, identify:
- **Happy path**: Expected inputs, expected outputs
- **Missing input**: Required arguments omitted (e.g., missing repo path)
- **Permission error**: File/dir not readable (mock with `exit 1` + error message)
- **Invalid data**: Malformed JSON, empty files, unexpected format
- **External command failure**: Dependency missing or broken (mock exits 127)
- **Boundary**: Empty string, very large input, special characters

At least 3-4 test cases per script, covering happy path + 1-2 critical failures.

### Parallelism & Isolation

- Each test function creates its own `$TMPDIR/test_$RANDOM` subdirectory
- Never write to `/tmp` directly or use predictable temp names
- Source files from the repo read-only (no modification)
- Mock binaries are temporary and local to that test run
- No global state shared between test functions

### Bash 3.2 Compatibility

- No `declare -A` (associative arrays)
- No `readarray` or `mapfile`
- No `${var,,}` or `${var^^}` (case conversion)
- No `[[ =~ ]]` regex (use `[[ == ]]` + glob patterns or `grep`)
- No `printf %q` (use `printf %s` + manual escaping for JSON)
- Test with: `bash --version` reports 3.2+ before shipping

### Test Registration

Add to `package.json` `"test"` script:
```json
"test": "npm run test:all",
"test:all": "./scripts/sw-test-all.sh",
...
"test:NAME": "./scripts/sw-NAME-test.sh"
```

`sw-test-all.sh` discovers all `*-test.sh` files and runs them sequentially, summing PASS/FAIL counts.

### Debugging Failed Tests

- Run `./scripts/sw-NAME-test.sh` directly to see colored PASS/FAIL output
- Add `set -x` at top to trace execution
- Check `$TMPDIR/test_*/` contents after failure (don't clean up yet)
- Verify mock binary routing with `bash -x scripts/sw-NAME-test.sh 2>&1 | grep mock`
