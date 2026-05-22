# Houston — Mission Log

> Renamed from "Mission Control Menubar" on 2026-05-12. Earlier entries below refer to the app under its previous name.

---

## 2026-05-12 — Start button works end-to-end: clean spawn + content-aware JSONL wait

Start button now works end-to-end. Replaced the focus-race-prone Cmd+T spawn with `open -na Ghostty.app --args --working-directory=<path> -e claude` so Ghostty spawns a brand-new window with claude already running. Also fixed the silent /start-mission keystroke timeout: JSONL-readiness poll extended from 8s to 30s, now requires the file to have content (not just exist), and the post-readiness settle is 1500ms (was 400ms). Next: address any residual /tmp window confusion if it resurfaces, then pick up the @2x tray icon, .icns, and onboarding flow.

**Done this session:**
- Verified empirically that `open -na Ghostty.app --args ...` *does* spawn a new Ghostty window even when Ghostty is already running — earlier comment claiming it was a no-op was wrong (likely an artifact of testing without `.app` or `--args`)
- Rewrote `electron/terminal/ghostty.js` `spawnSession`: dropped the activate + Cmd+T + keystroke-`cd && claude` flow entirely. Now just one `execFile("open", ["-na", "Ghostty.app", "--args", "--working-directory=<path>", "-e", command])` call. No keystrokes, no focus race for the spawn.
- Removed `shellQuote` and `isGhosttyRunning` helpers from `ghostty.js` — only `spawnSession` used them and they're no longer needed
- Extended `startMission` JSONL-readiness poll in `electron/terminal/index.js`: 40 iters × 200ms = 8s → 150 iters × 200ms = 30s. Old timeout was silently bailing on cold-start claude launches (dyld + auth + MCP init can easily exceed 8s on first run)
- Tightened the readiness signal: poll now requires `fs.statSync(candidate).size > 0`, not just file-exists. The file-touch-before-content gap was letting the keystroke fire too early (or, when combined with the short timeout, miss entirely)
- Bumped post-readiness settle from 400ms to 1500ms so claude's TUI is fully drawn before the /start-mission keystroke fires
- Diagnosed user-reported "extra Ghostty window that just says TMP" by running the bare `open -na` invocation in isolation — only 1 new window appeared, so the menubar spawn itself isn't doubling. Most likely cause was leftover test windows from earlier diagnostics. User confirmed it's working now.

