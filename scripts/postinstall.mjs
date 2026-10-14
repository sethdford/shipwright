#!/usr/bin/env node
// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  Shipwright — npm postinstall                                           ║
// ║  Copies templates and migrates legacy config directories                ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

import {
  existsSync,
  mkdirSync,
  cpSync,
  readFileSync,
  writeFileSync,
  appendFileSync,
  chmodSync,
  readdirSync,
} from "fs";
import { join, basename } from "path";
import { execSync } from "child_process";
import { USER_AGENTS, USER_HOOKS } from "./install-allowlist.mjs";

const HOME = process.env.HOME || process.env.USERPROFILE;
const PKG_DIR = join(import.meta.dirname, "..");
const SHIPWRIGHT_DIR = join(HOME, ".shipwright");
const LEGACY_DIR = join(HOME, ".claude-teams");
const CLAUDE_DIR = join(HOME, ".claude");

const CYAN = "\x1b[38;2;0;212;255m";
const GREEN = "\x1b[38;2;74;222;128m";
const YELLOW = "\x1b[38;2;250;204;21m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

function info(msg) {
  console.log(`${CYAN}${BOLD}▸${RESET} ${msg}`);
}
function success(msg) {
  console.log(`${GREEN}${BOLD}✓${RESET} ${msg}`);
}
function warn(msg) {
  console.log(`${YELLOW}${BOLD}⚠${RESET} ${msg}`);
}

function ensureDir(dir) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

function copyDir(src, dest) {
  if (!existsSync(src)) return;
  ensureDir(dest);
  cpSync(src, dest, { recursive: true, force: false });
}

/** Copies the named files from src to dest without overwriting; returns how many exist in src. */
function copyFiles(src, dest, names) {
  let found = 0;
  for (const name of names) {
    const from = join(src, name);
    if (!existsSync(from)) continue;
    ensureDir(dest);
    cpSync(from, join(dest, name), { force: false });
    found++;
  }
  return found;
}

