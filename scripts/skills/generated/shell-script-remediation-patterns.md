## Shell Script Auto-Remediation Safety Patterns

Auto-remediation must be non-destructive, idempotent, and verifiable. These patterns prevent corrupting user state.

### Core Principles

**1. Atomic Writes**: Never modify files in-place; use temp file + mv pattern:
```bash
tmpfile=$(mktemp)
# populate tmpfile
mv "$tmpfile" "$target"  # atomic, all-or-nothing, crash-safe
```

**2. Idempotency**: Fix must be safe to run twice. Structure as:
```bash
if ! check_passes; then
  apply_fix
  if check_passes; then
    echo "FIXED: check now passes"
  else
    echo "SKIPPED: fix attempted but check still fails" >&2
    return 1  # leave unchanged if fix fails
  fi
else
  echo "ALREADY_OK: check already passes"
fi
```

**3. Verification Loop**: Re-run check after every fix. Never assume fix succeeded.

**4. Shell RC Backups**: When editing .bashrc/.zshrc/.config/fish/config.fish:
```bash
backup_rc="${rc_file}.bak.$(date +%s)"
cp "$rc_file" "$backup_rc"
echo "Backup: $backup_rc"
# make changes to $rc_file
if verification_fails; then
  mv "$backup_rc" "$rc_file"
  echo "Restored from backup"
else
  rm "$backup_rc"  # only if truly fixed
fi
```

**5. Permission Checks**: Verify write access before attempting fixes:
```bash
if ! [ -w "$target_dir" ]; then
  echo "DIAGNOSTIC: cannot write to $target_dir, skipping auto-fix" >&2
  return 1
fi
```

**6. Clear Reporting**: Report exactly what changed:
- File created/modified/deleted
- Bytes added/removed
- Verification result (pass/fail)
- Backup location if applicable

### Fixable Checks (Auto-Remediate)
- Create missing `.claude/` directories
- Install missing hook symlinks (with verification)
- Add missing PATH entries to shell rc files
- Create missing config skeleton files
- Fix symlink targets (if safe)

### Diagnostic-Only Checks (Never Auto-Fix)
- Missing system binaries (tmux, jq, node) — requires package manager
- Permission errors on system paths — requires chmod/sudo
- GitHub/API access issues — requires OAuth, cannot automate safely
- Version mismatches on installed tools — requires manual update
- Corrupt or conflicting configs — too risky to auto-remediate

### Test Patterns
- Test 1: Fix applied, check passes on re-run
- Test 2: Running --fix again makes no changes (idempotency)
- Test 3: Non-fixable check skipped with diagnostic message
- Test 4: Shell rc backed up, verified, restored if fix failed
- Test 5: Permission error caught, reported, no modification attempted
