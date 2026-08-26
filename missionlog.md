# Houston — Mission Log

---

## 2026-08-25 — Searchable theme picker, icon footer, paginated onboarding

The terminal theme menu is now a searchable flyout card (max-height list, search field, last-10 recents) instead of a 485-item submenu, the sidebar footer collapsed to one horizontal icon row, and a new seven-page onboarding dialog replaced the old WelcomeView — it shows once per install and replays from the gear. All of today's work (this plus the morning's share-proxy/ServerPanel session) is uncommitted on main; next is reviewing the onboarding in the running debug build, then /push.

**Done this session:**
- `SearchableMenuList` in Components.swift: reusable searchable list for any over-long menu — pinned auto-focused search field, Recents section while the query is empty, 340pt max-height scroll; native NSMenus can't host a text field, hence a presented card
- Theme picker rebuilt on it (`TerminalThemePicker` in MainWindowView): per-theme swatches drawn in each theme's own bg/fg colors, checkmark on current, Houston default pinned first; presented in the rail-flyout chrome (panelFill card, spring slide, full-window clear scrim, Esc closes) after an NSPopover first cut — anchored bottom-leading beside the gear in both sidebar states
- `recentTerminalThemes` in settings.json (newest first, deduped, cap 10); picks from every entry point bump it
- Menu-bar Settings menu's theme submenu now shows Houston + recents + "All Themes…" (posts `.houstonShowThemePicker` to open the window's picker) instead of the full catalog
- Sidebar footer: one horizontal icon row — Collapse, Settings, Reminders, Notifications (labels and the short rule gone; badges ride icon corners); rail unchanged; dead `labeled` GearLabel variant removed
- `OnboardingView.swift`: 7-page centered card over a 25% scrim — Terminals (animated typing vignette), Servers, Share Your Work (.local + COMING SOON), Projects, Status Bar, Reminders, Themes; illustration → title → two sentences → dots (active dot white, 2× wide) → Skip/Back/Next controls
- Deleted WelcomeView.swift (git rm); `welcomeSeen` replaced by fresh `onboardingSeen` key so existing installs see the new onboarding once; "Show Onboarding" replay item in the footer gear

**Up next:**
- Review the onboarding in the running debug build (it should be up right now — fresh `onboardingSeen` key) and iterate on copy/vignettes
- /push — everything from today's two sessions is uncommitted on main
- Carried over: phone-test `hierarch.local`, tier-3 relay (Hetzner VPS + frp/sish), persist the right sheet's pin state

**Handoff:**
- The debug Houston binary was relaunched with the onboarding showing; Aaron hasn't reviewed it yet — expect tweak requests to OnboardingView.swift (copy, vignettes, sizing) before /push.
- Theme-picker flyout keyboard focus is unverified: unlike the NSPopover cut (own window), the flyout lives in the main window — check the search field actually grabs first responder on open.
- The onboarding scrim is inert by design (no click-away) — Skip/Esc/Start Exploring are the outs; the theme flyout DOES click-away-dismiss.
- CLAUDE.md still documents `welcomeSeen` and the old footer/theme-menu layout in its Settings/gotchas prose; not updated this session.
- The stale `welcomeSeen` key remains harmlessly in settings.json (write preserves unknown keys); `onboardingSeen` is the live flag.
- Everything from the morning session's handoff still stands: Hierarch's Vite server runs from a nohup shell (not a Houston pane), `.local` is only Mac-side verified, Sequoia network prompts unobserved, light-mode Theme.link not eyeballed.

---

## 2026-08-25 — Shareable dev URLs (tiers 1+2), server sheet, design polish

Shareable dev URLs are live: a reverse proxy serves `<project>.localhost` on this Mac and `<project>.local` to any device on the Wi-Fi (mDNS A records), with the public-link tier reserved as a Coming Soon card. The server page moved into the shared right sheet as `ServerPanel`, sheets are now swappable with no click-away scrim, and a design pass added brand-rose links plus accessible text-grade status color tokens. Next: exercise `.local` from a real phone and design the tier-3 relay.

