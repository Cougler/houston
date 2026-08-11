# Houston — Claude Handoff

> Last updated: 2026-08-11

## What This Is
Houston is a native macOS app for running CLI coding agents. A sidebar lists
your projects, servers, and running agents; selecting a project opens a real
terminal in that directory, hosted inside Houston. A menubar item toggles the
window.

Swift / SwiftUI + AppKit, single SwiftPM executable. **~2,700 lines** — it was
~6,200 until the Electron-era popover UI, onboarding flow, and AppleScript spawn
path were deleted; see *History* below so nobody re-adds them.

## Stack
- Swift 6 / SwiftUI, macOS 14+
- SwiftPM `.executableTarget` (`Package.swift`), single target `Houston`
- **`libghostty-spm`** (MIT, macOS 13+) — prebuilt libghostty XCFramework, **no
  Zig toolchain**. Pins the upstream Ghostty commit in its own `Ghostty.ref`, so
  a package bump can't silently change the Ghostty build.
- Bundle resources at `Sources/Houston/Resources/icons`

## Key Locations
- **Project**: `~/Apps/houston/`
- **Run**: `cd ~/Apps/houston && swift run`. Restart cleanly:
  `pkill -f '.build/debug/Houston'; swift build && nohup .build/debug/Houston > /tmp/houston.log 2>&1 &`
- **Dev hook**: `HOUSTON_TEST_PANE=<path>` preselects a project at launch, so the
  pane path can be exercised without driving the sidebar by hand.

## Layout
```
main.swift → AppDelegate (menubar item) → MainWindowController → MainWindowView
                                                                  ├── sidebar (SidebarTable)
                                                                  └── detail
                                                                       ├── topPanel
                                                                       ├── TerminalHostView
                                                                       └── bottomPanel
```

- `main.swift` — `.regular` activation policy + `MainMenu.install`.
- `MainMenu.swift` — a SwiftPM executable gets **no main menu for free**, and
  without an Edit menu ⌘C/⌘V are never dispatched, so copy/paste inside the
  terminal silently does nothing. Not boilerplate; don't delete.
- `AppDelegate.swift` — menubar status item only. Left click opens the window,
  right click gives Open/Quit.
- `MainWindowController.swift` — one window: `.fullSizeContentView`,
  `titlebarAppearsTransparent`, `titleVisibility = .hidden`.
- `MainWindowView.swift` — `HStack` + owned `splitDivider`; sidebar left, detail right. Detail is
  top panel → terminal → bottom status strip.
- `SidebarTable.swift` — `NSTableView` wrapped in `NSViewRepresentable` with
  SwiftUI rows in `NSHostingView`.
- `TerminalSessionManager` / `TerminalPaneView` — panes and the libghostty
  surfaces. A project owns a *list* of panes arranged in an `NSSplitView`
  tree (`roots[path]`): ⌘D / ⇧⌘D wrap the focused pane's view in a new
  split, ⇧⌘W unwraps. The tree is frames + autoresizing (no constraints),
  so re-parenting on selection change stays a no-op for the PTYs. Split
  commands resolve their target via first responder; right-click focuses
  the clicked pane first (`HoustonTerminalView`), which is what makes the
  terminal context menu act on the pane under the cursor. Ghostty's view
  never consults `NSView.menu` — the context menu needs that subclass.
- `ProcessDetect` / `AgentDetect` / `DevServerDetect` — everything Houston knows
  about the machine. All three sit on `ProcScan`, the one implementation of the
  `ps` snapshot, pid→cwd lookup, and parent-chain walk.

## Gotchas — all of these were bugs, not theory

- **`contextWindow(for:)` defaults to 1M.** The `[1m]` suffix is not persisted
  anywhere on disk — only the bare model id (`claude-opus-5`). Detection is an
  allowlist of the *small*-window models (`smallWindowPatterns`: Haiku, Opus
  ≤4.5, Sonnet ≤4.5) with 1M as the fallback, so a new model reads correctly
  with no code change. The inverse — allowlisting 1M models — is what broke
  Opus 5 and pinned its bar at 100%.
- **`Theme.Context.color(for:)` takes a fraction (0–1), not a percentage.**
- **Spawned panes MUST get a scrubbed environment.** If Houston is launched from
  a shell already inside a claude session, panes inherit
  `CLAUDE_CODE_CHILD_SESSION`, treat themselves as sub-sessions, and **silently
  disable transcript saving** — no session file, no JSONL, so Houston goes blind
  to its own pane. `env_vars` can only add, not unset, so `TerminalEnvironment`
  overrides the markers to empty strings.
- **Closing a pane needs `view.controller = nil`, not just dropping refs.**
  `TerminalController` retains every surface's callback bridge, so releasing the
  pane leaves the surface unfreed and **the shell still running** (measured).
- **`TerminalHostView` must mount into `TerminalSessionManager.paneContainer`,
  never a container built in `makeNSView`.** SwiftUI recreates representables
  freely; a per-render container detached and reattached the terminal view
  constantly, and a reattach with a torn-down surface makes libghostty build a
  *new* one — i.e. orphaned shells.
- **Agent detection must NOT rely on the `HOUSTON_PANE` env tag.** Panes spawn
  through setuid `login`, and macOS then reports *no* environment for the
  resulting process. Walk pids instead (`AgentDetect`, `isDescendantOfSelf`).
- **Selection is `SidebarSelection`, an enum — never a bare `String`.** A server
  row's id is also a `String`; with a `String?` selection, clicking a server set
  the selection to `"<pid>:<port>"` and Houston opened a shell in a directory of
  that name. `pane(for:)` also refuses non-directories as a backstop.
