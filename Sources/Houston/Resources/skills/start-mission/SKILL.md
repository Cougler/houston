---
name: start-mission
description: Resume a project where the last session left off and start its local dev server. Git is handled separately by /pull.
---

# /start-mission — Start Mission

Triggered when the user says **"start mission"** (optionally followed by a project path or name), or when Houston types `/start-mission` into a freshly spawned session.

## Context: what Houston already did

When launched from Houston, the navigate / launch / rename steps are **already done** before this skill runs:

1. Houston spawned a terminal **in the project directory** and started `claude` there (so the current working directory *is* the project).
2. Houston typed `/rename <project>` to name the session.
3. Houston then typed `/start-mission` — that's this skill.

So this skill does **not** navigate, launch claude, or rename. It picks up context and starts the dev server. **It does not touch git** — that's `/pull`, which the user runs right after this.

## Steps

### 1. Resolve the project path

- The current working directory is normally the project (Houston launched here). Use it.
- If the user gave a full path, use it directly.
- If they gave just a name (e.g. "Hierarch"), assume `~/Apps/<name>`.
- If still unclear, ask.

### 2. Pick up where we left off

Read the project's recent history and brief the user so the session resumes in full context:

1. **`~/Apps/<project>/missionlog.md`** — **this is the handoff.** The newest
   entry is at the TOP, under the most recent `## YYYY-MM-DD — Title` header.
   Read that one entry whole: the summary is where things stand, **Up next** is
   what to do, and **Handoff** (when present) is what the last session knew and
   the code doesn't say — half-done work, unvalidated assumptions, anything it
   could not verify, environment facts, branch state. Older entries are history;
   don't read past the first unless something in it points backwards.
2. **`~/Apps/<project>/CLAUDE.md`** — the project's own context file (what the
   system is, how to build it, rules and gotchas). Claude Code auto-loads it, so
   don't re-read it wholesale — it is NOT a status document and does not
   describe the last session.
3. **`~/Apps/<project>/.mc.json`** — the `notes` field, a one-paragraph echo of
   the same status. A tiebreak if the log is missing, not a second source.

Then give a short, scannable brief:

---

**Picking up [Project Name]**

**Where we left off:** [2–3 sentences from the latest missionlog entry — present tense, plain English]

**Up next:** [the most likely next tasks from that entry's "Up next"]

**Worth knowing:** [only if the entry has a **Handoff** section — the one or two items that change what you'd do first. Skip this line entirely if there's nothing.]

---

Synthesize — don't dump the whole file. If none of these exist, fall back to README.md, then a quick description of the folder structure.

If the log's newest entry says work was left half-done or unverified, say so in
the brief rather than opening with a clean-slate summary — the point of reading
it is to not repeat what the last session already learned.

### 3. Check for running dev servers

Before starting anything, see what's already running:

```bash
lsof -iTCP -sTCP:LISTEN -P | grep -E ':(3[0-9]{3}|4[0-9]{3}) '
```

Report any dev servers already running on ports in the 3000–4999 range so there's awareness of leftovers from previous sessions.

### 4. Find the project's dev port

Check in this order, stop at the first match:

**a) `.mc.json` overrides** — read `~/Apps/<project>/.mc.json`:
- `devCommand` — a full shell command to run instead of `npm run dev`. If present, use it verbatim (skip step 5's package.json lookup) and treat any `devPort` as `$PROJECT_PORT`.
- `devPort` — a specific port the project should always use. Use it as `$PROJECT_PORT` (skip 4c).

**b) Hardcoded port in `package.json`** — if no `.mc.json` override, inspect the `dev` script for an explicit port flag (`next dev -p 3333`, `next dev --port 3333`, `vite --port 3333`, any `--port <N>` / `-p <N>`). Use it as `$PROJECT_PORT`.

**c) Fall back to scanning** — only if neither (a) nor (b) yields a port, scan for the first free port from 3000:

```bash
for port in 3000 3001 3002 3003 3004 3005; do
  lsof -ti:$port > /dev/null 2>&1 || { echo $port; break; }
done
```

In all cases, if `$PROJECT_PORT` is already in use, report it and ask before killing or reassigning — a dedicated port likely means another instance of this same project is already running.

### 5. Determine the start command

If `.mc.json` provided a `devCommand`, use it verbatim and skip the rest of this step.

Otherwise read `~/Apps/<project>/package.json` for the dev/start script (default to `npm run dev` if present). For non-Node projects (Swift, etc.), note the appropriate run command (e.g. Xcode / `swift run`) and skip steps 6–7.

### 6. Start the dev server

If `devCommand` was provided, run it as-is (it's assumed self-contained — don't append `--port`):

```bash
cd ~/Apps/<project> && <devCommand> > /tmp/<project>-dev.log 2>&1 &
```

If the port came from a hardcoded `package.json` script (4b), run without appending `--port` (the script already specifies it):

```bash
cd ~/Apps/<project> && npm run dev > /tmp/<project>-dev.log 2>&1 &
```

Otherwise start on the scanned free port from 4c (Vite uses `--port`, Next.js uses `-- --port`):

```bash
cd ~/Apps/<project> && npm run dev -- --port $PROJECT_PORT > /tmp/<project>-dev.log 2>&1 &
```

### 7. Open in browser

```bash
open http://localhost:$PROJECT_PORT
```

### 8. Confirm

Reply with something like:

> **Mission started.**
> - <Project Name> → http://localhost:$PROJECT_PORT
>
> Run **/pull** to sync the latest from GitHub before you start working.

---

## Notes

- **Git is out of scope here.** Checking the repo, fetching, and pulling now live in **/pull** — run it right after this skill. Committing/pushing lives in **/push**, run before **/end-mission**.
- Never kill an existing dev server without asking — it may belong to a different project.
- For Swift/Xcode projects, skip the dev-server steps and note that they need to be run from Xcode (`swift run` for SwiftPM executables).
