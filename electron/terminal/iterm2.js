const { runAS, escapeAS } = require("./applescript");

const NAME = "iTerm2";

async function injectCommand(session, command) {
  const tty = session.tty || "";
  const cmd = escapeAS(command);
  const script = `
    tell application "iTerm2"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            try
              if (tty of s) is "${tty}" then
                select t
                tell s to write text "${cmd}"
                return "ok"
              end if
            end try
          end repeat
        end repeat
      end repeat
      return "no-match"
    end tell
  `;
  const { stdout } = await runAS(script);
  return { ok: stdout.trim() === "ok" };
}

async function spawnSession(projectPath, command, mode = "window") {
  const path = escapeAS(projectPath);
  const cmd = escapeAS(command);
  // "tab" opens a new tab in iTerm2's current window if one exists, otherwise
  // falls back to a new window.
  const script =
    mode === "tab"
      ? `
        tell application "iTerm2"
          activate
          if (count of windows) > 0 then
            tell current window to create tab with default profile
            tell current session of current window to write text "cd \\"${path}\\" && ${cmd}"
          else
            set newWindow to (create window with default profile)
            tell current session of newWindow to write text "cd \\"${path}\\" && ${cmd}"
          end if
        end tell
      `
      : `
        tell application "iTerm2"
          activate
          set newWindow to (create window with default profile)
          tell current session of newWindow to write text "cd \\"${path}\\" && ${cmd}"
        end tell
      `;
  await runAS(script);
  return { ok: true };
}

module.exports = { NAME, injectCommand, spawnSession };
