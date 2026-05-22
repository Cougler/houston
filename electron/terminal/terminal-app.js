const { runAS, escapeAS } = require("./applescript");

const NAME = "Terminal";

async function injectCommand(session, command) {
  const tty = session.tty || "";
  const cmd = escapeAS(command);
  const script = `
    tell application "Terminal"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          try
            if (tty of t) is "${tty}" then
              set selected of t to true
              set frontmost of w to true
              do script "${cmd}" in t
              return "ok"
            end if
          end try
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
  // Tab mode: `do script "..." in front window` would run the command in the
  // already-active tab, not a new one. So we send Cmd+T via System Events to
  // create a new tab first, then `do script ... in selected tab of front
  // window`. If Terminal has no windows, fall through to a fresh window via
  // `do script` with no `in` clause.
  const script =
    mode === "tab"
      ? `
        tell application "Terminal" to activate
        delay 0.2
        if (count of windows of application "Terminal") = 0 then
          tell application "Terminal" to do script "cd \\"${path}\\" && ${cmd}"
        else
          tell application "System Events" to keystroke "t" using {command down}
          delay 0.4
          tell application "Terminal" to do script "cd \\"${path}\\" && ${cmd}" in selected tab of front window
        end if
      `
      : `
        tell application "Terminal"
          activate
          do script "cd \\"${path}\\" && ${cmd}"
        end tell
      `;
  await runAS(script);
  return { ok: true };
}

module.exports = { NAME, injectCommand, spawnSession };
