#!/usr/bin/env node
// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  Shipwright — npm postinstall                                           ║
// ║  Copies templates and migrates legacy config directories                ║
// ╚═══════════════════════════════════════════════════════════════════════════╝

import { existsSync, mkdirSync, cpSync, readFileSync } from "fs";
import { join } from "path";

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

function info(msg) { console.log(`${CYAN}${BOLD}▸${RESET} ${msg}`); }
function success(msg) { console.log(`${GREEN}${BOLD}✓${RESET} ${msg}`); }
function warn(msg) { console.log(`${YELLOW}${BOLD}⚠${RESET} ${msg}`); }

function ensureDir(dir) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

function copyDir(src, dest) {
  if (!existsSync(src)) return;
  ensureDir(dest);
  cpSync(src, dest, { recursive: true, force: false });
}

try {
  // Copy team templates → ~/.shipwright/templates/
  copyDir(join(PKG_DIR, "tmux", "templates"), join(SHIPWRIGHT_DIR, "templates"));
  success("Installed team templates");

  // Copy pipeline templates → ~/.shipwright/pipelines/
  copyDir(join(PKG_DIR, "templates", "pipelines"), join(SHIPWRIGHT_DIR, "pipelines"));
  success("Installed pipeline templates");

  // Copy settings template → ~/.claude/settings.json.template (if missing)
  const settingsTemplate = join(PKG_DIR, "claude-code", "settings.json");
  const settingsDest = join(CLAUDE_DIR, "settings.json.template");
  if (existsSync(settingsTemplate) && !existsSync(settingsDest)) {
    ensureDir(CLAUDE_DIR);
    cpSync(settingsTemplate, settingsDest);
    success("Installed settings template");
  }

  // Migrate ~/.claude-teams/ → ~/.shipwright/ (non-destructive)
  if (existsSync(LEGACY_DIR) && !existsSync(join(SHIPWRIGHT_DIR, ".migrated"))) {
    info("Migrating legacy ~/.claude-teams/ config...");
    copyDir(LEGACY_DIR, SHIPWRIGHT_DIR);
    // Write migration marker so we don't re-copy on every install
    const { writeFileSync } = await import("fs");
    writeFileSync(join(SHIPWRIGHT_DIR, ".migrated"), new Date().toISOString());
    success("Migrated legacy config (originals preserved)");
  }

  // Print success banner
  const version = JSON.parse(readFileSync(join(PKG_DIR, "package.json"), "utf8")).version;
  console.log();
  console.log(`${CYAN}${BOLD}  ⚓ Shipwright v${version} installed${RESET}`);
  console.log();
  console.log(`  Next steps:`);
  console.log(`  ${DIM}$${RESET} shipwright doctor     ${DIM}# Verify your setup${RESET}`);
  console.log(`  ${DIM}$${RESET} shipwright session    ${DIM}# Launch an agent team${RESET}`);
  console.log(`  ${DIM}$${RESET} shipwright pipeline   ${DIM}# Run a delivery pipeline${RESET}`);
  console.log();
} catch (err) {
  warn(`Postinstall encountered an issue: ${err.message}`);
  warn("Shipwright is installed — some templates may need manual setup.");
  warn(`Run: shipwright doctor`);
}
