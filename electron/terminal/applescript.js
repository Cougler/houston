const { execFile } = require("node:child_process");
const { promisify } = require("node:util");

const execFileP = promisify(execFile);

// Escape a string for safe embedding inside an AppleScript double-quoted literal.
function escapeAS(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

async function runAS(script) {
  return execFileP("osascript", ["-e", script], { encoding: "utf-8" });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

module.exports = { runAS, escapeAS, sleep };