try {
  // Ensure expected directories exist
  ensureDir(CLAUDE_DIR);
  ensureDir(join(CLAUDE_DIR, "hooks"));
  ensureDir(LEGACY_DIR);
  ensureDir(SHIPWRIGHT_DIR);

  // Copy team templates → ~/.shipwright/templates/
  copyDir(
    join(PKG_DIR, "tmux", "templates"),
    join(SHIPWRIGHT_DIR, "templates"),
  );
  success("Installed team templates");

  // Copy pipeline templates → ~/.shipwright/pipelines/
  copyDir(
    join(PKG_DIR, "templates", "pipelines"),
    join(SHIPWRIGHT_DIR, "pipelines"),
  );
  success("Installed pipeline templates");

  // Copy settings template → ~/.claude/settings.json.template (if missing)
  const settingsTemplate = join(
    PKG_DIR,
    "claude-code",
    "settings.json.template",
  );
  const settingsDest = join(CLAUDE_DIR, "settings.json.template");
  if (existsSync(settingsTemplate) && !existsSync(settingsDest)) {
    ensureDir(CLAUDE_DIR);
    cpSync(settingsTemplate, settingsDest);
    success("Installed settings template");
  }

  // Install user-facing agent definitions and hooks → ~/.claude/{agents,hooks}/.
  // Allowlisted (see install-allowlist.mjs): dev-only files in .claude/ must not be
  // installed into users' ~/.claude.
  const agentsCount = copyFiles(
    join(PKG_DIR, ".claude", "agents"),
    join(CLAUDE_DIR, "agents"),
    USER_AGENTS,
  );
  if (agentsCount) success("Installed agent definitions");
  const hooksCount = copyFiles(
    join(PKG_DIR, ".claude", "hooks"),
    join(CLAUDE_DIR, "hooks"),
    USER_HOOKS,
  );
  if (hooksCount) success("Installed hooks");

  // Install CLAUDE.md agent instructions → ~/.claude/CLAUDE.md (idempotent)
  const claudeMdSrc = join(PKG_DIR, "claude-code", "CLAUDE.md.shipwright");
  const claudeMdDest = join(CLAUDE_DIR, "CLAUDE.md");
  if (existsSync(claudeMdSrc)) {
    ensureDir(CLAUDE_DIR);
    if (existsSync(claudeMdDest)) {
      const existing = readFileSync(claudeMdDest, "utf8");
      if (!existing.includes("Shipwright")) {
        appendFileSync(
          claudeMdDest,
          "\n---\n\n" + readFileSync(claudeMdSrc, "utf8"),
        );
        success("Appended Shipwright instructions to ~/.claude/CLAUDE.md");
      } else {
        success("~/.claude/CLAUDE.md already contains Shipwright instructions");
      }
    } else {
      cpSync(claudeMdSrc, claudeMdDest);
      success("Installed ~/.claude/CLAUDE.md");
    }
  }

  // Migrate ~/.claude-teams/ → ~/.shipwright/ (non-destructive)
  if (
    existsSync(LEGACY_DIR) &&
    !existsSync(join(SHIPWRIGHT_DIR, ".migrated"))
  ) {
    info("Migrating legacy ~/.claude-teams/ config...");
    copyDir(LEGACY_DIR, SHIPWRIGHT_DIR);
    writeFileSync(join(SHIPWRIGHT_DIR, ".migrated"), new Date().toISOString());
    success("Migrated legacy config (originals preserved)");
  }

  // Set executable bits on all scripts (npm strips them on some platforms)
  const scriptsDir = join(PKG_DIR, "scripts");
  if (existsSync(scriptsDir)) {
    let madeExecutable = 0;
    for (const file of readdirSync(scriptsDir)) {
      const fp = join(scriptsDir, file);
      try {
        chmodSync(fp, 0o755);
        madeExecutable++;
      } catch (_) {
        // skip non-files
      }
    }
    const libDir = join(scriptsDir, "lib");
    if (existsSync(libDir)) {
      for (const file of readdirSync(libDir)) {
        try {
          chmodSync(join(libDir, file), 0o755);
          madeExecutable++;
        } catch (_) {}
      }
    }
    success(`Set executable bits on ${madeExecutable} scripts`);
  }

  // Install shell completions for the user's current shell
  const completionsDir = join(PKG_DIR, "completions");
  if (existsSync(completionsDir)) {
    const shell = basename(process.env.SHELL || "/bin/bash");
    try {
      if (shell === "bash") {
        const dest =
          process.env.BASH_COMPLETION_USER_DIR ||
          join(
            process.env.XDG_DATA_HOME || join(HOME, ".local", "share"),
            "bash-completion",
            "completions",
          );
        ensureDir(dest);
        cpSync(
          join(completionsDir, "shipwright.bash"),
          join(dest, "shipwright"),
        );
        cpSync(join(completionsDir, "shipwright.bash"), join(dest, "sw"));
        success(`Installed bash completions to ${dest}`);
      } else if (shell === "zsh") {
        const dest = join(HOME, ".zfunc");
        ensureDir(dest);
        cpSync(join(completionsDir, "_shipwright"), join(dest, "_shipwright"));
        cpSync(join(completionsDir, "_shipwright"), join(dest, "_sw"));
        success(`Installed zsh completions to ${dest}`);
      } else if (shell === "fish") {
        const dest = join(
          process.env.XDG_CONFIG_HOME || join(HOME, ".config"),
          "fish",
          "completions",
        );
        ensureDir(dest);
        cpSync(
          join(completionsDir, "shipwright.fish"),
          join(dest, "shipwright.fish"),
        );
        cpSync(join(completionsDir, "shipwright.fish"), join(dest, "sw.fish"));
        success(`Installed fish completions to ${dest}`);
      }
    } catch (e) {
      warn(`Could not auto-install completions: ${e.message}`);
      info(`Run: shipwright init  (or: bash scripts/install-completions.sh)`);
    }
  }

  // Print success banner
  console.log();
  console.log(`${GREEN}${BOLD}Shipwright CLI installed!${RESET} Next steps:`);
  console.log(
    `  ${DIM}shipwright init${RESET}    ${DIM}# Set up tmux, hooks, and templates${RESET}`,
  );
  console.log(
    `  ${DIM}shipwright doctor${RESET}  ${DIM}# Verify your setup${RESET}`,
  );
  console.log();
} catch (err) {
  warn(`Postinstall encountered an issue: ${err.message}`);
  warn("Shipwright is installed — some templates may need manual setup.");
  warn(`Run: shipwright doctor`);
}
