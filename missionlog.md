# Houston — Mission Log

---

## 2026-08-12 — Native Claude status bar, terminal tabs, MCP controls, solar-system empty state

Houston now has a native status bar for Claude sessions — model picker (drives `/model`), context bar with the model's true window size, account rate-limit meters, and an MCP menu with health dots and one-click OAuth — all fed by a statusline script that also blanks Claude's in-terminal bar (with consent and a restorable backup). Projects grew nested terminal tabs in the sidebar, Add Folder now distinguishes projects from folders-of-projects, and the empty state is an animated solar system. Next: live with the status bar and MCP auth day-to-day and see what breaks.

**Done this session:**
- Status bar pipeline: `StatusLineFeed` swaps the user's statusLine for a script that dumps the JSON payload per pane (`HOUSTON_PANE`-keyed) and prints nothing; consent alert, backup + gear-menu restore, `StatusLineStore` poll, `StatusBarView`
- Status bar UI: model dropdown (types `/model` into the exact pane), context bar, per-limit meters (Session / All models / per-model), lines ±, cost
- MCP: `MCPStatusStore` shells `claude mcp list` (off-main, cached, 45s timeout); menu shows per-server health, ⚠ rows run `claude mcp login` (browser OAuth), ✓ rows tuck Log Out behind a submenu, ✗ rows open `/mcp`
- Fixed the play button never launching agents: `sendText` is a bracketed paste, so a pasted trailing `\n` sat highlighted in zsh — trailing newlines now go through the `text:\r` binding action
- Fixed the statusline command dying silently: `Application Support` needs single-quoting through `sh -c`
- Nested terminal tabs: `TerminalTab` model, `.shell` selection case, "name · N" rows, per-tab claude badges attributed via the feed, header ✕ / ⇧⌘W / context-menu close semantics
- Sidebar: Terminals→Active and Folders→Projects renames, smart Add Folder (project → pinned row, folder → group), `shippingbox` glyphs on project rows, folder chevron at far right, tightened padding, + menu (shell here / home), empty-section affordances (New Terminal, Open Folder…)
- Empty state: solar system (8 planets, real order/colors, slow individual periods, ringed Saturn), 36-star twinkling field, comet fly-through every 12–24s; title bar hidden when nothing is selected
- Fixed removing the last sidebar folder resurrecting `~/Apps` (empty projectsDirs read as unset) and the Active header's stale + menu (selection missing from contentKey)

**Up next:**
- Use the status bar in anger: model switching, MCP login/logout, meters against real limits
- Consider worktree-per-tab for parallel agents on one repo (the real value behind "remote repo" features)
- Sidebar keyboard nav (arrows, type-ahead) — still never hand-verified

