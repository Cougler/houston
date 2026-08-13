---
name: log-mission
description: Checkpoint the session — write the mission-log entry and refresh .mc.json, nothing else. Step one of Houston's Rebrief (log → /clear → /handoff). Does not touch git or the dev server.
---

# /log-mission — Log Mission (checkpoint)

Triggered when the user says **"log mission"**, or when Houston types
`/log-mission` as step one of a **Rebrief**: Houston waits for this skill to
write `missionlog.md`, then sends `/clear` and `/handoff` so a fresh context
picks up exactly where this one leaves off.

This is a **checkpoint, not an ending.** It is `/end-mission` minus the
teardown: record where things stand and stop there.

- Do **not** kill the dev server.
- Do **not** commit or push (that's `/push`).
- Do **not** treat the session as over — the very next thing that happens may
  be `/handoff` reading this entry back into a fresh context window.

## Steps

1. Write a **2–3 sentence project status note** in plain English — a
   *present-tense snapshot*: what's working, what was just completed, what's
   next. Write it as if briefing someone picking the project up tomorrow.

2. **Append a session log entry to the top of `missionlog.md`** at the project
   root (newest first; create the file with a `# <Project> — Mission Log`
   title + `---` if it doesn't exist). Houston's Projects tab parses this, so
   use the exact format:

   ```markdown
   ## YYYY-MM-DD — <Short session title>

   <The 2–3 sentence status note from step 1.>

   **Done this session:**
   - <specific change>

   **Up next:**
   - <next task>

   **Handoff:**
   - <what the next context needs that the bullets don't say>

   ---
   ```

   Header must be `## YYYY-MM-DD — Title` (today's date); section labels
   exactly `**Done this session:**` and `**Up next:**`; `**Handoff:**` last,
   immediately before the closing `---`.

   **Write the Handoff section as a briefing to your own successor** — after a
   Rebrief it will be read back within seconds by a context that remembers
   nothing: work left half-done and why it stopped there, decisions taken on
   unvalidated assumptions, anything this session could not verify, environment
   facts a fresh session would trip over.

3. Update the project's `.mc.json` by setting the `notes` field to the status
   note from step 1. Preserve all other fields.

4. Confirm: **"Mission logged."**
