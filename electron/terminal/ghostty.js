const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const { runAS, escapeAS, sleep } = require("./applescript");

const execFileP = promisify(execFile);
const NAME = "Ghostty";

// Ghostty doesn't expose tty-per-window via AppleScript, so we focus the app
// and rely on System Events keystrokes. This requires the user's target tab
// to be the focused tab when injection runs. Future v2: native helper for
// precise window targeting via Accessibility API.
async function injectCommand(_session, command) {
  await runAS(`tell application "Ghostty" to activate`);
  await sleep(250);
  const cmd = escapeAS(command);
  // keystroke types the text; key code 36 is Return.
  await runAS(`tell application "System Events" to keystroke "${cmd}"`);
  await runAS(`tell application "System Events" to key code 36`);
  return { ok: true, fallbackUsed: false };
}

// pgrep can't see Ghostty's process on macOS (likely a sandbox/visibility
// quirk), so we ask AppleScript instead — it reflects the user-visible app
// state reliably.
async function isGhosttyRunning() {
  try {
    const { stdout } = await runAS(`application "Ghostty" is running`);
    return stdout.trim() === "true";
  } catch {
    return false;
  }
}

async function spawnSession(projectPath, command, mode = "window") {
  // Tab mode: only works when Ghostty is already running with a window.
  // Ghostty has no CLI/AppleScript for opening a tab, so we activate
  // Ghostty (brings its most-recently-focused window forward), send Cmd+T
  // to create a new tab in that window, then type `cd <path> && <cmd>`.
  // If Ghostty isn't running yet there's no window to attach a tab to —
  // fall through to a fresh `open -na` spawn.
  if (mode === "tab" && (await isGhosttyRunning())) {
    const fullCmd = `cd "${projectPath}" && ${command}`;
    const escaped = escapeAS(fullCmd);
    await runAS(`tell application "Ghostty" to activate`);
    await sleep(300);
    await runAS(
      `tell application "System Events" to keystroke "t" using {command down}`
    );
    // Let the new tab fully open before typing; shells take a beat to draw.
    await sleep(600);
    await runAS(`tell application "System Events" to keystroke "${escaped}"`);
    await runAS(`tell application "System Events" to key code 36`);
    return { ok: true };
  }
  // Window mode (or tab-mode fallback when no Ghostty windows exist yet).
  await execFileP("open", [
    "-na",
    "Ghostty.app",
    "--args",
    `--working-directory=${projectPath}`,
    "-e",
    command,
  ]);
  return { ok: true };
}

module.exports = { NAME, injectCommand, spawnSession };
