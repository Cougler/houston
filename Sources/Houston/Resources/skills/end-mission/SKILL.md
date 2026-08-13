---
name: end-mission
description: Wrap a session — write the session log AND the handoff into missionlog.md, refresh .mc.json notes, then kill the project's dev servers. Run /push first to commit & push.
---

# /end-mission — End Mission

Triggered when the user says **"end mission"** (or "wrap up", "stop servers", "close dev servers").

This skill does two things: **(1) save a log of what we did this session**, and **(2) kill the dev servers.** Git commit/push is **not** part of this anymore — run **/push** before this to publish your work.

## Steps

### 1. Write the session log

Append a new entry to **`~/Apps/<project>/missionlog.md`** describing this session. This is the running, append-only log Houston reads and renders in the Projects tab — the format matters.

If the file doesn't exist yet, create it with a title header first:

```markdown
# <Project> — Mission Log

---
```

Then prepend a new entry **at the top** (newest first), immediately after the title/`---`, using exactly this shape:

```markdown
## YYYY-MM-DD — <Short session title>

<1–3 sentence present-tense summary: what's working, what was just completed, what's next. Plain English, no jargon dump.>

**Done this session:**
- <specific change — file/component names, not vague>
- <specific change>

**Up next:**
- <most likely next task>
- <next task>

**Handoff:**
- <anything the next session needs that the bullets above don't say>

---
```

Format rules (Houston's parser depends on these):
- Header must be `## YYYY-MM-DD — Title` (real em dash or hyphen, today's date).
- The summary paragraph comes **before** any `**Section:**` marker.
- Section labels are exactly `**Done this session:**` and `**Up next:**`, each followed by `-` bullets.
- `**Handoff:**` goes LAST, immediately before the `---`. Houston renders the
  summary and the two known sections; keeping this one at the end means that if
  its parser ever does something unexpected with an unknown label, it can only
  affect the tail of the entry. If the Projects tab starts showing handoff
  bullets as "Up next", move this section above `**Done this session:**`.
- End every entry with a `---` separator.

### What belongs in **Handoff:**

The state the next session cannot reconstruct from the code or from git — and
**nothing that is already written down somewhere durable.** If it is true of the
project rather than of this session, it belongs in `CLAUDE.md`, not here.

Worth writing:
- Work that is HALF-done, and why it stopped where it did.
- A decision taken under an assumption that hasn't been validated yet.
- Anything the session could NOT verify, and what verifying it would take
  (a permission, a device, a credential, someone else's review).
- Environment facts a fresh session would trip over — a non-obvious build
  invocation, a stale cache, a service left running deliberately.
- Branch state when it isn't obvious: unpushed commits, an unopened PR.

Not worth writing (it belongs elsewhere, or nowhere):
- Build/test commands, architecture, gotchas → `CLAUDE.md`.
- A restatement of the summary or the bullets above it.
- Anything `git status` / `git log` answers on its own.

### 2. Refresh .mc.json

- **`~/Apps/<project>/.mc.json`** — set the `notes` field to the 1–3 sentence status note from the log entry. Preserve all other fields.

**Do NOT write a separate handoff file, and do NOT overwrite the project's
`CLAUDE.md` with a handoff template.** The mission log's top entry IS the
handoff — it is newest-first by design, so there is exactly one account of
where things stand and no way for two copies to drift apart.

`CLAUDE.md` is the project's own context file: what the system IS, how to build
it, the rules and gotchas that outlive any session. Many projects keep a
carefully curated one that is checked into git — replacing it with a generated
status template destroys real work. If this session earned something DURABLE
(a gotcha, a convention, a build fact), add it to `CLAUDE.md` in that file's own
style; everything else goes in the log entry.

That addition is an EDIT, never a rewrite: insert the rule where its neighbours
live, match their voice and length, and leave the rest of the file byte-for-byte
alone. If the file documents its own growth policy — where new rules go, a size
budget, a companion file for the long version — follow it; that policy is the
project telling you how it wants to be extended. When in doubt about whether
something is durable, it isn't: put it in the log entry.

### 3. Kill the dev servers

```bash
pkill -f "next dev" 2>/dev/null; pkill -f "next-server" 2>/dev/null; pkill -f "vite" 2>/dev/null; pkill -f "react-scripts start" 2>/dev/null; echo "done"
```

If a specific project port is known (from `.mc.json` `devPort` or the start command), also target it directly:

```bash
kill $(lsof -ti:<PORT>) 2>/dev/null; echo "done"
```

### 4. Confirm ports are free

```bash
lsof -iTCP -sTCP:LISTEN -P | grep -E ':(3[0-9]{3}|4[0-9]{3}) '
```

If nothing relevant is returned, the ports are clear.

### 5. Confirm

Reply with: **"Mission logged."** plus a one-line summary (e.g. *"Logged the session to missionlog.md and killed the dev server on :3000."*).

---

## Notes

- **Run `/push` before this** to commit and push the session's work — end-mission does **not** touch git.
- If `pkill` doesn't kill a stuck dev server, fall back to `lsof -ti:<port> | xargs kill -9`.
- This skill does **not** exit the Claude session — it just wraps up and kills servers. If you also want to close the terminal/session, say so explicitly.
- The missionlog entry and the `.mc.json` note tell the same story — the present-tense status note is the source they share.
- `/start-mission` and `/handoff` both read the handoff back out of the log's top entry, so write it for a reader who has none of this session's context.