- **One layer draws each highlight.** Selection *and* hover are both drawn by
  `RowChrome`; `table.selectionHighlightStyle = .none`. Every highlight bug in
  this sidebar (three separate times) was two layers drawing the same thing with
  different geometry.
- **Sidebar shows only sessions Houston hosts** (`ActiveSession.isHoustonOwned`,
  decided by walking the parent chain — the tree is `Houston → login → bash →
  claude`, so the immediate parent isn't enough). Houston can *observe* any
  session but can only *display* ones whose pty it owns.
- **"Active" means an agent process is running**, not that a session file
  exists — instant, and works for agents that write no session file. Only Claude
  Code publishes usage on disk, so context % is Claude-only by design.
- **Layout: three traps that all look like "the UI collapsed into a band".**
  (1) `HSplitView` is NSSplitView-backed and sizes to a *fitting* height instead
  of filling its parent — use a plain `HStack` with the hand-drawn
  `splitDivider`. (2) `NSViewRepresentable` has **no intrinsic content size**, so
  `SidebarTable` and `TerminalHostView` each need
  `.frame(maxWidth: .infinity, maxHeight: .infinity)`; `List` was greedy on its
  own, an NSView is not. (3) The root goes in via `contentViewController`
  (`NSHostingController`), not a bare `contentView` — an NSHostingView assigned
  directly doesn't track the window's size.
- **The sidebar must never call `reloadData()` on the poll.** It discards and
  rebuilds every row view, and the entry list changes on every 2s tick *and*
  every click (a project moves Projects → Shells the moment its pane opens) —
  that was the visible flicker. `SidebarTable.apply(_:)` diffs entries with
  `inferringMoves()` — a section jump MUST be a `moveRow`, not remove+insert,
  or the row view (and its hosted SwiftUI content) is torn down mid-jump and
  flashes — and `contentKey` gates re-hosting so a row is only rebuilt when its
  own content actually differs. Three supporting rules, each a measured bug:
  structural updates run with `isSyncing` set (removing the selected row fires
  `selectionDidChange`, which otherwise writes nil into the SwiftUI binding
  mid-update); hover is re-derived from the pointer after rows shift (it's
  tracked by row index, and the old index names whatever row slid into it);
  and NSTableView applies batched calls *serially*, so removals go high-to-low
  against old offsets, inserts/moves low-to-high against new ones, with the
  move source located via a live mirror of the row order.
- **Detector scans never run on the main thread.** They shell out to
  `ps`/`lsof` and block on `waitUntilExit`; `AgentDetect.snapshot` used to run
  straight from the 2s timer and stalled the UI for the length of both. All
  three stores now run scans in `Task.detached` with a single-flight guard so
  a slow pass can't stack onto the next tick.
- **`readUsage` reads the transcript's tail (256KB), not the whole file.**
  Transcripts grow to tens of MB and are re-read every 2s; usage lives in the
  last assistant message. It falls back to a full read only when the tail's
  lines carry no usage at all (e.g. a giant trailing tool result).
- **The terminal claims focus on a pane's first display only**
  (`TerminalPane.hasAutoFocused`). Re-grabbing it on every selection yanked
  focus out of the sidebar the instant you clicked a row, so arrow-key
  navigation never worked.
- **Theming: every chrome color is a dynamic token in `Theme.swift`**
  (`Color(light:dark:)` over `NSColor(name:dynamicProvider:)`), so the
  System/Light/Dark setting restyles everything live — never hard-code a hex
  in a view. Light values are the Figma design (file `DiTvczoWOd98QMG3o9AnMF`,
  node 326:73); dark is the same design on #1E1E1E. The terminal's colors come
  from a `TerminalTheme` (design-matched by default, or any
  `GhosttyThemeCatalog` theme via the footer gear); font/cursor/padding ride
  in the base `TerminalConfiguration` so they hold across themes, and
  `controller.setTheme` restyles running shells. The ghostty surface tracks
  the appearance itself — no manual color-scheme plumbing.
- **Sessions die with Houston.** Accepted tradeoff — same as sessions dying with
  Ghostty today. To make them survive, launch `tmux new-session -A -s
  houston-<project>` instead of the bare shell; that's the whole change.
- **Not a git repo.** No `.git`, so `/push` won't work until it's initialised.

## History — deliberately removed, don't re-add
Houston began as a port of an Electron menubar app. Deleted 2026-08-11 (~3,200
lines):

- **Menubar popover UI** (ContentView + Projects/Servers/Skills/Settings tabs +
  ProjectDetailView) — duplicated the desktop window over the same data.
- **Onboarding flow** (~1,270 lines) — walked users through the Accessibility
  permission that embedded terminals made unnecessary.
- **AppleScript spawn path** (TerminalAdapter, AppleScript, Permissions,
  MissionLauncher) — drove Ghostty by *synthesising System Events keystrokes*
  and polled `~/.claude/sessions/` for 30s hoping to find what it spawned.
  Owning the pty replaced all of it; `/start-mission` is now a pty write.
- Settings shrank to `projectsDir`; the Electron-era keys have no consumer.

## What's Next
- Verify keyboard nav (arrows, type-ahead) in the sidebar — the reason for the
  `NSTableView` wrapper, not yet confirmed by hand.
- Terminal focus after switching panes is unverified.
- The replicated design (2026-08-11) has no context-% UI and no bottom status
  strip; `ContextBar` + `formatTokens` (Components.swift) and `Theme.Context`
  are kept but unreferenced, awaiting the design for that surface. The session
  data pipeline (`ProcessDetect` → `ActiveSessionStore`) still runs and is
  still used for selection pruning.
- The header's Skills button opens `~/.claude/skills` in Finder as a
  placeholder — the design doesn't define its behaviour.
