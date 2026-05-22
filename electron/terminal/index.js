const ghostty = require("./ghostty");
const terminalApp = require("./terminal-app");
const iterm2 = require("./iterm2");
const tmux = require("./tmux");
const clipboard = require("./clipboard");
const { sleep, runAS, escapeAS } = require("./applescript");
const fs = require("node:fs");
const path = require("node:path");

const HOME = process.env.HOME || "";
const PROJECTS_DIR = path.join(HOME, ".claude", "projects");
const SESSIONS_DIR = path.join(HOME, ".claude", "sessions");

function adapterFor(terminal) {
  switch (terminal) {
    case "Ghostty":
      return ghostty;
    case "Terminal":
      return terminalApp;
    case "iTerm2":
      return iterm2;
    case "tmux":
      return tmux;
    default:
      return clipboard;
  }
}

function encodeCwd(cwd) {
  return cwd.replace(/\//g, "-");
}

function listJsonls(cwd) {
  const dir = path.join(PROJECTS_DIR, encodeCwd(cwd));
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => path.join(dir, f));
}

// Snapshot of the per-PID session files claude writes on TUI boot. These exist
// immediately when claude becomes interactive, whereas the per-project JSONL is
// only created on the first user/assistant exchange — so the JSONL is unsuitable
// as a "claude is ready" signal.
function listSessionFiles() {
  if (!fs.existsSync(SESSIONS_DIR)) return [];
  return fs
    .readdirSync(SESSIONS_DIR)
    .filter((f) => f.endsWith(".json"))
    .map((f) => path.join(SESSIONS_DIR, f));
}

function readSessionFile(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf-8"));
  } catch {
    return null;
  }
}

// Spawn a new claude session in the given project directory, then inject
// /start-mission once Claude has booted (detected by the JSONL appearing).
async function startMission(projectPath, preferredTerminal = "Ghostty", mode = "window") {
  const adapter = adapterFor(preferredTerminal);
  const sessionsBefore = new Set(listSessionFiles());

  // Spawn a new terminal window/tab that runs `claude` in the project dir.
  await adapter.spawnSession(projectPath, "claude", mode);

  // Wait up to 30 seconds for a new ~/.claude/sessions/<pid>.json to appear
  // whose `cwd` matches our spawned project. claude writes this file the moment
  // its TUI is interactive — well before any per-project JSONL exists (the JSONL
  // is only created on the first user/assistant exchange). Polling the JSONL
  // directory means waiting indefinitely on a fresh window.
  let sessionReady = null;
  for (let i = 0; i < 150; i++) {
    await sleep(200);
    const after = listSessionFiles();
    for (const p of after) {
      if (sessionsBefore.has(p)) continue;
      const obj = readSessionFile(p);
      if (obj && obj.cwd === projectPath) {
        sessionReady = obj;
        break;
      }
    }
    if (sessionReady) break;
  }

  if (!sessionReady) {
    return { ok: false, error: "Claude session did not start within 30s" };
  }

  // Generous settle so the TUI is fully drawn before we keystroke. 400ms was
  // too tight; the keystroke could land mid-redraw and get dropped.
  await sleep(1500);

  // Rename the Claude session to the project name. Claude Code's /rename
  // command also updates the terminal tab/window title (via the OSC escape
  // it emits), and unlike a pre-claude `printf` escape, this is the title
  // claude itself uses — so it sticks for the rest of the session.
  const projectName = path
    .basename(projectPath)
    .replace(/[^a-zA-Z0-9._\- ]/g, "");
  if (projectName) {
    const safeName = escapeAS(projectName);
    await runAS(
      `tell application "System Events" to keystroke "/rename ${safeName}"`
    );
    await runAS(`tell application "System Events" to key code 36`);
    // Let /rename complete before queuing the next slash command.
    await sleep(800);
  }

  // Keystroke /start-mission WITHOUT calling `tell application "Ghostty" to
  // activate` first. The new window from spawnSession is still frontmost
  // (open -na brought it forward). Calling `activate` here would re-pick
  // Ghostty's most-recently-USER-focused window — which is not our spawned
  // window — and the keystroke would land in the wrong tab.
  await runAS(
    `tell application "System Events" to keystroke "/start-mission"`
  );
  await runAS(`tell application "System Events" to key code 36`);

  return { ok: true };
}

module.exports = { startMission };