**Done this session:**
- `ShareProxy.swift`: Host-header reverse proxy on port 80 (fallback 14080, outside the dev-scan range), byte-splice after first request headers so WebSockets/HMR/SSE work; unknown hosts get a listing page, dead backends a friendly offline page (`.waiting` = connection refused — Network.framework would retry forever)
- `MDNSAdvertiser.swift`: `<project>.local` hostname A records via `DNSServiceRegisterRecord` (NWListener Bonjour can't register hostnames); re-registers on IP change, tears down when idle
- Vite host-check fix twice over: `server.allowedHosts: ['.local']` added to Hierarch's vite config, and `TerminalEnvironment` now sets `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.local` so any Vite server launched from a Houston pane accepts `.local` names automatically
- `ServerPanel` in the right sheet (RightPanel.server(id)): replaced both the dead full-page ServerDetailView (deleted) and the interim popover; strategic layout — name + health pill (ops trivia in its tooltip), ONE primary link (pretty URL, falls back to `localhost:<port>` when sharing is off), action buttons, then Sharing with two matching cards: "Any device on your Wi-Fi" (wifi icon, `.local` link) and "Anyone, anywhere" (COMING SOON badge)
- Swappable sheets: no scrim; opener clicks swap content in place; project/shell rows select without dismissing; floating sheet closes on header gaps, empty-state sky, sidebar dead space (`onEmptyClick`), terminal clicks (`.houstonTerminalClicked` from `HoustonTerminalView.mouseDown`), and ✕; selection changes never auto-dismiss
- Design pass: `Theme.link` (brand rose, AA in both modes) + reusable `LinkButton` (hover underline, hand cursor) and `CopyIconButton` (hover chrome, checkmark confirm); text-grade tokens `textPositive`/`textDanger`/`textWarning` replacing raw green/red/amber hexes across sidebar diff counts, GitPanel, FeedSheet, WelcomeView; amber unified as `dotDegraded`; sharing toggle tinted rose
- `sharingDisabled` setting (default on) with the toggle in ServerPanel

**Up next:**
- Open `hierarch.local` from a real phone — the mDNS + proxy path is only verified Mac-side (curl with spoofed Host + `dns-sd` resolution)
- Tier 3: buy the short share domain, stand up frp/sish on a VPS (Hetzner CX22 Ashburn chosen, ~$4.59/mo), wire the Coming Soon card
- Persisting the right sheet's pin state (carried over from last session)

**Handoff:**
- The Hierarch Vite server is currently running from a plain background shell (nohup, pid on port 5173), NOT a Houston pane — it died with a Houston relaunch mid-session and was restarted to verify the `.local` fix. The next Houston-pane launch re-owns it.
- The `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` env var only reaches servers launched from Houston panes; servers started elsewhere still need the vite.config line (Vite's own block page prints the fix).
- The proxy splices raw bytes — the Host header is NOT rewritten (keep-alive would make per-first-request rewriting inconsistent). Frameworks that host-check see the pretty name; only Vite is known to care.
- Sequoia's Local Network privacy prompt and the firewall "allow incoming connections" dialog have not been observed yet — first packaged-build run on a fresh machine may surface both.
- Light-mode `Theme.link` (#8F5350) is computed-contrast approved but not eyeballed against the brand rose — Aaron may want it nudged.
- Contrast numbers for all new tokens are hand-computed, not tool-verified.
- The debug Houston binary was left running for review; the packaged-build items from last session's handoff (banners, self-updater verify) remain unexercised.

---

## 2026-08-24 — Reminders, notification feed, unified right sheet, v1.0.8 shipped

Houston 1.0.8 is shipped (notarized DMG on GitHub Releases and tryhoustonapp.com) with two new systems: Reminders — dated obligations captured via the new bundled /track skill or a manual form with an inline calendar, stored in tracked.json and surfaced with lead-window badges and banners — and a Notifications feed collecting needs-you events, finished turns, due reminders, and commits. Git, Skills, Reminders, and Notifications all live in one full-height right sheet now, floating by default and pinnable inline. Next: install 1.0.8 and exercise the reminder banners and the /track skill end-to-end in the packaged build.

**Done this session:**
- `/track` skill (Resources/skills/track, auto-installed): Claude converts "track X in 24 months" to an absolute date and writes `Application Support/Houston/tracked.json`; handles list/done/untrack and `repeatMonths` recurrence
- `TrackedStore`: polls tracked.json (mtime + day-rollover), computes lead windows, posts feed events + packaged-build banners once per item per launch; write-backs (done/undone/postpone/remove/add) mutate raw JSON so unknown skill fields survive
- `EventFeed` + `FeedSheet`: in-session notification feed — needs-input/finished (via NotifyStore), reminders coming due, commits detected from GitInfo HEAD movement on the watched branch (branch-switch and rebase filtered out)
- Unified right sheet (`rightSheet` in MainWindowView): one full-height strip for Git/Skills/Reminders/Notifications, spring slide-in, pin toggle — floating overlays with scrim + click-away, pinned reserves layout width and pushes the detail column; single always-mounted view so pin/unpin doesn't jump; replaced the old floating panels, their scrims, and the DetailFrameKey plumbing
- Reminders sheet (TrackedPanel rewrite): card items with deterministic-color project tags, countdown pills swapping to actions on hover, sort (due/title/project) + project filter pills, "Track something" trailing the list until it pins to the bottom, manual add form with custom CalendarGrid (fixed 6-week grid, year pull-down, today dot, past days inert), HIG-style remind pull-down and inset fields, /track hint chip
- Sidebar: Notifications + Reminders rows above a labeled Settings row (collapse below a short rule); rail back to 52pt; quiet all-caps section headers everywhere; server glyphs plain gray (health lives in the tooltip); "New" instead of "New Terminal"
- Empty-state sky back to its own color inside the terminal's rounded container with 30pt top/bottom rails
- Released v1.0.8 (signed, notarized, stapled; site DMG synced); featureideas.md started with the shareable-localhost-URLs concept

**Up next:**
- Install 1.0.8 and exercise the packaged loop: reminder banners, /track from a real session, feed events landing while unfocused
- Consider persisting the right sheet's pin state in settings.json (session-only today)
- The Hierarch client-secret reminder's due date (2028-08-24) was assumed from "24 months from today" — verify against the actual Azure expiry

**Handoff:**
- tracked.json is seeded with one real item (Hierarch client secret, due 2028-08-24, leadDays 30) — its date is an assumption, not read from Azure.
- Reminder banners and the tracked-due notification path have never run in a packaged build; debug builds badge only (`UNUserNotificationCenter` needs a bundle).
- Commit-feed events only watch the selected project (they ride GitStatusStore's existing poll); background projects' commits are invisible by design.
- The self-updater in-place install remains unverified from an installed build — 1.0.8 is the third release without anyone exercising verify → swap → relaunch.
- The right sheet's pin state and the Reminders sort/filter are session-only @State — deliberate, not an oversight.
- The debug Houston binary was left running for the user to review the sheet redesign.

---

## 2026-08-19 — Sidebar avatars + density, git commands page, v1.0.5 & v1.0.6 shipped

Houston 1.0.5 and 1.0.6 are shipped — notarized DMGs on GitHub Releases and tryhoustonapp.com, both cut cleanly via /release. The sidebar got a full pass: terminal rows now lead with a git-status avatar (tinted circle, agent logo as a corner badge), everything is denser, and sidebar width/collapse plus the window frame persist in settings.json so they survive updates. The git panel gained a click-to-run Git Commands page. Next: actually exercise the self-updater's in-place install from an installed build, and enable the needs-you notification hooks.

**Done this session:**
- Sidebar rows: leading agent icon replaced by a status avatar — circle filled with the git-status color at 18% + solid 1pt ring, centered terminal glyph, agent logo as an 11pt white-backed badge overhanging lower-right; trailing git dot and the attention edge bar removed (rose wash is the whole signal)
- GitPanel: new Git Commands page (terminal button in the header) — sync/commit/stash/undo/inspect catalog, each row shows the exact command and runs it in the project's terminal; destructive ones (`git restore .`, `git clean -fd`) are typed but not executed, Return confirms; commit rows prompt for a message
- Theme.controlHovered token (16% white / 11% black) — skill run buttons (row rocket + detail "Run Skill") now visibly darken on hover
- Density pass: rowInset 5→3, pill inner padding 12→8, row heights trimmed (terminals 32→28, library 28→26, headers 22→20, servers 42→38), header/footer insets 14→10 mirrored in the collapsed rail
- Persistence: sidebarWidth + windowFrame ([x,y,w,h]) in settings.json — WindowFrameSaver window delegate saves on move/resize-end; restore prefers settings over the UserDefaults frame autosave
- Released v1.0.5 and v1.0.6: signed, notarized, stapled DMGs on GitHub Releases with the site DMG synced both times

**Up next:**
- Run the self-updater for real: open the installed 1.0.4/1.0.5 app and let it install 1.0.6 in place — first true test of verify → swap → relaunch
- Enable needs-you notifications from the gear menu and validate the loop (badges in debug; banners need the packaged app)
- Live with the new avatar rows and tighter density; adjust any single number that feels off

**Handoff:**
- The self-updater's in-place path is STILL unverified — 1.0.5 and 1.0.6 both shipped, but no installed build has actually run the update flow yet; that was the point of cutting 1.0.5 and it hasn't happened.
- The needs-you notification hooks have still never been enabled; the pipeline remains unexercised end-to-end.
- settings.json's sidebarWidth/windowFrame keys only appear after the first divider drag or window move/resize — their absence right after launch is not a bug.
- A "traffic lights on a tab sticking above the window" idea was explored and explicitly dropped by the user ("nah forget i asked") — don't resurrect it.
- The debug Houston binary was left running for the user to eyeball the density pass.

---

## 2026-08-19 — Self-updater, needs-you notifications, first real releases

Houston now ships properly: v1.0.3 and v1.0.4 are on GitHub Releases with notarized DMGs, tryhoustonapp.com serves the same build, a `/release` skill does the whole chain in one command, and 1.0.4+ installs updates in place (verify → swap → relaunch). The big new feature is needs-you notifications — Claude Code's Notification/Stop hooks drive native banners, a menubar dot, and rose-washed sidebar rows — alongside a pile of chrome polish (git sheet fixes, 81pt collapsed rail containing the traffic lights, click-away panels, accessible light-mode green). Next: enable the hooks and live with notifications, then cut 1.0.5 to test the self-updater's first real in-place install.

**Done this session:**
- Git sheet: fixed long branch names blowing the 320pt card out (fixed "Branch" title, name below in smaller text), wider section spacing, untracked dirs expanded to real files (`-uall`), "Empty file" preview note
- Releases: v1.0.3 and v1.0.4 published (signed, notarized, stapled DMGs) — the repo had NO releases before, so installed apps had nothing to update from; site DMG synced both times
- `/release` skill (.claude/skills/release): package → GitHub release → site DMG → verify, one command
- Self-updater (`UpdateInstaller`): downloads the release DMG, verifies deep codesign + TeamIdentifier 4CDVHNL984 + Gatekeeper, swaps the bundle with rollback, relaunches via detached child; pills/alert install in place with confirmation (sessions die with Houston)
- Needs-you notifications (`NotifyFeed`/`NotifyStore`): one script as Claude's Notification+Stop hooks (consent-gated, non-destructive settings.json hooks merge), events per HOUSTON_PANE, banners (packaged builds only) + menubar amber dot + sidebar badges; banner click routes to the project; viewing clears
- Sidebar row re-layout: agent/AI icon now leads the row, git dot moved to trailing (hover-✕ swaps in same 16pt cell), attention = rose row wash + 3pt edge bar drawn in RowChrome
- Chrome: collapsed rail 81pt (traffic lights end at x=69, measured; L-shelf removed), terminal leading padding removed, footer gear+collapse horizontal and pinned at 14pt in both states, git/skills panels dismiss on clicks anywhere (3 scrim rects around tracked detail frame), popover fills match sidebar bg in light mode, dotActive green darkened to #15803D in light mode (all meters unified on the token)

**Up next:**
- Enable needs-you notifications from the gear and validate the full loop (badge in debug; banners need the packaged app)
- Cut 1.0.5 via /release once validated — first real test of the self-updater from installed 1.0.4
- Eyeball the new row layout (icon leading / git dot trailing) and the rose attention wash

**Handoff:**
- UNCOMMITTED: MainWindowView.swift carries the row re-layout + attention wash/edge-bar (chosen over dot via user Q&A: "Row wash + edge bar") — build passes, running in the relaunched debug binary, not yet committed; run /push.
- The notification hooks are NOT enabled — NotifyFeed.install() only runs from the gear-menu consent alert; nothing has ever exercised the pipeline end-to-end. Debug builds can't banner (UNUserNotificationCenter needs a bundle id) — badges/menubar dot only.
- The self-updater's real path (installed app swapping itself) is untested — only the pipeline commands were verified headlessly against the 1.0.3 DMG. The 1.0.5 release is the test.
- Anyone on the 1.0.3 site DMG updates via browser download (self-updater shipped in 1.0.4).
- Releasing = /release skill; SIGN_ID is the Developer ID "Aaron Cougle (4CDVHNL984)", notarization via keychain profile houston-notary. GitHub release + site DMG must both happen or installs and downloads drift.
- houston-fos (the site) is NOT a git repo — deploys go straight from the working dir via vercel --prod.

---

## 2026-08-12 — UI polish pass, mission controls, packaged skills, first DMG

Houston now packages as a universal, ad-hoc-signed DMG (`scripts/package.sh` → `dist/Houston.dmg`) and the invisible-window bug it exposed is fixed. The day's polish landed everywhere: warm light theme with 10%-black borders and a matching terminal background, a mirror-not-move sidebar (Terminals / Servers / Projects with library rows that never jump sections), header mission controls (rocket Start Mission gated on a mission log; a Mission menu whose Handoff does a one-click log → /clear → /handoff context reset via the new bundled log-mission skill), an evenly-distributed responsive status bar with peak hours, a skills sheet with detail pages, and health-colored server icons. Next: install the DMG and live in the packaged build.

**Done this session:**
- Light-mode theme: #EBEBEB background, 10%-black borders + orbit rings, empty-state sky one step off the chrome each way, Houston terminal theme background matched to the chrome
- Sidebar model: mirror-not-move (`.library` rows with green live glyph, project rows never leave Projects), always-visible "+ New" (32pt, right-click for project shell) and "+ Add" rows, gear bottom-left, ✕-on-hover closes terminal rows, empty-state guidance text
- Mission lifecycle: Start Mission / Mission menu inline with header buttons; new bundled `log-mission` skill; `HandoffCoordinator` sequences log → mtime-watch → /clear → /handoff with a 3-min timeout; all four mission skills packaged in the app and installed to ~/.claude/skills when missing
- Status bar: mission buttons and chart toggle removed, groups (model+context, meters) spread evenly, compact tier under 620pt (% only, peak label only, details in tooltips), per-item toggles + Hide/Disable persisted in settings, mirrored in a new menu-bar Settings menu
- Skills sheet: "Comes with Houston" section, rocket run buttons with tinted-pill hover, pushed detail pages (curated copy for mission skills, Run/Type/Reveal actions)
- Server rows: servers.svg drawn as a tintable Shape, colored by a gentle HEAD probe (green/orange/red) — probe hits `localhost` not 127.0.0.1 (IPv6-only binds read as down)
- Packaging: `scripts/package.sh` (universal build, resource bundle, icns from AppIcon.png, ad-hoc sign, DMG); fixed `contentViewController` collapsing the window to 1×1 in fresh-prefs launches

**Up next:**
- Install dist/Houston.dmg to /Applications and live in the packaged build
- Hand-verify the one-click Handoff sequence end-to-end in a real session
- Get a Developer ID for real signing/notarization when distribution matters

**Handoff:**
- The DMG is ad-hoc signed (no Developer ID on this machine) — Gatekeeper rejects it if downloaded; local installs fine, other Macs need right-click → Open.
- `dist/` is untracked build output — gitignore it before /push (scripts/ and Resources/skills/ SHOULD be committed).
- The packaged app was left running deliberately (user testing); the debug binary was killed. Its prefs domain is com.cougler.houston — a 1×1 frame saved by the broken first build was cleared here, and the code now refuses degenerate frames anyway.
- Hand-unverified: the Handoff sequence (mtime watch + /clear timing — settle is 3s, may clip a turn whose log write lands early), menu-bar Settings actions, per-item status toggles, compact bar under 620pt, server health colors against a 5xx, skills detail pages, skill install on a fresh machine.
- Peak hours is a local-clock port of the user's old statusline script (9:00–18:00) — the Claude statusline payload carries no peak data (verified in docs), so don't go looking for it there.
- Houston's feed script is still the user's global Claude statusline; other terminals show a blank status row by design (backup restorable from gear menu).

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
