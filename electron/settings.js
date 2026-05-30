const fs = require("node:fs");
const path = require("node:path");

const HOME = process.env.HOME || "";
const SUPPORTED_TERMINALS = ["Ghostty", "Terminal", "iTerm2"];
const SUPPORTED_SPAWN_MODES = ["tab", "window"];
const DEFAULTS = {
  terminals: ["Ghostty"],
  projectsDir: path.join(HOME, "Apps"),
  spawnMode: "window",
  permissionsRequestedAt: null,
};

function settingsPath(app) {
  return path.join(app.getPath("userData"), "settings.json");
}

function expandHome(p) {
  if (typeof p !== "string") return p;
  if (p === "~") return HOME;
  if (p.startsWith("~/")) return path.join(HOME, p.slice(2));
  return p;
}

function normalizeTerminals(obj) {
  // Migrate legacy single-terminal field to terminals[].
  if (Array.isArray(obj.terminals)) {
    const filtered = obj.terminals.filter((t) => SUPPORTED_TERMINALS.includes(t));
    return filtered.length ? filtered : [DEFAULTS.terminals[0]];
  }
  if (typeof obj.terminal === "string" && SUPPORTED_TERMINALS.includes(obj.terminal)) {
    return [obj.terminal];
  }
  return [...DEFAULTS.terminals];
}

function read(app) {
  let obj = {};
  try {
    const raw = fs.readFileSync(settingsPath(app), "utf-8");
    obj = JSON.parse(raw);
  } catch {
    // First run / corrupt — fall through with defaults.
  }
  const merged = { ...DEFAULTS, ...obj };
  merged.terminals = normalizeTerminals(merged);
  merged.projectsDir = expandHome(merged.projectsDir);
  // The legacy `terminal` field is no longer used; drop it so it doesn't drift.
  delete merged.terminal;
  return merged;
}

function write(app, patch) {
  const current = read(app);
  const next = { ...current, ...patch };
  next.terminals = normalizeTerminals(next);
  if (next.spawnMode && !SUPPORTED_SPAWN_MODES.includes(next.spawnMode)) {
    next.spawnMode = DEFAULTS.spawnMode;
  }
  // Terminal.app's tab APIs are broken on macOS Sequoia (see known issues in
  // CLAUDE.md), so force window mode whenever Terminal is the primary.
  if (next.terminals[0] === "Terminal") {
    next.spawnMode = "window";
  }
  if (next.projectsDir) {
    next.projectsDir = expandHome(next.projectsDir);
    if (!path.isAbsolute(next.projectsDir)) {
      next.projectsDir = DEFAULTS.projectsDir;
    }
  }
  delete next.terminal;
  try {
    fs.mkdirSync(app.getPath("userData"), { recursive: true });
    fs.writeFileSync(settingsPath(app), JSON.stringify(next, null, 2));
    return next;
  } catch (e) {
    throw new Error(`failed to write settings: ${e?.message || e}`);
  }
}

const TERMINAL_BUNDLE_PATHS = {
  Ghostty: [
    "/Applications/Ghostty.app",
    path.join(HOME, "Applications/Ghostty.app"),
  ],
  Terminal: [
    "/System/Applications/Utilities/Terminal.app",
    "/Applications/Utilities/Terminal.app",
  ],
  iTerm2: [
    "/Applications/iTerm.app",
    path.join(HOME, "Applications/iTerm.app"),
  ],
};

function getInstalledTerminals() {
  const result = {};
  for (const name of SUPPORTED_TERMINALS) {
    const paths = TERMINAL_BUNDLE_PATHS[name] || [];
    result[name] = paths.some((p) => {
      try {
        return fs.existsSync(p);
      } catch {
        return false;
      }
    });
  }
  return result;
}

module.exports = {
  read,
  write,
  getInstalledTerminals,
  SUPPORTED_TERMINALS,
  SUPPORTED_SPAWN_MODES,
  DEFAULTS,
};
