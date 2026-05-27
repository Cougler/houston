# Houston — Claude Handoff

> Last updated: 2026-05-26
> Renamed from "mission-control-menubar" on 2026-05-12 — older references to that name in git history / past log entries point to this same project.

## What This Is
Mac menubar app that sits in the top-right of the screen and shows live context % for every running `claude` CLI session. Drops down into a 4-tab popover (Projects / Servers / Skills / Settings). Currently injects only `/start-mission` (the rest of the mission lifecycle is user-typed because of unresolved focus-targeting bugs in keystroke injection). Houston is the packaged, productized successor to Aaron's local Next.js Mission Control dashboard at `~/Apps/mission-control` — intended for paid distribution.

## Status
Active project rows in Houston's Projects tab now show a context progress bar where the chevron used to be, with the `%` beside it and a "Next request: ~XXk tokens" secondary line. The mission lifecycle is consolidated — `/log-mission` is folded into the global End Mission flow and Mission Control coupling (the `log-session.py` call) is removed entirely. Next: install the freshly built DMG (rebuilt this session) and walk through onboarding to verify the new row layout in the packaged build.

## Stack
- Electron 42 (main process: Node, renderer: Chromium)
- Next.js 16.2.6 (App Router, `output: 'export'` for static bundle into Electron)
- React 19
- Tailwind 4 (`@import "tailwindcss"` in globals.css)
- TypeScript
- `osascript` / AppleScript for terminal control (Terminal.app via tty-precise injection for legacy injectCommand; iTerm2 via tty-precise; Ghostty via System Events keystrokes — for Start mission's post-spawn `/rename` and `/start-mission` only)
- `tmux send-keys` for tmux pane injection (unwired now that mission chains are gone)
- Native Electron `dialog.showOpenDialog` for folder picker
- electron-builder 26 for DMG packaging; code-signed with the user's Apple Development cert (not notarized — fine for local install)

## Key Locations
- **App**: `~/Apps/houston/`
- **GitHub**: https://github.com/Cougler/houston (private)
- **Dev server**: `npm run dev` → Next.js on `http://localhost:3401` + Electron popover (concurrently + wait-on)
- **Packaged build**: `npm run build` → `dist/Houston-0.1.0-arm64.dmg` (~189 MB, signed)
- **electron-builder identity**: `appId: com.aaroncougle.houston`, `productName: Houston`, `mac.icon: public/icon.png` (1024×1024, auto-converted to `.icns`)
- **App icon source**: `public/icon.png` (1024×1024)
- **Tray icons**: `electron/icons/tray.png` (21×22) + `tray@2x.png` (41×44) — both regenerated from `public/tray@2x.png` master via `sips -Z`
- **User settings**: `~/Library/Application Support/Houston/settings.json` — keys: `terminal`, `projectsDir`, `spawnMode`
- **Onboarding flag**: `~/Library/Application Support/Houston/onboarded.json` (existence-based)
- **Globally updated skills**:
  - `~/.claude/skills/start-mission/SKILL.md` — step 2 offers `git init` + `gh repo create --private --push` for projects without `.git` or remote (pre-flight scan for secrets); step 3 fast-forward pulls when behind, silent otherwise, stops only on divergence.
  - `~/.claude/CLAUDE.md` `End Mission` — full wrap-up flow: status note → write project `CLAUDE.md` handoff → update `.mc.json` notes → kill dev server → git commit/push (drafts message from diff, asks once, commits with `Co-Authored-By` trailer). Mission Control coupling removed (no more `log-session.py`); `/log-mission` skill deleted (folded in here).
  - `~/.claude/skills/end-mission/SKILL.md` — quick-exit slash command: kills dev servers and exits Claude with no wrap-up. Separate from the "end mission" phrase trigger above.
- **Authoritative session data on disk**: `~/.claude/sessions/<pid>.json` per running claude (sessionId, cwd, startedAt, version, kind, entrypoint)

## Architecture Notes
- `electron/main.js` — entry. Creates the menubar Tray, a frameless BrowserWindow popover, IPC handlers, and calls `app.dock.hide()` for menubar-only mode (`LSUIElement: true` in build config for the packaged app). Tray right-click menu: Reload / Help → Show onboarding / Quit Houston. **In production, loads the renderer via a custom `app://` scheme** (`win.loadURL("app://-/index.html")`, `onboardingWin.loadURL("app://-/onboarding/index.html")`). The scheme is registered as privileged (`standard + secure + supportFetchAPI`) at module load time. Inside `app.whenReady`, `protocol.handle("app", ...)` maps `app://-/<path>` → `file://<PROD_OUT_DIR>/<path>` via `net.fetch(pathToFileURL(...).toString())`. Required because Next's static export emits root-absolute paths (`/_next/...`, `/houstonlogo.png`) that don't resolve under `file://`.
- `electron/preload.js` — `contextBridge.exposeInMainWorld('mc', ...)` exposes: `getDashboard`, `getActiveSessions`, `getProjectDetail`, `getSkillDetail`, `getActiveServers`, `killServer`, `completeOnboarding`, `openPath`, `openExternal`, `hide`, `clearServerCache`, `startDevServer`, `getSettings`, `setSettings`, `pickDirectory`, and `startMission(projectPath, terminal?, mode?)`.
- `electron/settings.js` — reads/writes `<userData>/settings.json`. Validates `terminal ∈ ["Ghostty", "Terminal", "iTerm2"]`, `spawnMode ∈ ["tab", "window"]`. Expands `~` in `projectsDir`. Defaults: Ghostty / `~/Apps` / window.
- `electron/data.js` — `getDashboardData(projectsDir)` and `getProjects(projectsDir)` take the projects directory as a parameter; `getDashboardData` returns `projectsDir` in its payload so the renderer can show it in the empty state. Project icons are auto-detected and embedded as data URLs.
- `electron/dev-servers.js` — `getActiveServers(projectsDir)` lists every TCP listener in ports 3000–9999 via `lsof`, resolves cwd via `lsof -d cwd`, and labels the row with the project basename when cwd is under `projectsDir`.
- `electron/process-detect.js` — load-bearing detection module. Uses `ps -axo pid,ppid,lstart,command` for the snapshot. For each claude PID it reads `~/.claude/sessions/<pid>.json` for the cwd (definitive when present, else `lsof -a -p <pid> -d cwd -Fn` fallback). To pick the JSONL it prefers the **latest-mtime** JSONL in `~/.claude/projects/<encoded-cwd>/` whose mtime ≥ the claude PID's `startMs` — because Claude does NOT update the session file's `sessionId` after `/clear`, the file points at a stale JSONL post-clear, so trusting it gives stale token counts. Birth-time-to-process-start matching (±30s) is the last-resort fallback for older claude versions with no session file.
- **Context size math**: `contextSize = input_tokens + cache_read_input_tokens + cache_creation_input_tokens + output_tokens` from the latest assistant message.
- `electron/terminal/index.js` — adapter dispatch + `startMission` only. Snapshots `~/.claude/sessions/*.json` before spawn → polls up to 30s for a new sessions file whose `cwd` matches → 1500ms settle → keystrokes `/rename <sanitized-projectName>` + Enter → 800ms settle → keystrokes `/start-mission` + Enter.
- `electron/terminal/<adapter>.js`:
  - `terminal-app.js spawnSession(path, cmd, "window"|"tab")` — Sequoia limitation: tab AppleScript dead-ends; workaround is "Prefer tabs when opening documents" → Always.
  - `iterm2.js spawnSession(path, cmd, "window"|"tab")` — both modes work cleanly.
  - `ghostty.js spawnSession(path, cmd, "window"|"tab")` — tab mode uses `application "Ghostty" is running` check + Cmd+T via System Events. Falls back to new window if Ghostty isn't already running.
- `app/page.tsx` — single client component. Polls `getActiveSessions()` every 2s, `getDashboard()` every 30s, `getActiveServers()` every 4s. Header has a sync icon (`SyncIcon`, now using Lucide's `refresh-cw` paths at viewBox 24 / strokeWidth 2) that re-fires all three polls in parallel via `handleSync` and spins for 400ms minimum. Four tabs: Projects / Servers / Skills / Settings, with directional slide transitions (`navDirection` from `TAB_ORDER` diff). Context warning banner under BigStats when `contextPct >= WARN_PCT` (25%). All buttons unified to `rounded-[8px]`, `font-semibold`, `letterSpacing: -0.01em`. **`ActiveSessionRow`**: dot indicator on the left, project name + `Next request: ~XXk tokens` secondary line in the middle, and a 72×5px rounded progress bar followed by the `%` text on the right (no chevron). Bar + `%` share the threshold color (`ctxColor(pct)`); bar fill animates `width 200ms ease`. Dead helpers `timeAgo` and `formatModel` removed along with the `ago` local; `formatTokens` still in use.
- `app/onboarding/page.tsx` — 7-step flow: Welcome → Terminal picker → Projects folder picker → Projects intro → Mission lifecycle → Other tabs → "You're all set". Two interactive steps gate Continue; existing settings hydrate on revisit.
- `next.config.ts` — `output: 'export'`, `trailingSlash: true`, `images.unoptimized: true`. Electron loads via `app://-/index.html` in production; `http://localhost:3401` in dev.
- `package.json` — `name: "houston"`, `build.appId: "com.aaroncougle.houston"`, `build.productName: "Houston"`, `build.mac.icon: "public/icon.png"`, `build.mac.extendInfo.LSUIElement: true` (menubar-only).

## Recent Changes (this session)
- **Active project rows redesigned.** In `ActiveSessionRow` (`app/page.tsx`): replaced the right-side `ChevronRightIcon` with a 72×5px rounded progress bar, with the `pct%` text immediately to the bar's right (`minWidth: 28` so the bar position stays steady). Bar fill uses `ctxColor(pct)` to match the dot color; transitions `width 200ms ease`. Secondary line under the project name went through three iterations — `Context used: {pct}%` → `~Xk tokens` → final form `Next request: ~{formatTokens(contextSize)} tokens`. Removed unused helpers `timeAgo` and `formatModel`, and the `ago` local. `formatTokens` still in use elsewhere; `ChevronRightIcon` still used by 3 other rows.
- **Consolidated the mission lifecycle.** Deleted `~/.claude/skills/log-mission/` entirely. Folded its handoff-CLAUDE.md write step into the global End Mission flow in `~/.claude/CLAUDE.md` — new ordering: status note → write project handoff `CLAUDE.md` → update `.mc.json` notes → kill dev server → git commit/push → confirm. The git step now explicitly documents the "on decline" path (CLAUDE.md + `.mc.json` still persist locally for next session). Dropped the `log-session.py` invocation entirely.
- **Removed Mission Control coupling.** Updated `~/.claude/skills/end-mission/SKILL.md` footer to reflect that `/end-mission` is the quick-exit path and the phrase "end mission" is the full wrap-up. Updated Houston's CLAUDE.md "Globally updated skills" list to remove the deleted log-mission entry and document the new End Mission shape.
- **Saved project memory.** Added `project_decouple_mission_control.md` under `~/.claude/projects/-Users-aaroncougle-Apps-houston/memory/` so future sessions remember Houston stands alone — `.mc.json` keeps its name but isn't "MC's file."
- **Rebuilt the DMG.** `npm run build` → fresh `dist/Houston-0.1.0-arm64.dmg` (189 MB), signed with the Apple Development cert. Same advisory warnings as before (missing `description`/`author`, duplicate `react-dom`, notarization skipped) — none blocking.

## What's Next
- **Install the freshly built DMG** and eyeball the new ActiveSessionRow layout in the packaged build — confirm the progress bar + `%` arrangement is balanced and doesn't crowd long project names at small popover widths.
- **End-to-end packaged-app walk-through**: onboarding (terminal + folder pickers) → tray icon sharpness on Retina → Settings persistence across relaunches → active-session detection → Start mission spawning → dev/browser hover buttons → app icon in Finder + DMG window + About dialog.
- **Verify the new start-mission git-setup step** by running on a project without a remote — confirms the `gh repo create` branch end-to-end.
- **Single-instance lock**: `app.requestSingleInstanceLock()` if dock-launcher clicks while Houston is running spawn duplicate instances.
- **Resolve Terminal.app tab-mode** under macOS Sequoia. Doc the "Prefer tabs when opening documents" workaround in Settings sub-label, or point users at iTerm2.
- **Restart-friction in dev**: `concurrently -k` doesn't reload Electron when `electron/*.js` changes — consider a nodemon-style watcher.
- **Stale `missionlog.md`**: now that `/log-mission` is gone, the file no longer gets appended to. Decide whether to keep it as historical record (current state) or delete it.
- Carried over: Swift helper for Ghostty AX targeting (would unblock proper tab-targeting + potentially revive Log/End if focus race is solved), `.icns` polish if the auto-generated one looks off in any context, end-to-end DMG build test in a clean environment.

## Known Issues / Gotchas
- **Terminal.app "Tab" spawn mode opens a new window** under macOS Sequoia. AppleScript dead-ends: `do script "..." in front window` runs in the active tab; `make new tab` is unsupported; synthesized Cmd+T via key code 17 silently no-ops; "New Tab" menu item creates a new window. Workaround: System Settings → Desktop & Dock → "Prefer tabs when opening documents" → Always.
- **Ghostty "Tab" mode is focus-sensitive**. `tell application "Ghostty" to activate` brings Ghostty's most-recently-focused window forward; Cmd+T creates the new tab there.
- **Residual focus race for the post-spawn `/rename` and `/start-mission` keystrokes**.
- **Settings tab shows "Loading…" if Electron hasn't picked up the new IPC handlers** — happens whenever `electron/*.js` changes hot-reload skips. Manual fix: Ctrl+C and rerun `npm run dev`.
- **30s timeout on session-file readiness** for Start mission.
- **Port 3401 is hardcoded** for dev. Change in both `package.json` scripts and `electron/main.js` `DEV_URL`.
- **First-run permissions for the packaged Houston.app**: needs Accessibility (System Events keystrokes for `/rename` + `/start-mission`) + Automation (controlling Terminal/iTerm/Ghostty for spawnSession) grants. These are per-bundle, so the packaged Houston.app is a different identity than the dev Electron.app — the user will see fresh permission prompts on first packaged-app launch.
- **`concurrently` doesn't auto-restart Electron** on `electron/*.js` edits.
- **electron-builder warnings**: `description` and `author` fields missing in `package.json`; duplicate `react-dom@19.2.4` in the dep tree; macOS notarization is skipped (`notarize` options not generated). None affect local install/testing; matter for outside-the-machine distribution.
- **Process detection is read-only** — the app never modifies `~/.claude/projects/` JSONLs or `~/.claude/sessions/*.json`.
- **Session JSON files are not always present.** Only recent claude versions emit `~/.claude/sessions/<pid>.json`. Code falls back to birth-time correlation when missing.
- **No projection of in-flight tokens.** If the user has just typed a message but Claude hasn't responded yet, that message isn't in the JSONL usage block.
