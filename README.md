<img width="1039" height="679" alt="Houston" src="https://github.com/user-attachments/assets/341c9693-cc7a-4f86-ab85-80f03532003e" />

# Houston

Houston is a native macOS app for running coding agents. It puts your
projects in a sidebar, opens a real terminal in whichever one you click,
and keeps watch over the things you'd otherwise be checking by hand:
git state, dev servers, and what your Claude session is up to.

The terminal is the real thing — panes are backed by
[libghostty](https://github.com/ghostty-org/ghostty), so anything you'd do
in Ghostty works here. Houston's job is everything around the terminal:
knowing which agent is running where, how much context it has left, whether
your working tree is dirty, and whether the server on port 3000 is actually
answering.

**[Download for macOS](https://tryhoustonapp.com)** (macOS 14+, universal),
or install from the command line:

```sh
curl -fsSL https://tryhoustonapp.com/install.sh | sh
```

## What it does

**Projects.** Add a single project or a whole folder of them. Clicking one
opens a shell in that directory. Rows show uncommitted line counts at a
glance, and a project that's running an agent gets mirrored into the
Terminals section without ever leaving its place in the list.

**Sessions.** When a Claude Code session is running, a status bar under the
terminal shows the model (switchable from a menu), a context meter with the
window's true size, account rate limits, MCP server health with one-click
OAuth, and whether you're inside peak hours. The data comes from Claude's
own statusline hook, which Houston offers to install — with your consent,
and reversibly — the first time it sees a session.

**Missions.** Houston ships four Claude Code skills that give sessions
continuity. Start Mission boots an agent with the context of where the last
session left off. Handoff is a one-click context reset: it writes a log
entry, clears the session, and re-briefs a fresh context from what was just
written — nothing learned gets lost, because it round-trips through the
mission log. End Mission wraps up. The log itself is a plain markdown file
in your project, newest entry first.

**Git.** A panel shows the working tree as a pipeline — uncommitted,
committed, synced — with commit details and file diffs. You can switch and
create branches from it, and clone a repo straight from the sidebar. All
git commands are typed into the visible terminal rather than run silently,
so when something fails you see git say why.

**Servers.** Anything listening on a dev port shows up in the sidebar,
colored by an actual HTTP probe: green if it responds, orange if it's slow
or erroring, red if the socket is there but nothing answers.

## Building

It's a single SwiftPM executable, no Xcode project:

```sh
swift run
```

`scripts/package.sh` builds the distributable: universal binary, app
bundle, and a DMG with the drag-to-Applications window. With a `SIGN_ID`
it also signs, notarizes, and staples.

## A few honest notes

- Terminal sessions live inside Houston's process, so they end when the
  app quits. Same tradeoff as closing your terminal emulator.
- Context and cost readouts are Claude-specific, because Claude Code is
  the only agent that publishes them. Other agents (Codex, Gemini, Aider,
  OpenCode, and friends) are detected and launchable, but show less.
- Enabling the status bar replaces the `statusLine` command in
  `~/.claude/settings.json`. Your original is backed up and restorable
  from the gear menu; other terminals show a blank status row while
  Houston's feed is active.
