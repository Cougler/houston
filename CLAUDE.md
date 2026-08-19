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
- **Package**: `scripts/package.sh [version]` → `dist/Houston.dmg` — universal
  release build, resource bundle into `Contents/Resources`, icns from
  `AppIcon.png`, ad-hoc signed unless `SIGN_ID` is set. `dist/` is build
  output, never committed.

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
  surfaces. A project owns a list of `TerminalTab`s (`tabs[path]`): the
  first is its main terminal, extras appear as nested "name · N" sidebar
  rows (`SidebarSelection.shell`), each tab owning its own view tree.
  Within a tab, ⌘D / ⇧⌘D wrap the focused pane's view in an `NSSplitView`,
  ⇧⌘W unwraps (a tab's last pane closing closes the tab). Trees are frames
  + autoresizing (no constraints), so re-parenting on selection change
  stays a no-op for the PTYs. Split commands resolve their target via
  first responder, then the displayed tab (`activeTabID`); right-click
  focuses the clicked pane first (`HoustonTerminalView`), which is what
  makes the terminal context menu act on the pane under the cursor.
  Ghostty's view never consults `NSView.menu` — the context menu needs
  that subclass.
- `StatusLineFeed` / `StatusBarView` — the native status bar under the
  terminal (model menu → `/model`, context bar, rate-limit meters), fed by
  the statusline hook (see Gotchas). `MCPStatusStore` adds MCP health via
  `claude mcp list` plus one-click `login`/`logout`, all shelled off-main.
- `EmptyStateView` — the no-selection artwork: a slow solar system, star
  field, and occasional comet, all plain SwiftUI animation.
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
- **An empty `projectsDirs` must read back as empty.** Treating it as
  "unset → default `~/Apps`" meant removing the last sidebar folder silently
  resurrected it on the next settings read.
- **Anything a sidebar row's content reads must be in its `contentKey`.** The
  Active header's "+" menu reads the selection; with a title-only key the
  header never re-hosted and the menu kept the selection captured at launch
  (nil), so its per-project item never appeared.
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
- **`sendText` is a paste, not typing.** `ghostty_surface_text` delivers text
  as a bracketed paste, so zsh leaves a pasted trailing `\n` sitting
  highlighted in the line editor instead of executing it — `claude\n` just sat
  at the prompt. `TerminalPane.send` peels a trailing newline off and delivers
  it as the `text:\r` binding action, which writes the CR raw to the pty like
  a real Return keypress.
- **The Claude statusline command must be single-quoted.** Claude Code hands
  `statusLine.command` to `sh -c`, and Houston's feed script lives under
  `Application Support` — unquoted, the shell executed
  `/Users/…/Library/Application`, the status line silently blanked, and the
  feed never ran. `StatusLineFeed.statusLineCommand` wraps the path in quotes;
  the state check accepts both forms.
- **The status bar's data comes from Claude's own statusline hook, not
  transcripts.** `StatusLineFeed` (with user consent — it rewrites
  `~/.claude/settings.json`, backing the old value up for restore) installs a
  script that dumps the statusline JSON payload to
  `Application Support/Houston/statusline/<HOUSTON_PANE>.json` and prints
  nothing, which blanks the in-terminal status row *and* suppresses the hint
  badges. The payload carries the model's real context-window size (no
  `contextWindow(for:)` guessing), session cost, and account rate limits.
  Claude re-runs the hook on events (assistant message, /compact, permission
  mode change), **not** on a timer, and a *running* session keeps its cached
  command until its next real interaction — don't expect an installed feed to
  take over an idle session.
- **Assigning `contentViewController` resizes the window to the view's fitting
  size** — with `sizingOptions = []` that's ~1×1, an invisible window. The
  debug build masked it for months: its frame autosave restored a saved size
  over the collapse, and only the packaged app's fresh prefs domain exposed
  it. `MainWindowController` re-asserts the default size after assignment and
  refuses to restore a degenerate (<400×300) saved frame.
- **Server health probes must hit `localhost`, not `127.0.0.1`.** Node dev
  servers routinely bind only the IPv6 loopback (`::1`); probing the IPv4
  address alone reported a healthy server as down (red icon). The hostname
  resolves both families. Probes are HEAD requests at most every 30s per
  server — a per-tick `GET /` keeps a Next.js dev server permanently
  recompiling.
- **The mission skills ship in the app.** `Resources/skills/{start-mission,
  handoff,log-mission,end-mission}` are copied into `~/.claude/skills` at
  launch when missing (`HoustonSkills.installMissing`), never overwriting the
  user's copies. The header's Handoff is `HandoffCoordinator`: /log-mission →
  watch `missionlog.md`'s mtime → /clear → /handoff — orchestrated by Houston
  because a session cannot `/clear` itself.
- **Peak hours is wall-clock, not API data.** The statusline payload carries
  no peak-hours fields (checked against the docs); `PeakHoursPill` ports the
  user's old statusline script: peak = 9:00–18:00 local.
- **`SVGIcon` renders bundled SVGs as template images** (`NSImage` decodes SVG
  natively on macOS 11+), so `foregroundStyle` tints them like SF Symbols —
  used for the rocket; `servers.svg` was simple enough to draw as a `Shape`
  (`ServerGlyph`) instead.
- **Sessions die with Houston.** Accepted tradeoff — same as sessions dying with
  Ghostty today. To make them survive, launch `tmux new-session -A -s
  houston-<project>` instead of the bare shell; that's the whole change.
- **Repo: `Cougler/houston` (public).** The Electron app's history lives in
  the same repo — the Swift rewrite is grafted on top of it (`29de87b` is the
  last Electron commit), so the old code stays reachable without a separate
  archive repo.
- **Updates come from GitHub Releases.** `UpdateChecker` polls
  `releases/latest` (public API, no auth) and compares the tag against
  `CFBundleShortVersionString` — so releases MUST be tagged `vX.Y.Z` with the
  DMG attached: `scripts/package.sh X.Y.Z && gh release create vX.Y.Z
  dist/Houston.dmg`. Debug builds have no bundle version and never auto-check;
  the footer pill / rail badge appear only in the packaged app.
- **Updates install in place (1.0.4+).** `UpdateInstaller` downloads the
  release DMG, mounts it, and refuses anything that isn't Houston: intact
  `codesign --verify --deep --strict`, `TeamIdentifier=4CDVHNL984`, and a
  passing `spctl` assess (i.e. still notarized). The swap moves the old
  bundle aside first (running executables keep their inode) and rolls back on
  failure; `ditto`, not FileManager copy — a plain copy can break the seal.
  Relaunch is a detached `sh` child that waits for our pid to exit. Only a
  packaged app self-installs; dev builds and DMG-less releases fall back to
  the browser. Installing relaunches Houston, so every entry point confirms —
  sessions die with Houston.

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
- The bottom status strip exists now: `StatusBarView` under the terminal,
  fed by `StatusLineFeed`/`StatusLineStore` (see Gotchas), reusing
  `ContextBar` + `formatTokens` + `Theme.Context`. The transcript-based
  pipeline (`ProcessDetect` → `ActiveSessionStore`) still runs and is still
  used for selection pruning; the status bar does not use it.
- The header's Skills button opens `~/.claude/skills` in Finder as a
  placeholder — the design doesn't define its behaviour.
