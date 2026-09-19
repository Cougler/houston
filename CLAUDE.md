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
- `ChatArchive` / `ChatSessionHub` / `ChatAgentSession` / `ChatBrowserView` —
  the chat feature. `ChatArchive` parses both CLIs' session stores into
  transcripts (and transplants chats across harnesses via handoff brief +
  tail). Sends run through `ChatSessionHub`: ONE persistent agent process
  per open chat — Claude Code via its `--input-format stream-json
  --output-format stream-json` protocol (user messages on stdin; streaming
  deltas, `control_request` permissions, and interrupts verified against
  the live CLI), Codex via `codex app-server` JSON-RPC v2
  (`thread/start|resume`, `turn/start`, `item/*` notifications, approval
  server-requests; shapes from `codex app-server generate-json-schema`).
  Never rebuild this on one-shot `claude -p`/`codex exec` per message +
  transcript polling — that was tried and it pinwheeled: full CLI boot per
  send, whole-file re-parse every 1.2s, no permissions, no cancel. The
  transcript file is re-read exactly once per finished turn; the live turn
  renders from the stream (`LiveTurnView`, approval cards, Stop).
- **Chat lanes + warmth (2026-09-13).** Chat processes are WARM:
  `ChatSessionHub` keeps them alive under a 15-min TTL sweep (4 idle max,
  the on-screen chat exempt) and `prewarm` boots the CLI on chat *open*,
  so the first send skips cold start + `--resume` load — the reason chat
  used to feel slower than a terminal pane. Turn-end absorption is
  LEVEL-triggered (`ChatAgentSession.phase`: working / settling / idle,
  `hasUnabsorbedTurn`), never a bare `.onChange(of: completedTurns)` — an
  edge fired while the observer is unmounted is lost, and the reply
  didn't render until the user navigated away and back. Context rollover:
  past 80% of the window (Claude-only; codex publishes no usage) the chat
  seals into a capsule and continues in a fresh session seeded with an
  on-device handoff brief + verbatim tail + the sealed transcript's path
  (hidden in the UI by the handoff prefix-collapse, kept for the model);
  `.houstonChatRekeyed` retargets `chatTarget` so the sidebar follows.
  **Chats are FOREVER in the sidebar (2026-09-14)** — the ChatGPT mental
  model won; do not resurface "capsules" as user-facing objects. The
  engine work (warmth, rollover, chains) is invisible: a rollover chain
  presents as ONE chat (head listed, superseded segments hidden via
  `ChatMetaStore.continuations`, walked back per-click by "Show earlier
  conversation" with the seam deduped); the only things hidden from the
  list are negligible sessions (`ChatArchive.isNegligible` — husks and
  sub-1k single exchanges, dismissed by `CapsuleStore.autoDismissSweep`,
  reversible if the file grows back) and superseded segments. ✕ archives
  (never "seals"); any chat row drags into a composer as a context chip
  (transient `ChatCapsule.referenceText` — the capsule TYPE survives as
  plumbing for chips/markers, not as a shelf). Sidebar chat rows wear
  the phase (filled accent bubble while busy), driven by
  `ChatSessionHub.activityTick`; the busy flag rides in the row's
  `contentKey`.
- `ProviderAuth` — third-party cloud models (Grok/xAI, DeepSeek, Gemini)
  in the chat's model menu, riding codex's custom-provider rail exactly
  like MLX: `model_providers.<id>.*` overrides + `modelProvider` on the
  thread, API key delivered as an env var on the spawn (`env_key`), never
  written to config. Keys live 0600 in `Application Support/Houston/
  provider-keys.json`; sign-in opens the provider's key console in the
  browser and the key pastes back (Claude signs in via `claude /login`
  in a home terminal pane; OpenAI via `codex login`, which round-trips
  the browser itself). **codex only speaks `wire_api=responses`** —
  `"chat"` is a load-time error since 0.14x — so a provider needs an
  OpenAI-compat `/responses` endpoint: xAI has one (probed: 422 ≠ 404),
  Gemini does not (its models sit disabled behind `compatible: false`),
  DeepSeek is wired optimistically (catch-all 401, unprovable keyless).
  Both codex provider configs verified to load (initialize answers with
  a dummy key — the MLX config bug was a load-time error, so this
  catches typos). **Gemini's real path is the gemini CLI's ACP surface**
  (`gemini --acp`, installed via brew): JSON-RPC over stdio, handshake
  verified live — `authenticate {methodId: "oauth-personal"}` drives
  Google's browser OAuth and answers when the user finishes
  (`ProviderAuthStore.signInGemini`), creds cached by the CLI in
  `~/.gemini`. Sessions land at `~/.gemini/tmp/<dir>/chats/*.jsonl` as
  an op-log (`$set` patches with typed messages). The full `.gemini`
  chat harness (ACP session/prompt streaming) is NOT built yet — the
  assistant/tool stream shapes are only observable in an AUTHED session,
  and chat plumbing here is never built blind (see the stream-json
  lesson above).
- **Gemini chat harness — ACP driver (`ChatHarness.gemini`), 2026-09-14.**
  The third harness: `gemini --acp` over JSON-RPC/stdio, driven in
  `ChatAgentSession` alongside claude/codex. Handshake: `initialize` →
  `session/new` (or `session/load` on resume) → `session/prompt`;
  streamed via `session/update` notifications (`agent_message_chunk`
  content → text, `tool_call` → chips, `usage_update` → a REAL context
  meter, `used`/`size` — unlike codex which publishes none); permissions
  via the `session/request_permission` server-request (respond
  `{outcome:{outcome:"selected",optionId}}`); cancel via `session/cancel`.
  Model is pinned on the spawn (`-m <arg>`); a change respawns like
  claude. **All message shapes were extracted from the CLI's bundled zod
  schema** (`.../@google/gemini-cli/bundle/gemini-*.js`) — the
  authoritative source, so NOT built blind; the wire framing (initialize
  + session/new id-matching, the unauthed "API key missing" error path)
  was verified live. **Persistence is Houston-owned**, NOT Gemini's
  op-log: turns are written from the live stream to `Application Support/
  Houston/gemini-chats/<munged-cwd>/<acpSessionId>.jsonl` in a trivial
  one-message-per-line native format (`ChatArchive.geminiTranscript` /
  `appendGeminiTurn` / `exportToGemini`), parsed by verified code — so no
  unverifiable op-log parser. Login is Google OAuth through the ACP
  `authenticate` surface (`ProviderAuthStore.signInGemini`), NOT a
  terminal command (PromptDelivery.login special-cases it). **Not yet
  smoke-tested end-to-end** — a real streaming turn needs a signed-in
  Google account (shapes are schema-derived; the authed round trip is
  unrun here).
- **Grok chat harness — same ACP driver (`ChatHarness.grok`), 2026-09-14.**
  xAI open-sourced **Grok Build** (`xai-org/grok-build`, binary `grok`),
  an official coding agent that speaks ACP — so it rides the EXACT driver
  Gemini uses. The `.gemini`/`.grok` paths are unified: `ChatHarness.isACP`
  gates a shared `sendACP`/`ensureACPTransport`/`handleACP` in
  `ChatAgentSession` and a shared `acpChatsDir`/`acpTranscript`/
  `appendACPTurn`/`exportToACP` store (per-harness subdir under
  `Application Support/Houston/<harness>-chats/`). Only the spawn differs:
  Gemini `gemini --acp -m <model>`, Grok `grok --model <model> agent
  stdio` (global flags lead the subcommand). Install: `curl -fsSL
  https://x.ai/cli/install.sh | bash` → `~/.grok/bin/grok`. Grok Build
  owns its OWN sandbox + tool loop + auth (so none of the hand-rolled-
  harness guardrail concerns apply); login is browser OAuth via `grok
  login --oauth` in a terminal pane (`PromptDelivery.login` case),
  detected by `~/.grok/auth.json`. The `grok --model … agent stdio`
  spawn + ACP `initialize` handshake were verified live; a full streaming
  turn still needs a signed-in xAI account. **The lesson: standardizing
  the SECOND ACP agent (Grok) onto Gemini's driver was nearly free — new
  providers that speak ACP are a spawn command + a provider entry, not a
  new harness.** codex-rail providers (raw `model_providers.*` +
  Responses wire) stay for OpenAI-compatible key-only providers; codex
  itself still 422s xAI's Responses tools, which is why Grok goes through
  Grok Build's ACP agent, not the codex rail.
- **Pi chat harness — third ACP rider (`ChatHarness.pi`), 2026-09-16.**
  Pi (`@earendil-works/pi-coding-agent`, binary `pi`) is provider-AGNOSTIC
  — one harness, every provider it holds credentials for — driven through
  the `pi-acp` adapter (npm `pi-acp`, spawns `pi --mode rpc` underneath;
  pi itself doesn't speak ACP). Same shared driver as Gemini/Grok; the
  ONE structural difference: pi's model is NOT a spawn flag. It's set
  after session open via `session/set_config_option {configId:"model",
  value:"provider/model-id"}` (`session/set_model` is unregistered —
  probed), and `acpSessionReady` is deferred until that request answers
  so the first prompt can't race onto pi's default model. Verified live
  2026-09-16: initialize (protocol 1, loadSession true), session/new
  (auth = presence of a provider env key or pi's own `~/.pi` creds),
  set_config_option round trip, and the full model catalog dump. Model
  mapping lives in `ChatModelChoice.piModelIDs` — Houston model → pi
  catalog id, VERIFIED ids only (all Claude + all OpenAI models map;
  Gemini 2.5 yes, 3-pro-preview no; Houston's Grok/DeepSeek generation
  isn't in pi's catalog, so those show Pi grayed). The harness chip menu
  is now a real switch: `convert(_:to:)` hops a mapped model → Pi and a
  Pi chat back to its native CLI via `nativeEquivalent`. Auth: any keys
  in `ProviderAuthStore` ride the spawn env (never the "oauth" markers);
  "Set up Pi…" runs `pi`'s TUI in a terminal pane for the rest. A real
  authed streaming turn is still unrun here (no pi credentials on this
  machine) — stream shapes are the same session/update chunks the driver
  already handles, and pi-acp's bundle emits no `usage_update`, so no
  context meter (codex-style).
- **Inline chat threads (2026-09-19).** Ask about ONE paragraph of a reply
  without losing your place: hover a reply paragraph → "ask about this" →
  a thread panel in the right sheet (`RightPanel.chatThread`,
  `ChatThreadPanel.swift`). A thread turn is a normal turn into the SAME
  session prefixed `[Re: "<anchor>"] question` (`ChatThread.compose`) —
  the model sees the reference, the transcript keeps the exchange on disk
  (no sidecar), and the UI routes marker-prefixed exchanges into the
  panel: `ChatThread.strippingExchanges` filters them from the main flow
  (transcript, carried turns, live stream — `LiveTurnView.threadTurn`),
  `ChatThread.exchanges(in:anchor:)` collects one anchor's pairs, and
  reply-count chips ride the anchored paragraphs (`ThreadableBlock`).
  Anchors can be ANY selected text, not just whole paragraphs:
  right-click a reply paragraph → "Ask About Selected Text" (falls back
  to the whole paragraph when no selection captures — the item never
  dead-ends), or Edit ▸ Ask About Selection (⇧⌘A). The custom context
  menu REPLACES the system text menu, so it carries its own Copy. A
  drag-detection pill (NSEvent monitor) was tried first and REMOVED —
  gesture-sniffing selection was unreliable; don't re-add it. Capture is via
  `ChatThread.capturedSelection()` — a responder-chain copy: with the
  pasteboard deep-copied and restored around it, because SwiftUI's
  selectable Text exposes no selected-range API — validates the quote
  lives inside ONE assistant paragraph, and threads it. Chips hang off
  whichever paragraph CONTAINS each quote (`blockThreads`, containment
  over normalized text; several on one paragraph each lead with a
  sliver of their quote). Anchor key = the quote's first 90 chars,
  quotes flattened to singles so the marker's `"]` terminator parses
  unambiguously. Same
  hide-from-view-keep-for-model contract as the handoff prefix-collapse.
  One session = one turn at a time: a thread question mid-turn queues
  like any held message; the tangent stays in the model's context by
  design.
- `NotifyFeed` / `NotifyStore` — "needs you" notifications off Claude Code's
  `Notification` (permission request / idle waiting) and `Stop` (turn done)
  hooks. One script dumps each hook payload to
  `Application Support/Houston/notify/<HOUSTON_PANE>.….json`; the store polls,
  keeps per-pane attention, and drives the banner (packaged builds only —
  `UNUserNotificationCenter` needs a bundle), the menubar amber dot, and the
  sidebar row badge. An event for the pane the user is watching (its tab
  displayed, app active) is dropped. Unlike the statusline takeover this is a
  non-destructive *merge* into settings.json's `hooks` arrays — install
  appends Houston's entry, restore removes exactly it — but still gated on
  the same consent-dialog pattern (gear menu).
- `TrackedStore` / `EventFeed` — Reminders and the bell's notification feed.
  The bundled `/track` skill (ships like the mission skills) writes dated
  obligations to `Application Support/Houston/tracked.json`; `TrackedStore`
  polls it (mtime + day rollover) and its write-backs mutate the *raw* JSON
  dictionaries so fields only the skill knows survive the round trip.
  `EventFeed` is the in-memory session feed (needs-you, finished turns, due
  reminders, commits on the watched branch — HEAD moving on the *same*
  branch, so a branch switch isn't a "commit"). Git / Skills / Reminders /
  Notifications (and the server page, `ServerPanel`) share one full-height
  right sheet in `MainWindowView`: the
  sheet is ONE always-mounted overlay view sliding by offset, and pinning
  just animates a width reservation in the root HStack — re-parenting it
  between overlay and layout is what made pin/unpin jump. There is NO
  click-away scrim (2026-08-25, deliberate): sheets are swappable — clicking
  another opener (server row, Git button) swaps content in place, and
  sidebar project/shell rows select without dismissing. `closeFloatingSheet`
  fires from: header gaps, the empty-state sky, the sidebar's dead space
  (`onEmptyClick`, a click hitting no row), and clicks INTO the terminal
  (`.houstonTerminalClicked`, posted from `HoustonTerminalView.mouseDown`
  because ghostty consumes clicks before SwiftUI sees them). Selection
  changes alone never auto-dismiss; docked sheets ignore all of it.
- `StatusLineFeed` / `StatusBarView` — the native status bar under the
  terminal (model menu → `/model`, context bar, rate-limit meters), fed by
  the statusline hook (see Gotchas). `MCPStatusStore` adds MCP health via
  `claude mcp list` plus one-click `login`/`logout`, all shelled off-main.
- `EmptyStateView` — the no-selection artwork: a slow solar system, star
  field, and occasional comet, all plain SwiftUI animation.
- `ProcessDetect` / `AgentDetect` / `DevServerDetect` — everything Houston knows
  about the machine. All three sit on `ProcScan`, the one implementation of the
  `ps` snapshot, pid→cwd lookup, and parent-chain walk.
- `ShareProxy` / `MDNSAdvertiser` — shareable dev URLs (featureideas.md tiers
  1+2). A reverse proxy on port 80 (fallback 14080 — deliberately outside the
  3000–9999 scan range so Houston never lists itself as a dev server) routes
  `<project>.localhost` by Host header to the detected dev port, then
  byte-splices untouched after the first request's headers, so WebSockets/
  HMR/SSE work with zero protocol knowledge. `MDNSAdvertiser` registers
  `<project>.local` **A records** via `DNSServiceRegisterRecord` — hostname
  registration, which `NWListener`'s Bonjour support (services only) cannot
  do — so phones on the Wi-Fi reach the proxy, which forwards to loopback;
  the dev server never has to bind beyond localhost. UI is the Sharing
  section in `ServerPanel`, a right-sheet panel like Git — clicking a server
  row toggles `RightPanel.server(id)`, never the selection (server rows
  aren't selectable; the old full-page `ServerDetailView` and the interim
  popover are both gone). Toggle persists as
  `sharingDisabled`; unknown hosts get a listing page; tier 3 (public relay
  links) is only a Coming Soon slot there. Vite blocks non-localhost Host
  headers ("Blocked request"), so `TerminalEnvironment` sets
  `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.local` — Vite's official escape
  hatch — meaning Vite servers started from Houston panes accept `.local`
  names automatically; servers started elsewhere need
  `server.allowedHosts: ['.local']` in their own vite config.

## Gotchas — all of these were bugs, not theory

- **A refused backend connect surfaces as `.waiting`, not `.failed`.**
  Network.framework retries a refused localhost connection forever, so
  ShareProxy treats `.waiting` as down (server died since the lsof scan) and
  serves its offline page instead of hanging the request.

- **`contextWindow(for:)` defaults to 1M.** The `[1m]` suffix is not persisted
  anywhere on disk — only the bare model id (`claude-opus-5`). Detection is an
  allowlist of the *small*-window models (`smallWindowPatterns`: Haiku, Opus
  ≤4.5, Sonnet ≤4.5) with 1M as the fallback, so a new model reads correctly
  with no code change. The inverse — allowlisting 1M models — is what broke
  Opus 5 and pinned its bar at 100%.
- **`Theme.Context.color(for:)` takes a fraction (0–1), not a percentage.**
- **stream-json `result.usage` is CUMULATIVE across the turn's API calls** —
  a 3-call turn reported ~86k while the real context footprint was ~29k
  (measured). Never feed it to the chat context meter: the last *assistant*
  message's usage is the true occupancy. `result.modelUsage` does carry each
  model's exact `contextWindow`, which `ChatAgentSession` prefers over the
  `contextWindow(for:)` name-pattern guess.
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
- **Focus follows the sidebar selection into the terminal** (deliberate
  reversal, 2026-08-20): `select(_:)` calls `focusTerminal`, and
  `SidebarTable.onRowClick` re-fires it for a click on the already-selected
  row (no `selectionDidChange` then). Click a row → type immediately;
  arrow keys go to the shell, not sidebar navigation — that tradeoff is
  chosen, don't "fix" it back. Focus stays put if it's already in one of
  the tab's split panes.
- **`focusTerminal` must retry until the pane is mounted.** A first open
  mounts the pane on the *next* render pass, and one async hop isn't always
  enough — an in-flight animation (the onboarding dismissal springs) pushes
  the mount past it, and a single-shot `makeFirstResponder` silently drops
  focus: the terminal looks open but typing goes nowhere until the row is
  clicked again. `focusWhenMounted` retries (50ms × 10) until the view has
  a window and `makeFirstResponder` returns true.
- **Onboarding is a full-window takeover, and its dismissal is a
  choreographed handoff** (`OnboardingView`, `onboardingSeen`, replay from
  the footer gear). While it shows, `sidebarRevealed` keeps the sidebar at
  zero width and `EmptyStateView(skyLift: -56)` holds the empty state's sky
  at the welcome screen's lift, so the overlay's solar system and the one
  underneath are aligned; dismissal fades the overlay (0.25s), then one
  spring animates sidebar width + skyLift together — a single diagonal
  glide, no jump. Don't re-anchor the welcome solar system or the empty
  state's without keeping the two lifts equal.
- **Links are `LinkButton` (brand rose, `Theme.link`), never
  `.buttonStyle(.link)`** — system blue was the one color outside the
  palette. Status *text* gets its own text-grade tokens (`textPositive`,
  `textDanger`, `textWarning`): the dot/fill colors (`dotActive`,
  `closeRed`, `dotDegraded`) pass 3:1 non-text contrast but not the 4.5:1
  small text needs on the light chrome — that's why each hue exists twice.
  Copy-to-clipboard is `CopyIconButton` (hover chrome + checkmark confirm),
  both in `Components.swift`.
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
- **Window frame and sidebar width persist in `settings.json`, not the frame
  autosave.** Debug and packaged builds have different UserDefaults domains,
  so the autosave never carried between them; `WindowFrameSaver` (the window
  delegate) writes `windowFrame` `[x,y,w,h]` on move/resize-end and restore
  prefers it over the autosave (kept as fallback). Same degenerate-frame guard
  on save and restore, plus an on-some-screen check; `sidebarWidth` is written
  on divider-drag end and clamped to the 180–420 drag range on read.
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
