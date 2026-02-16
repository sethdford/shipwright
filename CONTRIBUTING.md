# Contributing to Shipwright

## Quick Setup

```bash
git clone https://github.com/sethdford/shipwright.git
cd shipwright
./install.sh
shipwright doctor   # verify everything works
```

## Development

### Project Structure

- `scripts/` — CLI scripts (bash). The `sw` router dispatches to `sw-*.sh` subcommands.
- `scripts/lib/` — Shared libraries (helpers, compat, pipeline modules, daemon modules)
- `tmux/` — tmux config and agent overlay
- `tmux/templates/` — Team composition templates (JSON)
- `templates/pipelines/` — Pipeline templates
- `dashboard/` — Real-time WebSocket dashboard (Bun/TypeScript)
- `claude-code/` — Claude Code settings, hooks, and agent instructions
- `completions/` — Shell completions (bash, zsh, fish)
- `website/` — Documentation site (Astro/Starlight)

### Running Tests

```bash
# Run all tests
npm test

# Run a specific test suite
bash scripts/sw-pipeline-test.sh

# Run smoke tests
npm run test:smoke

# Lint shell scripts
shellcheck scripts/sw-*.sh
```

### Writing Tests

Every `scripts/sw-<feature>.sh` should have a corresponding `scripts/sw-<feature>-test.sh`. Tests use a custom bash harness with:

- `setup_env` / `cleanup_env` for temp directory sandboxing
- Mock binaries (git, gh, claude, tmux) in `$TEMP_DIR/bin`
- `run_test "name" function` for test execution
- `assert_*` helpers for assertions

### Shell Conventions

- All scripts use `set -euo pipefail` and ERR traps
- Colors and output helpers come from `scripts/lib/helpers.sh`
- Platform detection from `scripts/lib/compat.sh`
- Exit codes: 0 = success, 1 = error, 2 = check failed

### Commit Messages

Follow conventional commits:

- `fix:` — Bug fixes
- `feat:` — New features
- `docs:` — Documentation changes
- `chore:` — Maintenance, CI, releases
- `refactor:` — Code changes that don't fix bugs or add features

## Autonomous Pipeline

Label a GitHub issue with `shipwright` and the autonomous pipeline processes it automatically. You can also create issues for Shipwright to process:

1. [Create an issue](https://github.com/sethdford/shipwright/issues/new?template=shipwright.yml)
2. Add the `shipwright` label
3. The pipeline handles: triage → plan → build → test → review → PR

## License

MIT
