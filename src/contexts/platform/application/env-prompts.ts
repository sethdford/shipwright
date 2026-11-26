import { RECIPE_PATH } from "../domain/env-recipe";

/**
 * Tools the recipe author may use: read the repository and write the recipe, nothing else. A
 * subset of config/agent-permissions.json (checked by a test). The agent never installs anything
 * itself: Shipwright runs the recipe in a fresh clone and hands back what failed.
 */
export const ENV_AUTHOR_TOOLS: readonly string[] = [
  "Read",
  "Glob",
  "Grep",
  "Write",
  "Edit",
  "Bash(git ls-files *)",
  "Bash(git log *)",
  "Bash(mkdir *)",
];

/** Trusted instructions for the recipe author. Repository content and command output arrive as data. */
export const ENV_AUTHOR_PROMPT = `You write the environment recipe for this repository: the file ${RECIPE_PATH}.
Shipwright will run it in a fresh clone on a developer Mac or a GitHub Actions runner (macOS or
Linux), cache what it produces, and reuse it for every later run. You cannot run commands
yourself beyond reading the repository; Shipwright runs the recipe and tells you what failed.

Read the README, CONTRIBUTING, CI workflows (.github/workflows), Makefile, lockfiles, toolchain
pins (.nvmrc, .tool-versions, rust-toolchain, .python-version) and docker-compose files to learn
how the project installs its dependencies and runs its tests. Then write ${RECIPE_PATH}:

{
  "version": 1,
  "setup": [["npm", "ci"]],              // argv arrays run in order in the repo root; no shell strings
  "cache": ["node_modules"],             // repo-relative paths setup produces that can be reused
  "keyFiles": ["package-lock.json"],     // files whose content decides whether the cache still fits
  "fingerprint": [["node", "--version"]],// toolchain version commands that also go into the cache key
  "smoke": ["npm", "test", "--", "--listTests"], // quick proof the environment works (under a minute)
  "test": ["npm", "test"],               // the project's test command
  "env": {"POETRY_VIRTUALENVS_IN_PROJECT": "true"}, // non-secret variables for setup and tests
  "services": [{"name": "db", "start": ["docker", "compose", "up", "-d", "db"],
                "ready": ["docker", "compose", "exec", "-T", "db", "pg_isready"],
                "stop": ["docker", "compose", "stop", "db"]}],
  "setupTimeoutSec": 1800
}

Rules:
- JSON only (no comments). Every command is an argv array. When setup needs shell logic, write it
  to .shipwright/setup.sh (bash 3.2 compatible, set -euo pipefail) and call ["bash", ".shipwright/setup.sh"].
- Prefer frozen, lockfile-exact installs (npm ci, pnpm install --frozen-lockfile, uv sync --frozen).
- Keep dependencies inside the repository where the tool allows it (node_modules, .venv,
  vendor/bundle) so they can be cached; list those paths in "cache".
- Never use sudo, never install system packages, never put credentials or tokens in the recipe,
  never download and pipe a script into a shell.
- Only add services the tests need, and only when they can start without credentials.
- The smoke command must be fast and must not need network access beyond package registries.
- Write only ${RECIPE_PATH} and, if needed, .shipwright/setup.sh. Do not change any other file.

When the data below includes a previous attempt's failure, fix the recipe so that failure goes
away. Finish with one line saying what you changed.`;