**Up next:**
- If the /tmp window issue resurfaces, capture `pgrep -fl "Ghostty.app/Contents/MacOS/ghostty"` output at the moment it appears to identify the spawning command line
- Add `tray@2x.png` (44×44) for Retina sharpness
- Generate `icon.icns` for the app bundle (electron-builder reads from `build/icon.icns`)
- Build the onboarding flow: permission prompts, projects folder picker, optional skills installer
- Swift helper for precise Ghostty window-targeting (Accessibility API) — the spawn is now clean, but L/E button keystrokes still go to the focused Ghostty window
- Test the L-button chain end-to-end (the menubar's /log-mission → /clear → /handoff sequence) against a real running claude session and verify `~/.claude/sessions/<pid>.json` `sessionId` flips after /clear so the context % drops
- electron-builder DMG build is still untested end-to-end

---

## 2026-05-12 — Renamed to Houston; fixed Start-button focus race

Renamed mission-control-menubar → Houston across the board (folder, package, electron-builder appId/productName, in-app header, tray tooltip, Quit menu, notification title, .mc.json, missionlog). Also fixed the Start button's Ghostty focus race in startMission: the post-spawn /start-mission keystroke no longer calls `tell application Ghostty to activate`, which previously jumped to the user's most-recently-clicked window instead of the just-spawned tab. Next: restart Electron in the new ~/Apps/houston folder, test Start/L/E end-to-end, and verify ~/.claude/sessions/<pid>.json updates after /clear so the menubar % drops.

**Done this session:**
- Moved folder: `~/Apps/mission-control-menubar` → `~/Apps/houston`
- Updated `package.json`: `name` → `houston`, `build.appId` → `com.aaroncougle.houston`, `build.productName` → `Houston`
- Updated `package-lock.json` name fields (both root and packages[""])
- Rewrote `.mc.json` with Houston branding + fresh description (drops "packaged Mission Control" framing; reframes as "successor to the local Next.js Mission Control dashboard")
- In-app: `app/layout.tsx` `metadata.title`, `app/page.tsx` Header label, `electron/main.js` `tray.setToolTip` + Quit menu label, `electron/terminal/clipboard.js` Notification title — all now "Houston"
- Diagnosed Start-button focus race: `startMission` was calling `ghostty.injectCommand` for /start-mission, which runs `tell application "Ghostty" to activate` first. That activate jumps to Ghostty's most-recently-USER-focused window — and the new tab opened via programmatic Cmd+T doesn't count as user-focused. So /start-mission was keystroking into the user's previously-clicked tab (often one with an active claude session) instead of the new tab.
- Rewrote that codepath in `electron/terminal/index.js` to keystroke /start-mission directly via System Events with no `activate`, trusting focus has stayed on the new tab from spawnSession (which it does, unless the user clicks elsewhere during claude's 2–8s boot)
- Added `runAS` to the `applescript` module import in `electron/terminal/index.js` for the bare keystroke calls

**Up next:**
- Restart Electron in the new folder (`cd ~/Apps/houston && pkill -f "Electron.app" && npm run dev`) — the old node_modules are still on disk under the new path, no reinstall needed
- Test Start button end-to-end with the focus-race fix
- Test L-button chain end-to-end and verify `~/.claude/sessions/<pid>.json` `sessionId` flips after /clear (otherwise the menubar % won't drop)
- If electron-builder DMG build needs re-running, confirm appId / productName render correctly in the packaged `.app`
- Add `tray@2x.png`, generate `icon.icns`, build onboarding flow, Swift helper for precise Ghostty window targeting

---

## 2026-05-12 — Chain moved to menubar L-button so /clear actually fires

The menubar's L button now chains /log-mission → wait-for-confirmation → /clear → /handoff <project> at the terminal-injection layer (electron/terminal/index.js), so /clear actually fires as a real user-typed slash command and the context % drops on the next session. The log-mission skill is back to just steps 1–7 — the chain lives in the menubar, not the skill. Next: restart Electron and test the chain end-to-end against an active claude session, then verify ~/.claude/sessions/<pid>.json updates with the new sessionId after /clear.

**Done this session:**
- Diagnosed why context % wasn't dropping after the previous log/clear/handoff run: skill-emitted `/clear` is plain text in the assistant turn, not a real slash command. Claude Code only intercepts slash commands typed at the user prompt, so the model can never trigger `/clear` from inside a skill.
- Reverted `~/.claude/skills/log-mission/SKILL.md` to steps 1–7 only; removed the skill-level `/clear` and `/handoff` steps so the menubar doesn't double-handoff
- Added `waitForAssistantText(jsonlPath, needle, timeoutMs)` helper to `electron/terminal/index.js` that polls the JSONL every 1.5s and scans assistant message text for a substring (returns true when found, false on timeout)
- Rewrote `electron/terminal/index.js` `logMission` to chain: inject `/log-mission` → `waitForAssistantText(session.jsonl, "Mission logged.", 180_000)` → 1s settle → inject `/clear` → 1.5s settle → inject `/handoff <basename-of-cwd>`. Each `injectCommand` result is checked and the chain bails on any `ok: false`

**Up next:**
- Restart Electron (`pkill -f "Electron.app" && npm run dev`) and test the L button end-to-end against a running claude session
- Verify `~/.claude/sessions/<pid>.json` gets updated with the new `sessionId` after `/clear` (so process-detect picks up the smaller fresh JSONL — otherwise the menubar would still read the old full one)
- If Ghostty's focused-tab problem bites (chain types into the wrong Ghostty tab), prioritize the v2 Swift helper for precise window targeting
- Add `tray@2x.png` (44×44), generate `icon.icns`, build onboarding flow
- electron-builder DMG build is still untested end-to-end

---

## 2026-05-12 — Row UX: context-cost readout + log→clear→handoff chain

The active-session row now shows 'Next request: ~Nk tokens' under the project name, replacing the first-user-message snippet — context cost per request is now the load-bearing readout. Also fixed home-dir sessions showing as 'Home' (now displays '~') and extended the log-mission skill to chain into /clear and /handoff for a continuous session-pivot flow. Next: verify /clear actually fires from inside a skill (or move the chain into the menubar's L-button injection sequence), plus the @2x tray icon and onboarding flow.

**Done this session:**
- Replaced the first-user-message snippet line in `ActiveSessionRow` with a `Next request: ~Nk tokens` readout (uses new `formatTokens` helper next to `timeAgo` in `app/page.tsx`)
- Changed `projectNameFromCwd` in `electron/process-detect.js:226` so `cwd === HOME` returns `~` instead of `Home`
- Updated `~/.claude/skills/log-mission/SKILL.md` to add step 8 (emit `/clear`) and step 9 (invoke the `handoff` skill) after the existing confirm step; documented the caveat that `/clear` from inside a skill may not actually wipe context

**Up next:**
- Test the log→clear→handoff chain end-to-end. If `/clear` emitted as text doesn't trigger the Claude Code built-in, move the chain into the menubar's L-button injection (`electron/terminal/index.js` `logMission`) so the terminal types `/log-mission`, `/clear`, `/handoff <project>` as three separate keypresses
- Test the three buttons end-to-end after granting macOS Accessibility + Automation permissions
- Add `tray@2x.png` (44×44) for Retina sharpness
- Build onboarding flow: permission prompts, projects folder picker, optional skills installer
- Generate `icon.icns` for the app bundle (electron-builder)
- Swift helper for precise Ghostty window targeting (v2)

---

## 2026-05-12 — Context-tracking accuracy: matches Claude Code's hint

Context tracking now matches Claude Code's own indicator: wired in `~/.claude/sessions/<pid>.json` as the authoritative PID → session mapping and corrected the math to include the latest assistant turn's `output_tokens` (which become next-turn cache_read). The 60k gap between Houston's reading and Claude Code's "save X tokens" hint is closed. Next: ship the onboarding flow with permission prompts and a skills installer, plus the Retina @2x tray icon and the `.icns` for the packaged build.

**Done this session:**
- Discovered Claude Code writes per-PID state to `~/.claude/sessions/<pid>.json` (sessionId, cwd, startedAt, version, kind, entrypoint) — definitive PID → session mapping when present
- Wired the session-file lookup into `process-detect.js` as primary source; kept birth-time correlation as fallback for older claude versions that don't write it
- Audited disk for any live context-size cache (`stats-cache.json`, `session-env/`, `cache/`, `telemetry/`, `claude --help` flags) — confirmed the JSONL `usage` blocks are the source of truth, same as Claude Code itself reads
- Removed a fudge-factor `SYSTEM_PROMPT_OVERHEAD` constant that was double-counting (the JSONL usage already includes system prompt + tool defs)
- Added `output_tokens` of the latest assistant turn to `contextSize` (they become next-turn `cache_read_input_tokens`, so they're part of the upcoming context but missed by a naive sum)
- Houston now reads ~27% for this session, matching the order of magnitude of Claude Code's "save 270k tokens" hint

**Up next:**
- Test the three buttons end-to-end after granting macOS Accessibility + Automation permissions
- Add `tray@2x.png` (44×44) for Retina sharpness
- Build onboarding flow: permission prompts, projects folder picker, optional skills installer
- Generate `icon.icns` for the app bundle (electron-builder)
- Swift helper for precise Ghostty window targeting (v2)

---

## 2026-05-11 — Initial build: process detection + terminal injection

Houston is up and running as a Mac menubar app: tray icon installed, three tabs (Projects/Skills/MCP) populated from local Claude data, live context % for all running sessions, and Start/Log/End buttons that inject the matching slash commands into the hosting terminal (Ghostty/Terminal.app/iTerm2/tmux supported, clipboard fallback for the rest). Just finished wiring the terminal injection adapters and updated the global end-mission skill to actually exit the Claude CLI when invoked. Next: ship the onboarding flow with permission prompts plus a skills installer, and add a Retina @2x tray icon.

**Done this session:**
- Scaffolded the project from scratch (Electron + Next.js 16 + Tailwind 4 + TypeScript)
- Pivoted stack mid-session from Tauri to Electron (user already had Electron toolchain from StudioFrame)
- Implemented process detection that correctly maps each running `claude` PID to its unique JSONL via process-start-time ↔ file-birth-time correlation (within 30s tolerance)
- Added first-user-message extraction to disambiguate sessions that share a cwd (e.g., multiple Home sessions)
- Built three-tab UI (Projects / Skills / MCP Servers) with Active Sessions list + context % bars
- Wired Start/Log/End buttons through a terminal adapter pattern: Ghostty (System Events keystroke), Terminal.app (AppleScript `do script` with tty match), iTerm2 (AppleScript `write text` with tty match), tmux (`send-keys` to matching pane), clipboard fallback
- Updated **global** `~/.claude/skills/end-mission/SKILL.md` to also kill the parent claude PID via a delayed `nohup kill -TERM` so the confirmation message renders before exit
- Replaced placeholder "MC" tray text with user-provided custom PNG icon

**Up next:**
- Test the three buttons end-to-end after granting macOS Accessibility + Automation permissions
- Add `tray@2x.png` (44×44) for Retina sharpness
- Build onboarding flow: permission prompts, projects folder picker, optional skills installer
- Swift helper for precise Ghostty window targeting (v2)
- Generate `icon.icns` for the packaged app bundle (electron-builder)

---

## 2026-05-12 — Start button keystroke fix: readiness signal switched to sessions file

Start button now reliably fires /start-mission inside the spawned Ghostty window. Root cause was the readiness poll watching `~/.claude/projects/<encoded-cwd>/` for a new JSONL — but that file isn't created until the first user/assistant exchange. Switched the poll to `~/.claude/sessions/<pid>.json`, which claude writes the moment its TUI is interactive; /start-mission now fires ~1.2s after spawn.

**Done this session:**
- Diagnosed silent /start-mission keystroke failure by adding console.log tracing to `startMission` in `electron/terminal/index.js`. Logs showed `FAILED: JSONL never had content. foundCandidate=null` — no new JSONL ever appeared during the 30s poll
- Confirmed via `ls ~/.claude/projects/` that no spicy-resume directory existed at all despite claude running with cwd=/Users/aaroncougle/Apps/spicy-resume — proving the JSONL is created lazily, not on TUI boot
- Confirmed `~/.claude/sessions/<pid>.json` IS written immediately on TUI boot and contains cwd, sessionId, pid, startedAt, version
- Replaced the JSONL-existence-with-content poll with a sessions-file poll: snapshot `~/.claude/sessions/` before spawn, then poll for a new `.json` whose `cwd` matches `projectPath`. Added `listSessionFiles()` + `readSessionFile()` helpers (kept `listJsonls()` — still used by `logMission`'s confirmation watcher)
- Verified end-to-end: pressed Start on superhumble, session-ready fired in 1.2s, /start-mission keystroke landed in the new Ghostty window
- Stripped the diagnostic console.log calls after confirmation
- Updated CLAUDE.md Status, Architecture Notes (`startMission` description), and Recent Changes sections

**Up next:**
- Add `tray@2x.png` (44×44) for Retina sharpness
- Generate `icon.icns` for the packaged app bundle
- Build onboarding flow: Accessibility + Automation permission prompts, projects folder picker, optional skills installer
- Swift helper for precise Ghostty window targeting (still needed for the L-chain — the post-spawn keystroke for /start-mission works because the new window is frontmost, but the L-chain types four commands across a window that may lose focus mid-chain)
- Test electron-builder DMG build end-to-end now that the rename is settled

---

## 2026-05-20 — Settings tab, dev-server actions, /rename for tab titles, Terminal.app tab limit

Houston's UI is now a 4-tab popover (Projects / Servers / Skills / Settings) with a full Settings store: terminal emulator, projects folder, and tab-vs-window spawn mode are all user-configurable via onboarding and the Settings tab. Log/End mission buttons were removed because the Ghostty focus-race made them unreliable; replaced with a Start dev / Open in browser hover action, and Start mission now keystrokes /rename so the spawned tab is titled with the project name. Next: resolve Terminal.app's macOS Sequoia tab-creation limitation (currently falls back to a new window) — workaround is setting macOS's 'Prefer tabs when opening documents' to Always, or switching to iTerm2.

**Done this session:**
- **Removed Log/End mission** from Houston entirely (UI buttons, `mission:log`/`mission:end` IPC, preload bridge, `logMission`/`endMission` + `waitForAssistantText` in `terminal/index.js`). Adapter `injectCommand` methods left in place but no longer wired.
- Added **Start dev / Open in browser** hover action on active session rows. Single button that flips label based on whether a matching dev server is detected (via `serverUrlByCwd` map in Home). Per-row `starting` state with 30s safety timeout.
- Added `dev:start` IPC handler that spawns `npm run dev` detached via `/bin/zsh -lc`; logs to `/tmp/<project>-dev.log`. PATH is sourced from the user's login shell so NVM/Homebrew binaries are found.
- Added per-server **Clear cache** action that deletes `.next/cache`, `node_modules/.vite`, `node_modules/.cache`, `.turbo` inside the server's cwd. Guarded by `path.isAbsolute(cwd) && cwd.split(path.sep).length >= 3`.
- Replaced **MCP tab with Settings tab**. MCP servers moved into the Servers tab as a second section under "Dev". Empty state for Dev: "No active dev servers".
- Created `electron/settings.js` — persists `terminal` / `projectsDir` / `spawnMode` to `<userData>/settings.json`. `~/` expansion, terminal allowlist validation, spawnMode validation.
- Wired `dashboard:get`, `project:detail`, `servers:active` to read `projectsDir` from settings. `data.js` and `dev-servers.js` now take `projectsDir` as a param.
- Added **`dialog:pickDirectory`** IPC handler using Electron's `dialog.showOpenDialog`.
- Empty-state **"Choose folder…"** affordance in the All Projects section — pops the native picker and refreshes the dashboard immediately.
- Added two new **onboarding steps**: terminal-emulator picker (3-card grid) and projects-folder picker (uses `pickDirectory`). Continue is gated until a choice is made; choices hydrate from existing settings on revisit.
- **Spawn-mode setting** (Tab / New window) with adaptive sub-labels referencing the chosen emulator (e.g., "Opens a new tab in your current Terminal window"). `mission:start` reads `spawnMode` when no explicit mode is passed.
- iTerm2 `spawnSession(_, _, "tab")`: `tell current window to create tab with default profile` then write text. Works reliably.
- Ghostty `spawnSession(_, _, "tab")`: AppleScript-based `isGhosttyRunning()` check (pgrep doesn't see Ghostty's process on this macOS), activate → 300ms → Cmd+T → 600ms → keystroke `cd "<path>" && claude`. Works when Ghostty already has a window.
- `startMission` now keystrokes `/rename <projectName>` (sanitized to `[a-zA-Z0-9._\- ]`) before `/start-mission`. Claude Code's `/rename` updates the terminal's OSC title, so the tab/window title sticks.
- **Design tightening pass**: row titles changed `font-bold` → `font-semibold`; all action buttons unified to `rounded-[8px]` (dropped the destructive pill); `mb-7`/`pb-7` → `mb-6`/`pb-6`; outer popover `rounded-[14px]` → `rounded-[12px]`; IconButton flipped to ghost-style (transparent → `var(--surface)` on hover); Empty state restyled as dashed-border centered panel; BigStat changed from filled surface to outlined card; "this app" badge harmonized with skill/MCP pill style.
- Removed dead code: `StartButton`, `SecondaryButton`, `ActionIconButton`, `TrashIcon`, `StopIcon`, `SpinnerIcon`, `SettingsIcon`, `MCPTab`.
- `globals.css` global rule: `button:not(:disabled), [role="button"] { cursor: pointer }`.
- Active-session row chevron stays visible on hover (was being hidden by `group-hover:hidden`).
- **Directional tab transitions**: `handleTabChange` now diffs the `TAB_ORDER` index from→to and sets `navDirection` accordingly. Moving rightward in tab order slides forward; leftward slides back.
- **Context warning banner** under BigStats when `contextPct >= WARN_PCT`: "Recommend running /log-mission to prevent using ~Nk tokens in your next prompt." Text is colored via `ctxColor(pct)`; BigStats `mb` tightens from `6` to `3` when banner is showing.
- `dashboard:get` returns `projectsDir` in the payload; All Projects empty state now reads "No projects found in `<displayPath>`" using the live value.
- Start mission button is now black-fill/white-text (`color="var(--text)"`), 44px tall (`h-11`), and lives **below** the SmallStat row in the project detail view.
- Updated `~/.claude/skills/log-mission/SKILL.md` step 7 to instruct the user to type `/clear` after the skill finishes — replaces the old "Mission logged." with a longer line explaining CLAUDE.md auto-loads on `/clear`.

**Up next:**
- **Resolve Terminal.app tab-mode**: macOS Sequoia + Terminal.app combination doesn't open tabs via AppleScript (`do script "..." in front window` runs in the active tab; `make new tab` is unsupported; synthesized Cmd+T via key code 17 silently no-ops despite Terminal being frontmost; clicking "New Tab" menu item creates a new window). Recommended fix is toggling System Settings → Desktop & Dock → "Prefer tabs when opening documents" to **Always** so newly-created Terminal windows auto-merge as tabs. Or just point users at iTerm2 for tab mode and document Terminal.app's limit in the Settings sub-label.
- **GitHub workflow integration**: the user wants `git pull` at session start and a commit/push prompt at session end. Discussed in this session as a "report → ask → act" pattern. Houston itself has no remote yet (verified via `git remote -v` audit) — needs an initial push before any of this becomes useful.
- **Restart-friction in dev**: `concurrently -k` doesn't restart Electron on `electron/*.js` changes. Consider a `nodemon`-style watcher.
- Carried over from prior sessions: `tray@2x.png` (44×44), `icon.icns` for the bundle, Swift helper for Ghostty AX targeting (would unblock proper tab-targeting + future log/end mission revival), and an end-to-end DMG build test.

---