**Handoff:**
- The user's global Claude statusline is now Houston's feed script — other terminals show a blank status row by design; the original is backed up at `~/Library/Application Support/Houston/statusline-backup.json` and restorable from the sidebar gear menu.
- Already-running claude sessions keep their cached statusline command until their next real interaction — a freshly enabled feed won't take over an idle session.
- Hand-unverified: MCP Authenticate/Log Out buttons (parser was verified against real `claude mcp list` output; the actions themselves weren't clicked), model-menu sends, and nested-tab edge cases. The per-model (Fable) meter only appears if the payload carries such a key — unconfirmed on this account.
- The Houston debug binary was left running deliberately (user was testing); no web dev server belongs to this project.

---

## 2026-08-11 — Figma redesign, git panel, splits, harness icons; repo on GitHub

Houston now matches the Figma design in light and dark, with split panes, a skills panel, a three-stage git panel (uncommitted → committed → synced, with commit detail and file diffs), collapsible multi-folder projects, and a Terminals sidebar whose rows show a git-status dot on the left and the running harness's real logo on the right. The repo is live at Cougler/houston with the Electron history preserved under the Swift rewrite — but everything after that initial push is still uncommitted. Next: push the day's UI work and eyeball the new light-mode logo variants and git dots.

**Done this session:**
- Cleanup/efficiency pass: shared `ProcScan` for ps/lsof, transcript tail-reads, off-main agent scans, dead code removed
- Sidebar flicker fixed twice over: `inferringMoves()` row diffing + synchronous pane creation in `select(_:)` + terminal boot fade-in
- Replicated the Figma design (node 326:73), then made every token adaptive light/dark with a System/Light/Dark setting and ghostty terminal theme picker (footer gear)
- Split panes as NSSplitView trees (⌘D/⇧⌘D/⇧⌘W, terminal right-click menu)
- Skills panel (agent-gated, types `/skill ` into the pane) and empty state with helmet watermark + recent-project quick-open
- Git panel: three-stage pipeline view, commit detail page, uncommitted file diff page, open-in-editor (VS Code), per-row status dots in the sidebar
- Harness dropdown detects installed CLIs and offers consented install commands; Pi added
- Sidebar restructure: Terminals section (merged Active/Shells), Folders with open/closed folder icons, server-rack icons, real harness logos with light/dark variants
- `.mc.json` gitignored and untracked across 18 repos; houston `git init` grafted onto the old Electron repo (`Cougler/houston`) and pushed

**Up next:**
- `/push` the day's work — everything after commit `e13a4a4` is uncommitted
- Visually check the new light-mode logo variants and per-row git dots
- Verify sidebar keyboard nav (arrows, type-ahead) by hand — still never confirmed

**Handoff:**
- The Houston debug binary was left running deliberately (user was actively testing); no web dev server belongs to this project.
- Agent logo assets live in `Resources/icons` as `<Name>.png` + optional `<Name> - light/dark.png`; the convention is enforced by `AgentIconCache`. The old 525px `OpenCode.png` is stale but harmless.
- Grok (`@vibe-kit/grok-cli`) and Pi (`@mariozechner/pi`) install commands are community package names the user hasn't verified — they run only after a confirm dialog that shows the command.
- `/Users/aaroncougle` (whole home dir) is in `projectsDirs` — possibly an accident from accessibility-driven test clicks; remove via right-click → Remove from Sidebar if unwanted.
- Everything visual was verified by screenshot; interaction testing was done via AXPress, which cannot hover — hover styling and keyboard nav remain hand-unverified.

---

## 2026-08-11 — Embedded terminals via libghostty; Houston becomes a desktop app

Houston is now a native desktop app that hosts its own terminals: a sidebar lists projects, open shells, running agents and dev servers, and selecting a project opens a real shell in that directory via libghostty. The Electron-era popover UI, onboarding flow, and AppleScript spawn path are gone, taking the codebase from ~6,200 to ~2,700 lines. Next is hands-on verification — sidebar keyboard navigation and whether the flicker fix holds in real use.

**Done this session:**
- Fixed context %: `contextWindow(for:)` now defaults to the 1M window with an allowlist of *small*-window models, instead of allowlisting 1M models. Opus 5 fell through the old list to 200k, so mlx-serve read 100% instead of 59%.
- Renamed `~/Apps/houston-swift` → `~/Apps/houston` (the Electron directory was deleted); wiped `.build` because the old absolute path was baked into its PCH module cache.
- Researched libghostty and Supacode; spiked `libghostty-spm` (MIT, macOS 13+, prebuilt XCFramework, no Zig) and proved a real PTY running `claude` in ~70 lines.
- Embedded terminals: `TerminalSessionManager`, `TerminalPaneView`, `TerminalEnvironment`. Panes run the user's shell; `startClaude(in:)` is explicit.
- Houston became a `.regular` desktop app: main window, `MainMenu` (⌘C/⌘V need an Edit menu), menubar item reduced to a window toggle.
- Sidebar sections Active / Shells / Servers / Projects, agent detection (`AgentDetect`, `CodingAgent`) with badges, and `ServerDetailView`.
- Took over the whole UI: custom window chrome (`fullSizeContentView`, hidden title), `HStack` + owned split divider, and an `NSTableView`-backed `SidebarTable` keeping keyboard nav and accessibility.
- Deleted ~3,600 lines: popover UI, onboarding, AppleScript spawn path (`TerminalAdapter`/`AppleScript`/`Permissions`/`MissionLauncher`), plus dead helpers and 2MB of onboarding art.
- Fixed sidebar flicker (row diffing + `contentKey` gating instead of `reloadData()`) and a layout collapse introduced by removing `NavigationSplitView`.

**Up next:**
- Verify sidebar keyboard navigation (arrows, type-ahead) and that the flicker is actually gone in use — both need hands on the app.
- Confirm terminal focus behaves after switching panes.
- Consider tmux-backed panes if sessions surviving a Houston restart starts to matter.

**Handoff:**
- **Not a git repo** — none of this is under version control. `/push` won't work until `git init`. Worth doing before the next session; ~3,600 lines were deleted today with no way back.
- Everything visual this session was verified by screenshot, not by clicking — I can't drive the mouse or keyboard reliably. Synthetic mouse events never triggered `onHover` and twice produced misleading captures. Anything interaction-shaped is unconfirmed.
- `/Applications/Houston.app` is still the old **Electron** build. Delete or re-package it before treating a launched `Houston.app` as this code.
- The bugs worth not re-discovering are all in `CLAUDE.md` → *Gotchas*, each one measured rather than theorised: pane teardown needs `view.controller = nil`; panes need `CLAUDE_CODE_*` scrubbed or they silently stop writing transcripts; agent detection can't use env tags (setuid `login` hides them); and every sidebar highlight bug was two layers drawing the same thing.
- `HOUSTON_TEST_PANE=<path>` preselects a project at launch — the only way to exercise the pane path without clicking.

---

## 2026-06-23 — Context % fix, popover toggle fix, full-segment tabs, Electron retired

Houston (Swift) is now the sole Houston — the Electron build is abandoned (left on disk, no longer a reference). This session fixed three issues: the context % now computes against the correct 1M window for Opus 4.8 sessions, the menubar icon toggles reliably without the click-away dead state, and the entire tab segment is now clickable instead of just the label text. The app is running clean; next is carrying the header/progress-bar design into ProjectDetailView and a visual parity pass.

**Done this session:**
- Fixed dramatically-wrong context %: `ProcessDetect.contextWindow(for:)` now matches the Opus 4.7–4.9 family (`opus-4-[7-9]`) as 1M-window. Root cause: the transcript only records the bare model id `claude-opus-4-8` — the harness's `[1m]` suffix is never persisted in the JSONL or session file, so 1M sessions were falling back to the 200k default (150k read as ~75% instead of ~15%).
- Fixed the menubar popover toggle dead state: the local dismiss monitor now skips clicks on the status-item button (and the popover itself), so `togglePopover` is the sole handler. Previously both the monitor and the button action raced the same click, leaving an orphaned monitor that swallowed the next click until you clicked the desktop.
- Made the whole segmented-tab area clickable: added `.contentShape(Rectangle())` to `TabBarItem` so the padding around the label is hit-tested, not just the text glyphs.
- Retired Electron: updated the Swift `CLAUDE.md` "What This Is" to declare the Swift target the sole Houston and stop treating `~/Apps/houston` as the design source of truth. Did NOT delete the directory (user chose "leave it, just abandon").

**Up next:**
- Carry the header/progress-bar design into `Views/ProjectDetailView.swift` (likely still shows the old "Xk of XXXk tokens" + percentage pattern)
- Visual polish pass on the popover (logo vertical alignment, progress-bar fill animation)
- Servers / Skills / Settings tabs — design parity not yet done

---

## 2026-06-18 — Restructured the global mission skills (no app changes)

This session was spent on the global Claude Code mission skills (`~/.claude`), not the houston-swift app itself. The start/end-mission skills were split apart and two new git skills (`/pull`, `/push`) were created; the Swift app was rebuilt clean with no code changes. Next on the app side: relaunch the running binary and visually compare the popover against the Electron build.

**Done this session:**
- Rewrote `/start-mission`: dropped the git steps, added a "pick up where we left off" step (reads missionlog.md + CLAUDE.md + .mc.json), kept the dev-server start
- Created `/pull` skill: git/GitHub setup (init / `gh repo create`) + fetch/compare/`--ff-only` pull, diverged-stops-and-asks
- Created `/push` skill: commit (asks once, explicit staging) + push, surfaces divergence/conflicts before pushing
- Rewrote `/end-mission`: writes a missionlog.md entry in Houston's parse format + refreshes CLAUDE.md/.mc.json, kills dev servers; git removed
- Reconciled global `~/.claude/CLAUDE.md` End Mission to match (added missionlog step, replaced inline git commit/push with a `/push` pointer)
- Rebuilt houston-swift (`swift build`) — clean, no Swift code changed

**Up next:**
- Relaunch the running Houston binary (PID 46993) to confirm nothing regressed
- Visually compare the Swift popover vs the Electron popover (logo alignment, progress-bar fill animation)
- Carry the header/progress-bar design into `ProjectDetailView`

---
