const { execFile } = require("node:child_process");
const { promisify } = require("node:util");

const execFileP = promisify(execFile);
const NAME = "tmux";

async function findPaneForTty(tty) {
  try {
    const { stdout } = await execFileP("tmux", [
      "list-panes",
      "-a",
      "-F",
      "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}",
    ]);
    for (const line of stdout.split("\n")) {
      const [paneTty, paneId] = line.trim().split(/\s+/);
      if (paneTty === tty) return paneId;
    }
  } catch {
    // tmux not running
  }
  return null;
}

async function injectCommand(session, command) {
  const target = await findPaneForTty(session.tty);
  if (!target) return { ok: false, error: "tmux pane not found" };
  await execFileP("tmux", ["send-keys", "-t", target, command, "Enter"]);
  return { ok: true };
}

async function spawnSession(_projectPath, _command) {
  return { ok: false, error: "tmux spawn not supported — start a new pane manually" };
}

module.exports = { NAME, injectCommand, spawnSession };
