# Houston — Claude Handoff

> Last updated: 2026-05-20
> Renamed from "mission-control-menubar" on 2026-05-12 — older references to that name in git history / past log entries point to this same project.

## What This Is
Mac menubar app that sits in the top-right of the screen and shows live context % for every running `claude` CLI session. Drops down into a 4-tab popover (Projects / Servers / Skills / Settings). Currently injects only `/start-mission` (the rest of the mission lifecycle is user-typed because of unresolved focus-targeting bugs in keystroke injection). Houston is the packaged, productized successor to Aaron's local Next.js Mission Control dashboard at `~/Apps/mission-control` — intended for paid distribution.

## Status
Houston's UI is now a 4-tab popover (Projects / Servers / Skills / Settings) with a full Settings store: terminal emulator, projects folder, and tab-vs-window spawn mode are all user-configurable via onboarding and the Settings tab. Log/End mission buttons were removed because the Ghostty focus-race made them unreliable; replaced with a Start dev / Open in browser hover action, and Start mission now keystrokes `/rename` so the spawned tab is titled with the project name. Next: resolve Terminal.app's macOS Sequoia tab-creation limitation (currently falls back to a new window) — workaround is setting macOS's "Prefer tabs when opening documents" to Always, or switching to iTerm2.

## Stack
- Electron 42 (main process: Node, renderer: Chromium)
- Next.js 16.2.6 (App Router, `output: 'export'` for static bundle into Electron)
- React 19
- Tailwind 4 (`@import "tailwindcss"` in globals.css)
- TypeScript
- `osascript` / AppleScript for terminal control (Terminal.app via tty-precise injection for legacy injectCommand; iTerm2 via tty-precise; Ghostty via System Events keystrokes — for Start mission's post-spawn `/rename` and `/start-mission` only)
- `tmux send-keys` for tmux pane injection (unwired now that mission chains are gone)
- Native Electron `dialog.showOpenDialog` for folder picker

## Key Locations
- **App**: `~/Apps/houston/`
- **GitHub**: not yet on GitHub — `git remote -v` is empty
- **Dev server**: `npm run dev` → Next.js on `http://localhost:3401` + Electron popover (concurrently + wait-on)
- **electron-builder identity**: `appId: com.aaroncougle.houston`, `productName: Houston`
- **Tray icon**: `electron/icons/tray.png` (22×22 — needs @2x variant)
- **User settings**: `~/Library/Application Support/Houston/settings.json` — keys: `terminal`, `projectsDir`, `spawnMode`
- **Onboarding flag**: `~/Library/Application Support/Houston/onboarded.json` (existence-based)
- **Globally updated skills**:
  - `~/.claude/skills/start-mission/SKILL.md` — no longer starts Mission Control (Houston replaces that dashboard); just starts the project's dev server.
  - `~/.claude/skills/log-mission/SKILL.md` — closing line now directs the user to type `/clear` after; CLAUDE.md auto-load handles the "pick back up" step
  - `~/.claude/skills/end-mission/SKILL.md` — unchanged
- **Reference source**: `~/Apps/mission-control` (the original local Next.js dashboard Houston is replacing as a distributable product — still runs locally on Aaron's machine; not deleted)
- **Authoritative session data on disk**: `~/.claude/sessions/<pid>.json` per running claude (sessionId, cwd, startedAt, version, kind, entrypoint)

## Architecture Notes
- `electron/main.js` — entry. Creates the menubar Tray, a frameless BrowserWindow popover, IPC handlers, and calls `app.dock.hide()` for menubar-only mode (`LSUIElement: true` in build config for the packaged app). Tray right-click menu has "Reload", "Help → Show onboarding", "Quit Houston".
- `electron/preload.js` — `contextBridge.exposeInMainWorld('mc', ...)` exposes: `getDashboard`, `getActiveSessions`, `getProjectDetail`, `getSkillDetail`, `getActiveServers`, `killServer`, `completeOnboarding`, `openPath`, `openExternal`, `hide`, `clearServerCache`, `startDevServer`, `getSettings`, `setSettings`, `pickDirectory`, and `startMission(projectPath, terminal?, mode?)`. The `mc` global name is preserved despite the rename.
- `electron/settings.js` — reads/writes `<userData>/settings.json`. Validates `terminal ∈ ["Ghostty", "Terminal", "iTerm2"]`, `spawnMode ∈ ["tab", "window"]`. Expands `~` in `projectsDir`. Defaults: Ghostty / `~/Apps` / window.
- `electron/data.js` — `getDashboardData(projectsDir)` and `getProjects(projectsDir)` now take the projects directory as a parameter; `getDashboardData` returns `projectsDir` in its payload so the renderer can show it in the empty state. Project discovery iterates the chosen directory; project icons are auto-detected from a list of common paths and embedded as data URLs.
- `electron/dev-servers.js` — `getActiveServers(projectsDir)` lists every TCP listener in ports 3000–9999 via `lsof`, resolves cwd via `lsof -d cwd`, and labels the row with the project basename when cwd is under `projectsDir`.
- `electron/process-detect.js` — load-bearing detection module. Uses `ps -axo pid,ppid,lstart,command` for the snapshot. For each claude PID it reads `~/.claude/sessions/<pid>.json` for the cwd (definitive when present, else `lsof -a -p <pid> -d cwd -Fn` fallback). To pick the JSONL it prefers the **latest-mtime** JSONL in `~/.claude/projects/<encoded-cwd>/` whose mtime ≥ the claude PID's `startMs` — because Claude does NOT update the session file's `sessionId` after `/clear`, the file points at a stale JSONL post-clear, so trusting it gives stale token counts. Birth-time-to-process-start matching (±30s) is the last-resort fallback for older claude versions with no session file. Walks the process tree to identify the hosting terminal.
- **Context size math**: `contextSize = input_tokens + cache_read_input_tokens + cache_creation_input_tokens + output_tokens` from the latest assistant message. Output is included because those tokens become `cache_read_input_tokens` on the next turn.
- `electron/terminal/index.js` — adapter dispatch + `startMission` only. `startMission(projectPath, preferredTerminal, mode)`:
  1. Snapshots `~/.claude/sessions/*.json` before spawn
  2. Calls `adapter.spawnSession(projectPath, "claude", mode)`
  3. Polls up to 30s for a new sessions file whose `cwd` matches `projectPath`
  4. Sleeps 1500ms for the TUI to draw
  5. Keystrokes `/rename <sanitized-projectName>` + Enter (sets the terminal tab/window title since Claude's `/rename` updates the OSC title)
  6. Sleeps 800ms
  7. Keystrokes `/start-mission` + Enter
  `logMission` / `endMission` / `waitForAssistantText` have been removed.
- `electron/terminal/<adapter>.js`:
  - `terminal-app.js spawnSession(path, cmd, "window"|"tab")` — window: `do script "cd … && cmd"`. tab: activate + System Events Cmd+T + `do script "cd … && cmd" in selected tab of front window`. **macOS Sequoia limitation**: Terminal.app's tab APIs don't reliably create a tab inside the front window — `do script in front window` runs in the active tab; `make new tab` is unsupported; Cmd+T via key code 17 silently no-ops; the "New Tab" menu item creates a new window in this user's config. Workaround: set macOS's "Prefer tabs" preference to Always so the new window auto-merges as a tab.
  - `iterm2.js spawnSession(path, cmd, "window"|"tab")` — window: `create window with default profile`. tab: `tell current window to create tab with default profile` (falls back to new window if no windows). Both write text to the resulting session.
  - `ghostty.js spawnSession(path, cmd, "window"|"tab")` — window: `execFile("open", ["-na", "Ghostty.app", "--args", "--working-directory=<path>", "-e", command])`. tab: AppleScript `application "Ghostty" is running` check (pgrep can't see Ghostty's process); if running, activate + 300ms + Cmd+T + 600ms + keystroke `cd "<path>" && claude` via System Events. Falls back to new window if Ghostty isn't already running.
  - `tmux.js`, `clipboard.js` — `injectCommand` paths intact but unused now; `spawnSession` for tmux is a no-op error.
- `app/page.tsx` — single client component. Polls `getActiveSessions()` every 2s, `getDashboard()` every 30s, `getActiveServers()` every 4s. Header reads logo on root pages with a sync icon (top-right) that re-fires all three in parallel. Four tabs: Projects / Servers / Skills / Settings.
  - **NavStack** (top of file): manual push/pop slide transitions between root / project-detail / skill-detail / update-detail views. Keeps the outgoing and incoming views mounted as absolute-positioned siblings during a 280ms `translateX` animation. Direction tracked in `navDirection` state, set by each push/pop handler. **Tab transitions are directional now**: `handleTabChange` diffs `TAB_ORDER` index and sets `navDirection` accordingly — rightward (e.g., Projects → Servers) slides forward; leftward (Settings → Projects) slides back. `viewKey = "tab:<tab>"` so each tab gets its own transition slot.
  - **ActiveSessionRow** shows project name + colored `pct%` + "Xm ago" on top, "Context used: pct%" on the second line. On hover the row expands a single button: "Start dev" → "Starting…" → "Open in browser" depending on whether `serverUrlByCwd.get(cwd)` is populated.
  - **ProjectsTab** receives `serverUrlByCwd: Map<string, string>` from Home; uses it to drive the active-session row's dev/browser button. Also receives `projectsDir` for the empty-state message + `onPickProjectsDir` callback that opens the native picker and refreshes the dashboard.
  - **ProjectDetailView** shows BigStats (Context used % + tokens per turn) when active, then the SmallStat row (Sessions / Last logged / Since), then a 44px tall black "Start mission" button when no session is active. When the active session's context ≥ `WARN_PCT` (25%), a centered banner appears between the BigStats and SmallStats: *"Recommend running /log-mission to prevent using ~Nk tokens in your next prompt."* — colored via `ctxColor(pct)`.
  - **ServersTab** has two sections: Dev (with empty state "No active dev servers") and MCP. Hover-revealed row actions on a dev server: Open in browser / Clear cache / Stop.
  - **SettingsView** lives at `tab === "settings"`, no longer pushed as a detail view. Three sections: Terminal emulator, Open new sessions in (Tab / New window), Projects folder. Selections persist immediately via `setSettings`.
  - **RowActionButton** is the unified hover-action button (3 variants: primary / secondary / destructive). **PrimaryButton** is the unified detail-view CTA. Both use `rounded-[8px]`, `font-semibold`, `letterSpacing: -0.01em`, opacity-0.85 hover.
- `app/onboarding/page.tsx` — 7-step flow: Welcome → Terminal picker → Projects folder picker → Projects intro → Mission lifecycle (3 slash commands explained) → Other tabs → "You're all set". Two interactive steps gate Continue until a selection is made; existing settings hydrate on revisit so users can re-enter via tray's Help menu without losing state.
- `app/layout.tsx` — `metadata.title: "Houston"`.
- `next.config.ts` — `output: 'export'`. Electron loads `out/index.html` in production; `http://localhost:3401` in dev.
- `package.json` — `name: "houston"`, `build.appId: "com.aaroncougle.houston"`, `build.productName: "Houston"`. `LSUIElement: true` for menubar-only mode.

## Recent Changes (this session)
- **Removed `/log-mission` and `/end-mission` from Houston UI + IPC + main process**. Active-session row hover collapses to a single dev/browser button. Project detail view shows Start mission only when no active session. `mission:log` / `mission:end` handlers, preload methods, and the `logMission` / `endMission` / `waitForAssistantText` functions in `terminal/index.js` are gone.
- **Added Start dev / Open in browser hover action**. Per-PID `starting` state; auto-clears when `devServerUrl` appears; 30s safety timeout. Backed by `dev:start` IPC running `npm run dev` detached via `zsh -lc` with logs to `/tmp/<project>-dev.log`.
- **Added per-server Clear cache button** that deletes `.next/cache`, `node_modules/.vite`, `node_modules/.cache`, `.turbo` relative to the server's cwd. Guarded by absolute-path + segment-depth checks.
- **Restructured tabs**: MCP merged into Servers as a second section under "Dev". Replaced the MCP tab with a **Settings tab** (no longer a push-detail view).
- **New Settings module + store**: `electron/settings.js` persists `terminal`, `projectsDir`, `spawnMode` to userData. `mission:start` reads them when no explicit override is passed.
- **New IPC**: `settings:get`, `settings:set`, `dialog:pickDirectory`, `dev:start`, `servers:clearCache`.
- **Onboarding got two new interactive steps**: terminal-emulator picker (3-card grid) and projects-folder picker (uses `dialog.showOpenDialog`). Continue gated on selection; choices hydrate from settings on revisit.
- **Spawn mode**: Tab / New window option in Settings; sub-labels are dynamic per chosen terminal. Each adapter's `spawnSession` now takes a `mode` argument.
  - iTerm2 tab mode works (`create tab with default profile`).
  - Ghostty tab mode works (AppleScript-detected + Cmd+T keystroke).
  - Terminal.app tab mode currently spawns a new window due to macOS Sequoia tab behavior; documented under Known Issues.
- **`/rename` is now keystroked between TUI-ready and `/start-mission`**, so the terminal tab title takes on the project name (Claude Code's `/rename` updates the OSC title).
- **Design tightening pass**: row titles `font-bold` → `font-semibold`; all action buttons `rounded-[8px]` (no more destructive pill); standardized spacing to mb-6 / pb-6; outer popover radius 14 → 12; IconButton ghost style; Empty state restyled as dashed-bordered centered panel; BigStat outlined card; "this app" badge harmonized; pointer cursor on all buttons via globals.css.
- **Directional tab transitions** added (`handleTabChange` diffs `TAB_ORDER` index).
- **Context warning banner** added under BigStats when `contextPct >= WARN_PCT`.
- **All Projects empty state** now reads "No projects found in `<displayPath>`" + a Choose-folder button affordance.
- Start mission button moved below the SmallStat row in the project detail view; black bg / white text, 44px tall.
- Updated `~/.claude/skills/log-mission/SKILL.md` step 7 to direct the user to type `/clear` after (CLAUDE.md auto-loads on `/clear`, so the briefing happens for free).
- Removed dead components: `StartButton`, `SecondaryButton`, `ActionIconButton`, `TrashIcon`, `StopIcon`, `SpinnerIcon`, `SettingsIcon`, `MCPTab`.

## What's Next
- **Resolve Terminal.app tab-mode** under macOS Sequoia. Two paths: (a) document in Settings sub-label that Terminal.app users need to set macOS's "Prefer tabs when opening documents" to "Always"; (b) point users at iTerm2 for actual tab support.
- **Push Houston to GitHub.** Audit earlier confirmed no remote configured. The pre-flight scan is clean (no secrets in tracked or untracked files; `.gitignore` covers `.env*`, `.pem`, `node_modules`, `.next`, `out`, `.vercel`). Approved commit message: *Build out Houston menubar: Electron shell, session detection, three-tab popover*. Approved target: `Cougler/houston` (private).
- **GitHub workflow integration**: extend `/handoff` and `/log-mission` skills with "report → ask → act" git steps (pull at start, status + optional commit/push at end). Discussed in this session but not implemented.
- **Restart-friction in dev**: `concurrently -k` doesn't reload Electron when `electron/*.js` changes. Consider a `nodemon`-style watcher to auto-restart on main-process edits.
- Carried over: `tray@2x.png` (44×44), `icon.icns`, Swift helper for Ghostty AX targeting (would unblock proper tab-targeting + potentially revive Log/End if focus race is solved), and an end-to-end DMG build test.

## Known Issues / Gotchas
- **Terminal.app "Tab" spawn mode opens a new window** under macOS Sequoia. AppleScript dead-ends explored: `do script "..." in front window` runs in the active tab; `make new tab` is unsupported; the "New Tab" menu item creates a new window; synthesized Cmd+T (`key code 17 using {command down}`) silently no-ops despite Terminal being the verified frontmost app. Workaround documented above.
- **Ghostty "Tab" mode is focus-sensitive**. `tell application "Ghostty" to activate` brings Ghostty's most-recently-focused window forward; Cmd+T creates the new tab there. If the user has the wrong Ghostty window selected at activation, the tab lands in that window (the session itself is correct because the subsequent `cd && claude` types into the new tab).
- **Residual focus race for the post-spawn `/rename` and `/start-mission` keystrokes**. Same shape as before but lower-impact now — the only effect is which Ghostty window hosts the session, not which session receives the keystroke (Terminal/iTerm2 spawns are unambiguous since `do script` targets the just-spawned tab/window precisely).
- **Settings tab shows "Loading…" if Electron hasn't picked up the new IPC handlers** — happens whenever `electron/*.js` changes hot-reload skips. Manual fix: Ctrl+C and rerun `npm run dev`. The `SettingsView` shows an explicit error message if the handler is missing.
- **30s timeout on session-file readiness** for Start mission.
- **Port 3401 is hardcoded** for dev. Change in both `package.json` scripts and `electron/main.js` `DEV_URL`.
- **First-run permissions**: Electron.app (dev) or packaged Houston.app needs Accessibility (System Events keystrokes for `/rename` + `/start-mission`) + Automation (controlling Terminal/iTerm/Ghostty for spawnSession) grants.
- **`concurrently` doesn't auto-restart Electron** on `electron/*.js` edits. Manually: Ctrl+C and rerun `npm run dev`. Next.js side hot-reloads fine.
- **electron-builder DMG build untested.** Configured in `package.json` build block but never run end-to-end.
- **Process detection is read-only** — the app never modifies `~/.claude/projects/` JSONLs or `~/.claude/sessions/*.json`.
- **Session JSON files are not always present.** Only recent claude versions emit `~/.claude/sessions/<pid>.json`. Code falls back to birth-time correlation when missing.
- **No projection of in-flight tokens.** If the user has just typed a message but Claude hasn't responded yet, that message isn't in the JSONL usage block. The reading will catch up after the next assistant turn.
