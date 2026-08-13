---
name: handoff
description: Read a project's handoff (the newest missionlog entry) and resume work exactly where the last session left off.
---

# /handoff — Resume a Project

Triggered when the user says **"handoff"** followed by a project name (e.g. "handoff hierarch", "handoff portfolio").

## Steps

### 1. Resolve the project path

- If the user gives a full path, use it directly.
- If they give a name (e.g. "Hierarch"), check `~/Apps/<name>` (case-insensitive — try the name as given, then Title-cased).
- If unclear, ask.

### 2. Read the handoff

Read `~/Apps/<project>/missionlog.md` and take the **newest entry** — it is at
the TOP, under the most recent `## YYYY-MM-DD — Title` header. That entry is the
handoff: its summary is where things stand, **Up next** is what to do, and
**Handoff** (when present) carries what the last session knew that the code
doesn't say.

There is deliberately no separate handoff FILE. Two documents describing one
state drift apart, and then neither can be trusted; the log is newest-first so
its top entry already serves that purpose.

`~/Apps/<project>/CLAUDE.md` is the project's own context file — what the system
is and how to build it. Claude Code auto-loads it; it is not a status document.
`~/Apps/<project>/.mc.json`'s `notes` field echoes the same status in a
paragraph, useful only if the log is missing.

### 3. Scan recent changes (optional but helpful)

If the project is a git repo, run:

```bash
cd ~/Apps/<project> && git log --oneline -10
```

This gives a quick sense of the last commits.

### 4. Brief the user

Reply with a concise handoff summary in this format:

---

**Picking up [Project Name]**

**Where we left off:**
[2–3 sentences from the newest missionlog entry — present tense, plain English]

**Worth knowing:**
[only if that entry has a **Handoff** section — the items that change what you'd do first. Omit this whole block if there are none.]

**Recent commits:**
- [list from git log if available]

**Ready to continue. What would you like to work on?**

---

Keep it short and scannable. Synthesize; don't dump the entry.

### 5. Stay ready

After the briefing, wait for the user's next instruction. You are now fully in context for this project.

---

## Notes

- Do NOT start any dev servers automatically — let the user do that with `/start-mission` if needed.
- If missionlog.md doesn't exist, fall back to `.mc.json` notes, then README.md, then just describe the project folder structure.
- The goal is to get the user back up to speed in under 30 seconds.
