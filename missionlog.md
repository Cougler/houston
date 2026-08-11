# Houston — Mission Log

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
