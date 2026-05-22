const { clipboard, Notification } = require("electron");

const NAME = "clipboard-fallback";

function notify(body) {
  try {
    new Notification({ title: "Houston", body }).show();
  } catch {
    // ignore notification failures
  }
}

async function injectCommand(session, command) {
  clipboard.writeText(command);
  notify(`Copied "${command}" — switch to your ${session.terminal} window and paste.`);
  return { ok: true, fallbackUsed: true };
}

async function spawnSession(projectPath, command) {
  clipboard.writeText(`cd "${projectPath}" && ${command}`);
  notify("Copied start command — paste it in your terminal.");
  return { ok: true, fallbackUsed: true };
}

module.exports = { NAME, injectCommand, spawnSession };
